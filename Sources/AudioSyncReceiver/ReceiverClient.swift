import Foundation
import Network
import SyncCore

/// UDP client: connects to the sender, keeps the clock synchronized with
/// periodic probes, and files incoming audio packets into the jitter buffer.
final class ReceiverClient {
    let sync = ClockSynchronizer()
    let drift = DriftEstimator()
    let buffer = JitterBuffer()

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "audiosync.recv.net")
    private var clockTimer: DispatchSourceTimer?
    private var helloTimer: DispatchSourceTimer?
    private let onReady: () -> Void

    // Diagnostics
    private(set) var audioPacketsReceived: UInt64 = 0
    private(set) var clockRepliesReceived: UInt64 = 0
    private(set) var decodeErrors: UInt64 = 0

    init(endpoint: NWEndpoint, onReady: @escaping () -> Void) {
        self.connection = NWConnection(to: endpoint, using: .udp)
        self.onReady = onReady
    }

    convenience init(host: String, port: UInt16, onReady: @escaping () -> Void) {
        self.init(
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!),
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
        // 4 probes/s: the synchronizer's min-RTT window converges within a
        // couple of seconds and then keeps tracking drift; probes double as
        // keepalives so the sender doesn't expire us.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
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
            buffer.insert(chunk)
        case .hello, .clockRequest:
            break // server-to-client only carries replies and audio
        }
    }
}
