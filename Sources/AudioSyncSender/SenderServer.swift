import Foundation
import Network
import SyncCore

/// UDP server: accepts receivers, answers their clock probes against our
/// master clock, and fans out timestamped audio packets to every client.
final class SenderServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "audiosync.sender.net")
    private let pathMonitor = NWPathMonitor()
    private var clients: [String: ClientState] = [:]
    private let clientsLock = NSLock()
    private var sequence: UInt32 = 0

    // Listener config, retained so the listener can be rebuilt identically
    // when the network changes — rebuilding re-binds the socket on the new
    // interface and re-publishes Bonjour WITHOUT restarting the process
    // (a process restart in --party mode would un-mute/re-mute system audio
    // and re-run the tap).
    private let params: NWParameters
    private let serviceName: String
    private let requestedPort: NWEndpoint.Port
    /// Actual port from the first successful bind; reused on rebuild so
    /// --connect receivers and the printed join code stay valid.
    private var boundPort: NWEndpoint.Port?
    private var listenerGeneration: UInt64 = 0
    private var rebuildScheduled = false
    private var lastPathDescriptor: String?

    // Diagnostics
    private var packetsSent: UInt64 = 0
    private var lastStatsPacketsSent: UInt64 = 0
    private var statsTimer: DispatchSourceTimer?

    /// Playback delay budget (latency), FIXED for the lifetime of the stream.
    /// We deliberately never change it while streaming: any runtime change
    /// shifts every subsequent packet's play time, and the receiver hears that
    /// seam as a click or a burst of static as the timeline ramps. A constant
    /// buffer is the only way to guarantee the stream never breaks from buffer
    /// tuning. Set it once with --buffer-ms (raise it on a flaky network).
    /// Receivers still report their health upstream — it shows in their own
    /// stats — the sender just doesn't act on it anymore.
    private let bufferDelayNs: UInt64
    /// Wire codec for outgoing audio: Int16 is half the bytes of Float32 and
    /// perceptually transparent. (Local --party playback still gets the full
    /// Float32 chunk via `localSink`.)
    private let codec: AudioCodec = .pcmInt16

    private struct ClientState {
        let connection: NWConnection
        var lastSeenNs: UInt64
    }

    /// Optional local consumer of every chunk (used by --party mode to feed
    /// the sender's own synced playback without a network round trip).
    var localSink: ((AudioChunk) -> Void)?

    /// Non-nil when a passphrase is set: every datagram in both directions
    /// is sealed/verified; unauthenticated peers are ignored entirely.
    private let cipher: StreamCipher?

    init(port: UInt16, serviceName: String, peerToPeer: Bool = true, passphrase: String? = nil, bufferDelayMs: Int = 150) throws {
        cipher = passphrase.flatMap { $0.isEmpty ? nil : StreamCipher(passphrase: $0) }
        self.serviceName = serviceName
        let clampedMs = max(20, min(bufferDelayMs, 5000))
        self.bufferDelayNs = UInt64(clampedMs) * 1_000_000
        // port == 0 → ask the OS for an ephemeral port (IANA dynamic range
        // 49152–65535). Corporate Wi-Fi controllers occasionally blocklist
        // specific known ports (we hit 7805 being filtered on one office
        // network); the dynamic range is essentially never on those lists.
        if port == 0 {
            requestedPort = .any
        } else {
            guard let p = NWEndpoint.Port(rawValue: port) else {
                throw RuntimeError("invalid port \(port)")
            }
            requestedPort = p
        }
        let params = NWParameters.udp
        // Voice-class QoS (802.11e WMM): Wi-Fi prioritizes our datagrams and
        // exempts them from power-save buffering — this directly reduces the
        // periodic 70–150 ms jitter bursts seen on infrastructure Wi-Fi.
        params.serviceClass = .interactiveVoice
        // Peer-to-peer (AWDL): lets receivers reach us over the direct
        // Mac-to-Mac link (the AirDrop radio path), bypassing the router.
        params.includePeerToPeer = peerToPeer
        self.params = params
        // Build the first listener up front so startup errors (e.g. port in
        // use) surface synchronously to the caller.
        listener = try makeListener(on: requestedPort)
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path) // delivered on `queue`
        }
        pathMonitor.start(queue: queue)
        listener?.start(queue: queue)
        startStatsTimer()
    }

    // MARK: - Listener lifecycle

    private func makeListener(on port: NWEndpoint.Port) throws -> NWListener {
        listenerGeneration &+= 1
        let gen = listenerGeneration
        let l = try NWListener(using: params, on: port)
        // Advertise over Bonjour so receivers can find us with --browse. The
        // service publishes whatever port the OS assigned, so receivers don't
        // need to know the port in advance.
        l.service = NWListener.Service(name: serviceName, type: "_audiosync._udp")
        l.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        l.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.listenerGeneration else { return }
            switch state {
            case .ready:
                if let actual = self.listener?.port { self.boundPort = actual }
                let actual = self.boundPort?.rawValue ?? 0
                log("listening on UDP port \(actual), Bonjour \"\(self.serviceName)\" (_audiosync._udp)")
                self.logJoinCodes(port: actual)
            case .failed(let error):
                log("listener failed: \(error) — rebuilding")
                self.rebuildListener(reason: "listener failed")
            default:
                break
            }
        }
        return l
    }

    /// Rebuild the listener in-process on a network change or failure. Leaves
    /// `clients`, the audio fan-out and the capture untouched — existing
    /// receiver connections keep flowing; only the listening endpoint is
    /// re-created and Bonjour re-published on the new interface.
    private func rebuildListener(reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        log("rebuilding listener (\(reason))…")
        listener?.cancel()
        listener = nil
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            // Prefer re-binding the same port; fall back to the originally
            // requested port (usually .any) if it's momentarily unavailable.
            var candidates = [self.boundPort ?? self.requestedPort]
            if self.requestedPort != candidates[0] { candidates.append(self.requestedPort) }
            for candidate in candidates {
                do {
                    let l = try self.makeListener(on: candidate)
                    self.listener = l
                    l.start(queue: self.queue)
                    return
                } catch {
                    log("listener bind on \(candidate) failed: \(error)")
                }
            }
            log("listener rebuild failed — retrying in 1s")
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.rebuildListener(reason: "retry")
            }
        }
    }

    private func handlePathUpdate(_ path: NWPath) {
        dispatchPrecondition(condition: .onQueue(queue))
        let ifaces = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
        let descriptor = "\(path.status)/[\(ifaces)]"
        let previous = lastPathDescriptor
        lastPathDescriptor = descriptor
        guard let previous, previous != descriptor else { return }
        if path.status == .satisfied {
            log("network changed (\(descriptor)) — rebuilding listener and re-publishing Bonjour")
            rebuildListener(reason: "path changed")
        } else {
            log("network unavailable — listener idle until it returns")
        }
    }

    // MARK: - Join code (manual-connect fallback)

    /// Print copyable join codes (IPv4:port) so a receiver on a network that
    /// blocks Bonjour discovery can still connect with --connect. The address
    /// changes across a network switch, so this is re-emitted on every
    /// listener (re)bind.
    private func logJoinCodes(port: UInt16) {
        guard port != 0 else { return }
        let addresses = localIPv4Addresses().sorted { lhs, rhs in
            func rank(_ name: String) -> Int { name == "en0" ? 0 : (name.hasPrefix("en") ? 1 : 2) }
            return rank(lhs.iface) < rank(rhs.iface)
        }
        for (index, address) in addresses.enumerated() {
            if index == 0 {
                log("join-code=\(address.ip):\(port) (\(address.iface)) — if discovery " +
                    "is blocked, enter this on the receiver's Manual Connect")
            } else {
                log("also reachable at \(address.ip):\(port) (\(address.iface))")
            }
        }
    }

    // MARK: - Clients

    private func accept(_ connection: NWConnection) {
        let key = String(describing: connection.endpoint)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                // Don't register the client yet — registration (and thus the
                // audio fan-out) happens in handle() only after the first
                // message that passes authentication. Unauthenticated peers
                // never receive a single packet.
                self.receiveLoop(connection, key: key)
            case .failed, .cancelled:
                self.removeClient(key)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func removeClient(_ key: String) {
        clientsLock.lock()
        let removed = clients.removeValue(forKey: key)
        clientsLock.unlock()
        if removed != nil { log("receiver disconnected: \(key)") }
    }

    private func receiveLoop(_ connection: NWConnection, key: String) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            // Stamp t2 as early as possible after the datagram arrives.
            let receivedNs = MonotonicClock.nowNs()
            if let data, !data.isEmpty {
                self.handle(data, receivedNs: receivedNs, from: connection, key: key)
            }
            if error == nil {
                self.receiveLoop(connection, key: key)
            } else {
                self.removeClient(key)
            }
        }
    }

    private func handle(_ data: Data, receivedNs: UInt64, from connection: NWConnection, key: String) {
        // Authenticate/decrypt before trusting anything — including the
        // keepalive bookkeeping, so unauthenticated peers can't stay "alive".
        let payload: Data
        if let cipher {
            guard let opened = try? cipher.open(data) else { return }
            payload = opened
        } else {
            guard !StreamCipher.looksSealed(data) else { return }
            payload = data
        }

        clientsLock.lock()
        let isNew = clients[key] == nil
        if isNew {
            clients[key] = ClientState(connection: connection, lastSeenNs: receivedNs)
        } else {
            clients[key]?.lastSeenNs = receivedNs
        }
        clientsLock.unlock()
        if isNew { log("receiver connected: \(key)\(cipher != nil ? " (authenticated)" : "")") }

        guard let message = try? Wire.decode(payload) else { return }
        switch message {
        case .hello:
            break // lastSeen update above is all we need
        case .clockRequest(let t1):
            // We are the master clock: t2 = receive time, t3 = send time.
            let reply = Wire.encode(.clockReply(
                clientSendNs: t1,
                serverRecvNs: receivedNs,
                serverSendNs: MonotonicClock.nowNs()
            ))
            connection.send(content: wrap(reply), completion: .contentProcessed { _ in })
        case .feedback:
            // Receivers report health upstream; with a fixed buffer the sender
            // doesn't act on it (kept on the wire for the receiver's own stats
            // and possible future use).
            break
        case .clockReply, .audio:
            break // not valid from a client; ignore
        }
    }

    // MARK: - Audio fan-out

    /// Split a run of interleaved samples into MTU-sized packets and send to
    /// every connected receiver. `sourceClockNs` is the master-clock capture
    /// time of the first frame; the server adds its current (adaptive,
    /// slew-limited) buffer to derive each packet's play time. The local
    /// --party sink always receives the full-quality Float32 chunk.
    func sendAudio(samples: [Float], sourceClockNs: UInt64, sampleRate: Double, channels: Int) {
        let totalFrames = samples.count / channels
        var frameOffset = 0
        while frameOffset < totalFrames {
            let n = min(Wire.maxFramesPerPacket, totalFrames - frameOffset)
            // Fixed buffer — never changed mid-stream, so packet play times
            // advance exactly with the audio and there is no seam to click on.
            let bufferNs = bufferDelayNs

            let slice = Array(samples[(frameOffset * channels)..<((frameOffset + n) * channels)])
            let playAt = sourceClockNs &+ bufferNs &+ UInt64(Double(frameOffset) / sampleRate * 1e9)
            sequence &+= 1
            let chunk = AudioChunk(
                sequence: sequence,
                playAtMasterNs: playAt,
                sampleRate: sampleRate,
                channels: channels,
                samples: slice
            )
            broadcast(wrap(Wire.encode(.audio(chunk), codec: codec)))
            localSink?(chunk)
            frameOffset += n
        }
    }

    /// Seal outbound data when encryption is on.
    private func wrap(_ data: Data) -> Data {
        cipher?.seal(data) ?? data
    }

    private func broadcast(_ data: Data) {
        clientsLock.lock()
        let connections = clients.values.map(\.connection)
        clientsLock.unlock()
        for connection in connections {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
        packetsSent &+= UInt64(connections.count)
    }

    // MARK: - Stats / housekeeping

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = MonotonicClock.nowNs()
            self.clientsLock.lock()
            // Drop receivers we haven't heard from in 15 s (their clock
            // probes double as keepalives).
            let stale = self.clients.filter { now - $0.value.lastSeenNs > 15_000_000_000 }
            for (key, state) in stale {
                state.connection.cancel()
                self.clients.removeValue(forKey: key)
            }
            let clientCount = self.clients.count
            self.clientsLock.unlock()
            for key in stale.keys { log("receiver timed out: \(key)") }

            let sent = self.packetsSent
            let rate = (sent - self.lastStatsPacketsSent) / 5
            self.lastStatsPacketsSent = sent
            log("clients=\(clientCount) packets/s=\(rate)")
        }
        timer.resume()
        statsTimer = timer
    }
}

func log(_ message: String) {
    let seconds = Double(MonotonicClock.nowNs()) / 1e9
    FileHandle.standardError.write(Data(String(format: "[%.3f] %@\n", seconds, message).utf8))
}

/// All non-loopback IPv4 addresses on currently-up "real" interfaces (Wi-Fi /
/// Ethernet), skipping AWDL/utun/bridge which aren't useful manual-connect
/// targets. Used to print join codes.
func localIPv4Addresses() -> [(iface: String, ip: String)] {
    var results: [(iface: String, ip: String)] = []
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
    defer { freeifaddrs(ifaddrPtr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        guard (flags & Int32(IFF_UP)) != 0, (flags & Int32(IFF_LOOPBACK)) == 0 else { continue }
        guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: ptr.pointee.ifa_name)
        guard !name.hasPrefix("awdl"), !name.hasPrefix("llw"),
              !name.hasPrefix("utun"), !name.hasPrefix("bridge") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        if r == 0 { results.append((name, String(cString: host))) }
    }
    return results
}
