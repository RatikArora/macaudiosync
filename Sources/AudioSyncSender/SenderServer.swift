import Foundation
import Network
import SyncCore

/// UDP server: accepts receivers, answers their clock probes against our
/// master clock, and fans out timestamped audio packets to every client.
final class SenderServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "audiosync.sender.net")
    private var clients: [String: ClientState] = [:]
    private let clientsLock = NSLock()
    private var sequence: UInt32 = 0

    // Diagnostics
    private var packetsSent: UInt64 = 0
    private var lastStatsPacketsSent: UInt64 = 0
    private var statsTimer: DispatchSourceTimer?

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

    init(port: UInt16, serviceName: String, peerToPeer: Bool = true, passphrase: String? = nil) throws {
        cipher = passphrase.flatMap { $0.isEmpty ? nil : StreamCipher(passphrase: $0) }
        // port == 0 → ask the OS for an ephemeral port (IANA dynamic range
        // 49152–65535). Corporate Wi-Fi controllers occasionally blocklist
        // specific known ports (we hit 7805 being filtered on one office
        // network); the dynamic range is essentially never on those lists.
        let nwPort: NWEndpoint.Port
        if port == 0 {
            nwPort = .any
        } else {
            guard let p = NWEndpoint.Port(rawValue: port) else {
                throw RuntimeError("invalid port \(port)")
            }
            nwPort = p
        }
        let params = NWParameters.udp
        // Voice-class QoS (802.11e WMM): Wi-Fi prioritizes our datagrams and
        // exempts them from power-save buffering — this directly reduces the
        // periodic 70–150 ms jitter bursts seen on infrastructure Wi-Fi.
        params.serviceClass = .interactiveVoice
        // Peer-to-peer (AWDL): lets receivers reach us over the direct
        // Mac-to-Mac link (the AirDrop radio path), bypassing the router.
        params.includePeerToPeer = peerToPeer
        listener = try NWListener(using: params, on: nwPort)
        // Advertise over Bonjour so receivers can find us with --browse.
        // The service publishes whatever port the OS assigned, so receivers
        // don't need to know the port in advance.
        listener.service = NWListener.Service(name: serviceName, type: "_audiosync._udp")
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let actual = self?.listener.port?.rawValue ?? port
                log("listening on UDP port \(actual), Bonjour \"\(serviceName)\" (_audiosync._udp)")
            case .failed(let error):
                log("listener failed: \(error)")
                exit(1)
            default:
                break
            }
        }
    }

    func start() {
        listener.start(queue: queue)
        startStatsTimer()
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
        case .clockReply, .audio:
            break // not valid from a client; ignore
        }
    }

    // MARK: - Audio fan-out

    /// Split a run of interleaved samples into MTU-sized packets and send to
    /// every connected receiver. `firstFramePlayAtNs` is the master-clock
    /// time the first frame should play.
    func sendAudio(samples: [Float], firstFramePlayAtNs: UInt64, sampleRate: Double, channels: Int) {
        let totalFrames = samples.count / channels
        var frameOffset = 0
        while frameOffset < totalFrames {
            let n = min(Wire.maxFramesPerPacket, totalFrames - frameOffset)
            let slice = Array(samples[(frameOffset * channels)..<((frameOffset + n) * channels)])
            let playAt = firstFramePlayAtNs + UInt64(Double(frameOffset) / sampleRate * 1e9)
            sequence &+= 1
            let chunk = AudioChunk(
                sequence: sequence,
                playAtMasterNs: playAt,
                sampleRate: sampleRate,
                channels: channels,
                samples: slice
            )
            broadcast(wrap(Wire.encode(.audio(chunk))))
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
