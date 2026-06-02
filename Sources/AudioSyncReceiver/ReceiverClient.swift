import Foundation
import Network
import SyncCore

func log(_ message: String) {
    let seconds = Double(MonotonicClock.nowNs()) / 1e9
    FileHandle.standardError.write(Data(String(format: "[%.3f] %@\n", seconds, message).utf8))
}

/// UDP client: connects to the sender, keeps the clock synchronized with
/// periodic probes, and files incoming audio packets into the jitter buffer.
final class ReceiverClient {
    let sync = ClockSynchronizer()
    let drift = DriftEstimator()
    let buffer = JitterBuffer()
    /// How early audio arrives vs. its play deadline (latency headroom).
    let margin = MarginTracker()

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "audiosync.recv.net")
    private var clockTimer: DispatchSourceTimer?
    private var helloTimer: DispatchSourceTimer?
    private let onReady: () -> Void

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

    init(endpoint: NWEndpoint, peerToPeer: Bool = true, onReady: @escaping () -> Void) {
        self.connection = NWConnection(to: endpoint, using: Self.parameters(peerToPeer: peerToPeer))
        self.onReady = onReady
    }

    convenience init(host: String, port: UInt16, peerToPeer: Bool = true, onReady: @escaping () -> Void) {
        self.init(
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!),
            peerToPeer: peerToPeer,
            onReady: onReady
        )
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                log("connected to \(self.connection.endpoint)")
                self.connection.send(content: Wire.encode(.hello), completion: .contentProcessed { _ in })
                self.receiveLoop()
                self.startClockProbes()
                self.onReady()
            case .failed(let error):
                log("connection failed: \(error)")
                exit(1)
            case .waiting(let error):
                log("waiting (network unreachable?): \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: - Clock probes

    private func startClockProbes() {
        // Startup burst: 20 probes/s for the first two seconds so playback
        // can begin ~0.3 s after connecting (the synchronizer needs 5
        // samples) with a well-filtered offset. Then drop to 4 probes/s,
        // which is plenty to keep tracking drift; probes double as
        // keepalives so the sender doesn't expire us.
        let burstProbes = 40
        var probesSent = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            probesSent += 1
            if probesSent == burstProbes {
                timer.schedule(deadline: .now() + 0.25, repeating: .milliseconds(250), leeway: .milliseconds(10))
            }
            let t1 = MonotonicClock.nowNs()
            self.connection.send(
                content: Wire.encode(.clockRequest(clientSendNs: t1)),
                completion: .contentProcessed { _ in }
            )
        }
        timer.resume()
        clockTimer = timer
    }

    // MARK: - Receive

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            let receivedNs = MonotonicClock.nowNs() // t4, stamped immediately
            if let data, !data.isEmpty {
                self.handle(data, receivedNs: receivedNs)
            }
            if error == nil {
                self.receiveLoop()
            } else {
                log("receive error: \(String(describing: error))")
                exit(1)
            }
        }
    }

    private func handle(_ data: Data, receivedNs: UInt64) {
        let message: Message
        do {
            message = try Wire.decode(data)
        } catch {
            decodeErrors &+= 1
            return
        }

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
        case .hello, .clockRequest:
            break // server-to-client only carries replies and audio
        }
    }
}
