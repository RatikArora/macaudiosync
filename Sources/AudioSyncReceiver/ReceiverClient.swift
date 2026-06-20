import Foundation
import Network
import SyncCore

func log(_ message: String) {
    let seconds = Double(MonotonicClock.nowNs()) / 1e9
    FileHandle.standardError.write(Data(String(format: "[%.3f] %@\n", seconds, message).utf8))
}

/// UDP client: connects to the sender, keeps the clock synchronized with
/// periodic probes, and files incoming audio packets into the jitter buffer.
///
/// Survives network changes WITHOUT tearing down playback. The audio state
/// (`sync`/`drift`/`buffer`/`margin`) and the `SyncedPlayer` that renders from
/// it live for the whole process; only the `NWConnection` (and, in browse
/// mode, the `NWBrowser`) are disposable and get rebuilt on demand. An
/// `NWPathMonitor` reconnects proactively the moment Wi-Fi changes (e.g.
/// corporate → hotspot), and every failure path funnels through one
/// serialized `reconnect()` guarded by a generation counter so overlapping
/// triggers (path change, watchdog, socket error) collapse into a single
/// reconnect instead of racing.
final class ReceiverClient {
    /// Where to find the sender. `.browse` self-discovers over Bonjour and
    /// re-resolves on every reconnect (so the sender's port can change across
    /// a network switch); `.endpoint` is a fixed, manually-entered target.
    enum Target {
        case browse(serviceName: String?)
        case endpoint(NWEndpoint)
    }

    let sync = ClockSynchronizer()
    let drift = DriftEstimator()
    let buffer = JitterBuffer()
    /// How early audio arrives vs. its play deadline (latency headroom).
    let margin = MarginTracker()

    private let target: Target
    private let peerToPeer: Bool
    private let onReady: () -> Void

    private let queue = DispatchQueue(label: "audiosync.recv.net")
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private let pathMonitor = NWPathMonitor()

    /// Bumped on every (re)connect. Callbacks captured against an older value
    /// belong to a torn-down connection and must no-op.
    private var generation: UInt64 = 0
    /// Collapses a burst of reconnect triggers into one re-establish attempt.
    private var reconnectScheduled = false
    /// onReady() / playback start happens exactly once, on the first ready.
    private var hasBecomeReadyOnce = false
    /// Remembered after the first successful discovery so reconnects prefer
    /// the same sender rather than hopping to a different one that appears.
    private var resolvedServiceName: String?
    private var lastPathDescriptor: String?

    private var clockTimer: DispatchSourceTimer?
    private var trafficWatchdog: DispatchSourceTimer?
    /// Host time of the last decoded packet from the sender. The watchdog
    /// reconnects once this goes stale — catching a silently-dead sender
    /// (UDP gives no socket error) within a few seconds.
    private var lastTrafficNs: UInt64 = 0
    /// Whether ANY sender packet has arrived on the current connection —
    /// distinguishes "this network is filtering/isolating us" (connected but
    /// never heard back) from "the sender went away" (heard, then silence).
    private var gotTrafficThisConnection = false
    /// Consecutive isolated reconnects (found the sender, no traffic). After a
    /// few, the guidance escalates from "retrying" to "this network can't carry
    /// it — use a hotspot or cable", since no amount of retrying will fix a
    /// network that blocks device-to-device traffic. Reset when traffic flows.
    private var isolationStrikes = 0

    // Diagnostics
    private(set) var audioPacketsReceived: UInt64 = 0
    private(set) var clockRepliesReceived: UInt64 = 0
    private(set) var decodeErrors: UInt64 = 0
    /// Consecutive-sequence chunks whose timestamps don't abut (>30 µs gap
    /// or overlap). Nonzero means the SENDER's capture timestamps jitter —
    /// audible as crackle even at 100% fill.
    private(set) var timestampJitterCount: UInt64 = 0
    private var lastSequence: UInt32 = 0
    private var lastEndNs: UInt64 = 0

    /// UDP parameters tuned for low-jitter audio: voice-class QoS (Wi-Fi
    /// WMM priority, no power-save buffering) and optional peer-to-peer
    /// (AWDL direct Mac-to-Mac link, bypassing the router).
    static func parameters(peerToPeer: Bool) -> NWParameters {
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        params.includePeerToPeer = peerToPeer
        return params
    }

    /// Non-nil when a passphrase is set: all traffic both ways is
    /// sealed/verified, and plaintext or wrong-key streams are rejected.
    private let cipher: StreamCipher?
    private var warnedAboutKeyMismatch = false
    private var warnedAboutVersionMismatch = false

    init(target: Target, peerToPeer: Bool = true, passphrase: String? = nil, onReady: @escaping () -> Void) {
        self.target = target
        self.peerToPeer = peerToPeer
        self.cipher = passphrase.flatMap { $0.isEmpty ? nil : StreamCipher(passphrase: $0) }
        self.onReady = onReady
    }

    convenience init(endpoint: NWEndpoint, peerToPeer: Bool = true, passphrase: String? = nil, onReady: @escaping () -> Void) {
        self.init(target: .endpoint(endpoint), peerToPeer: peerToPeer, passphrase: passphrase, onReady: onReady)
    }

    convenience init(host: String, port: UInt16, peerToPeer: Bool = true, passphrase: String? = nil, onReady: @escaping () -> Void) {
        self.init(
            target: .endpoint(.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)),
            peerToPeer: peerToPeer,
            passphrase: passphrase,
            onReady: onReady
        )
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path) // already delivered on `queue`
        }
        pathMonitor.start(queue: queue)
        queue.async { [weak self] in self?.beginConnecting() }
    }

    // MARK: - Connect / reconnect

    private func beginConnecting() {
        dispatchPrecondition(condition: .onQueue(queue))
        switch target {
        case .endpoint(let endpoint):
            connect(to: endpoint)
        case .browse(let name):
            startBrowse(preferName: resolvedServiceName ?? name)
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        dispatchPrecondition(condition: .onQueue(queue))
        generation &+= 1
        let gen = generation
        let conn = NWConnection(to: endpoint, using: Self.parameters(peerToPeer: peerToPeer))
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.generation else { return }
            switch state {
            case .ready:
                self.onConnected(conn, gen: gen)
            case .failed(let error):
                log("connection failed: \(error)")
                self.reconnect(reason: "connection failed")
            case .waiting(let error):
                log("waiting (network unreachable?): \(error)")
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func onConnected(_ conn: NWConnection, gen: UInt64) {
        let first = !hasBecomeReadyOnce
        hasBecomeReadyOnce = true
        let via = pathTypeDescription(conn.currentPath)
        log(first
            ? "connected to \(conn.endpoint)\(cipher != nil ? " (encrypted)" : "") via \(via)"
            : "stream resumed — reconnected to \(conn.endpoint) via \(via)")
        conn.send(content: wrap(Wire.encode(.hello)), completion: .contentProcessed { _ in })
        lastTrafficNs = MonotonicClock.nowNs()
        gotTrafficThisConnection = false
        receiveLoop(conn, gen: gen)
        startClockProbes()      // re-runs the startup burst → offset re-tightens fast
        startTrafficWatchdog()
        if first { onReady() }  // start playback exactly once
    }

    /// The single serialized reconnect path. Every failure trigger (path
    /// change, watchdog silence, socket error, listener failure) calls this
    /// instead of exiting. Bumping the generation neutralizes the old
    /// connection's in-flight callbacks; the scheduled flag collapses a burst
    /// of triggers into one re-establish.
    func reconnect(reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        generation &+= 1
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        clockTimer?.cancel(); clockTimer = nil
        trafficWatchdog?.cancel(); trafficWatchdog = nil
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        log("reconnecting (\(reason))…")
        // Keep playing the (now silent) timeline; the AVAudioEngine never stops.
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            self.beginConnecting()
        }
    }

    // MARK: - Discovery (browse mode)

    private func startBrowse(preferName: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        browser?.cancel()
        let b = NWBrowser(
            for: .bonjour(type: "_audiosync._udp", domain: nil),
            using: Self.parameters(peerToPeer: peerToPeer)
        )
        browser = b
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.browser === b else { return }
            let chosen = Self.pick(from: results, preferName: preferName)
            guard let chosen else { return }
            if case let .service(name, _, _, _) = chosen.endpoint {
                self.resolvedServiceName = name
            }
            log("found sender: \(chosen.endpoint)")
            b.cancel()
            self.browser = nil
            self.connect(to: chosen.endpoint)
        }
        b.stateUpdateHandler = { [weak self] state in
            guard let self, self.browser === b else { return }
            if case .failed(let error) = state {
                log("browse failed: \(error) — retrying in 1s")
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.browser === b else { return }
                    self.startBrowse(preferName: preferName)
                }
            }
        }
        b.start(queue: queue)
        log("browsing for senders (_audiosync._udp)…")
        // If discovery turns up nothing after a few seconds, say so — but
        // keep browsing. This is the "mDNS/Bonjour is blocked" case, distinct
        // from "found the sender but no traffic" (client isolation) above.
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.browser === b, self.connection == nil else { return }
            log("diag=no-mdns — no sender found yet. This network may block " +
                "Bonjour/mDNS discovery. Enter the sender's address with Manual " +
                "Connect, or put both Macs on a personal hotspot. Still searching…")
        }
    }

    private static func pick(from results: Set<NWBrowser.Result>, preferName: String?) -> NWBrowser.Result? {
        if let preferName {
            let match = results.first { result in
                if case let .service(name, _, _, _) = result.endpoint { return name == preferName }
                return false
            }
            if let match { return match }
        }
        return results.first
    }

    // MARK: - Path monitoring

    private func handlePathUpdate(_ path: NWPath) {
        dispatchPrecondition(condition: .onQueue(queue))
        let descriptor = pathDescriptor(path)
        let previous = lastPathDescriptor
        lastPathDescriptor = descriptor
        guard let previous, previous != descriptor else { return } // first/identical: record only
        switch path.status {
        case .satisfied:
            log("network changed (\(descriptor)) — reconnecting")
            reconnect(reason: "path changed")
        default:
            log("network unavailable — holding until it returns")
        }
    }

    private func pathDescriptor(_ path: NWPath) -> String {
        let ifaces = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
        return "\(path.status)/[\(ifaces)]"
    }

    private func pathTypeDescription(_ path: NWPath?) -> String {
        guard let path else { return "—" }
        if path.usesInterfaceType(.wifi) { return "Wi-Fi router" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired Ethernet" }
        if path.usesInterfaceType(.other) { return "peer-to-peer (AWDL)" }
        return "network"
    }

    // MARK: - Clock probes

    private func startClockProbes() {
        clockTimer?.cancel()
        // Startup burst: 20 probes/s for the first two seconds so playback
        // can begin ~0.3 s after connecting (the synchronizer needs 5
        // samples) with a well-filtered offset. Then drop to 4 probes/s,
        // which is plenty to keep tracking drift; probes double as
        // keepalives so the sender doesn't expire us. Re-run on each
        // reconnect so a network switch re-tightens the offset immediately.
        let burstProbes = 40
        var probesSent = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, let conn = self.connection else { return }
            probesSent += 1
            if probesSent == burstProbes {
                timer.schedule(deadline: .now() + 0.25, repeating: .milliseconds(250), leeway: .milliseconds(10))
            }
            let t1 = MonotonicClock.nowNs()
            conn.send(
                content: self.wrap(Wire.encode(.clockRequest(clientSendNs: t1))),
                completion: .contentProcessed { _ in }
            )
        }
        timer.resume()
        clockTimer = timer
    }

    // MARK: - Traffic watchdog

    // The NWConnection enters .ready as soon as the OS sets up its local UDP
    // socket — that says nothing about whether packets actually flow. On
    // networks that filter our port or isolate clients, the hello and clock
    // probes leave but nothing comes back; and a silently-killed sender gives
    // no socket error over UDP. So poll the last-traffic timestamp: once it
    // goes stale, reconnect (a fresh Bonjour resolve picks up any new sender
    // port). On a genuinely hostile network this becomes a steady retry, and
    // the distinct log lines feed the diagnosis surfaced to the user.
    private static let trafficTimeoutNs: UInt64 = 3_000_000_000

    private func startTrafficWatchdog() {
        trafficWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stale = MonotonicClock.nowNs() &- self.lastTrafficNs
            guard stale > Self.trafficTimeoutNs else { return }
            if self.gotTrafficThisConnection {
                log("sender stream silent for 3s — reconnecting…")
                self.reconnect(reason: "silent 3s")
            } else {
                self.isolationStrikes += 1
                if case .endpoint(let ep) = self.target {
                    // Manual address: UDP has no handshake, so "no reply" most
                    // likely means the address is wrong or the sender isn't
                    // there — not network isolation.
                    log("diag=unreachable — reached \(ep) but got no audio back. Double-check " +
                        "the address (the IP:port from the sender's join code), make sure the " +
                        "sender is running, and that both Macs are on the same network. Retrying…")
                } else if self.isolationStrikes >= 3 {
                    // Browse + persistent: retrying won't fix a network that
                    // blocks device-to-device traffic. Point at the sure fixes.
                    log("diag=isolated — this network keeps blocking the audio between " +
                        "your Macs (client isolation or port filtering) and can't carry the " +
                        "stream. Reliable fix: put BOTH Macs on a personal hotspot, or connect " +
                        "them with a USB-C / Thunderbolt cable — a direct link always works. " +
                        "Still retrying in the background…")
                } else {
                    log("diag=isolated — found the sender but no audio is getting through. " +
                        "This network may block device-to-device traffic (client isolation) or " +
                        "filter our port. Trying the direct Mac-to-Mac radio… if it doesn't " +
                        "catch, use a hotspot or a cable.")
                }
                self.reconnect(reason: "no traffic (isolated/filtered)")
            }
        }
        timer.resume()
        trafficWatchdog = timer
    }

    // MARK: - Feedback (upstream health report)

    /// Send a once-a-second health report to the sender, which uses the
    /// worst-case across receivers to tune its adaptive buffer. No-op while
    /// reconnecting (no current connection). Hops onto the net queue.
    func sendFeedback(_ feedback: Feedback) {
        queue.async { [weak self] in
            guard let self, let conn = self.connection else { return }
            conn.send(content: self.wrap(Wire.encode(.feedback(feedback))), completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Receive

    private func receiveLoop(_ conn: NWConnection, gen: UInt64) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, gen == self.generation else { return }
            let receivedNs = MonotonicClock.nowNs() // t4, stamped immediately
            if let data, !data.isEmpty {
                self.handle(data, receivedNs: receivedNs)
            }
            if error == nil {
                self.receiveLoop(conn, gen: gen)
            } else {
                log("receive error: \(String(describing: error))")
                self.reconnect(reason: "receive error")
            }
        }
    }

    /// Seal outbound data when encryption is on.
    private func wrap(_ data: Data) -> Data {
        cipher?.seal(data) ?? data
    }

    private func handle(_ data: Data, receivedNs: UInt64) {
        let payload: Data
        if let cipher {
            guard let opened = try? cipher.open(data) else {
                decodeErrors &+= 1
                warnKeyMismatch("stream rejected — is the sender using the SAME password?")
                return
            }
            payload = opened
        } else {
            guard !StreamCipher.looksSealed(data) else {
                decodeErrors &+= 1
                warnKeyMismatch("stream is encrypted — set the sender's password on this receiver")
                return
            }
            payload = data
        }

        let message: Message
        do {
            message = try Wire.decode(payload)
        } catch WireError.unsupportedVersion(let v) {
            decodeErrors &+= 1
            warnVersionMismatch(v)
            return
        } catch {
            decodeErrors &+= 1
            return
        }

        // Any well-formed packet from the sender proves the path works.
        lastTrafficNs = receivedNs
        gotTrafficThisConnection = true
        isolationStrikes = 0

        switch message {
        case .clockReply(let t1, let t2, let t3):
            clockRepliesReceived &+= 1
            if let sample = sync.addExchange(
                clientSendNs: t1, serverRecvNs: t2, serverSendNs: t3, clientRecvNs: receivedNs
            ) {
                drift.add(clientNs: sample.clientNs, offsetNs: sample.offsetNs)
            }
        case .audio(let chunk):
            audioPacketsReceived &+= 1
            if chunk.sequence == lastSequence &+ 1 {
                let deltaNs = Int64(bitPattern: chunk.playAtMasterNs &- lastEndNs)
                if deltaNs.magnitude > 30_000 { timestampJitterCount &+= 1 }
            }
            lastSequence = chunk.sequence
            lastEndNs = chunk.endMasterNs
            if buffer.insert(chunk), let masterNow = sync.masterNs(forClientNs: receivedNs) {
                margin.add(marginNs: Int64(bitPattern: chunk.playAtMasterNs &- masterNow))
            }
        case .hello, .clockRequest, .feedback:
            break // client-to-server only; ignore if ever echoed back
        }
    }

    private func warnKeyMismatch(_ message: String) {
        guard !warnedAboutKeyMismatch else { return }
        warnedAboutKeyMismatch = true
        // diag= so the app surfaces it plainly (it was otherwise just a
        // silent decodeErr count).
        log("diag=key — \(message)")
    }

    private func warnVersionMismatch(_ wireVersion: UInt8) {
        guard !warnedAboutVersionMismatch else { return }
        warnedAboutVersionMismatch = true
        log("diag=version — the sender is running a different Sonar version " +
            "(wire v\(wireVersion); this build expects v\(Wire.version)). Update both " +
            "Macs to the same version — open About → it'll offer the update.")
    }
}
