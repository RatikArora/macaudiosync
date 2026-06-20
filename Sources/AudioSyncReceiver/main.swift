import Foundation
import Network
import SyncCore
import AudioPipeline

// audiosync-recv — receiver side. Connects to a sender, synchronizes to its
// master clock, and plays the stream through the default output device at
// the master-scheduled time.

struct ReceiverOptions {
    var target: Target = .browse
    var headless = false
    var exitAfterSeconds: Int? = nil
    var peerToPeer = true
    var passphrase: String? = nil
    /// Browse mode: connect only to the sender with this exact Bonjour name
    /// (from `--list-senders`). nil = first one found.
    var senderName: String? = nil
    /// Discovery-only mode: list senders for N seconds, then exit.
    var listSeconds: Double? = nil

    enum Target {
        case browse
        case hostPort(host: String, port: UInt16)
    }
}

func parseReceiverOptions() -> ReceiverOptions {
    var options = ReceiverOptions()
    var args = Array(CommandLine.arguments.dropFirst())
    func takeValue(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag) else { return nil }
        guard i + 1 < args.count else { fail("missing value for \(flag)") }
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }
    func takeFlag(_ flag: String) -> Bool {
        guard let i = args.firstIndex(of: flag) else { return false }
        args.remove(at: i)
        return true
    }
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n\n\(receiverUsage)\n".utf8))
        exit(2)
    }

    if takeFlag("--help") || takeFlag("-h") {
        print(receiverUsage)
        exit(0)
    }
    if let c = takeValue("--connect") {
        let parts = c.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]), port > 0 else {
            fail("--connect expects host:port, got \(c)")
        }
        options.target = .hostPort(host: String(parts[0]), port: port)
    }
    if takeFlag("--browse") { options.target = .browse }
    if let s = takeValue("--sender") { options.senderName = s }
    if takeFlag("--list-senders") { options.listSeconds = 2.5 }
    if let v = takeValue("--list-seconds") { options.listSeconds = Double(v) ?? 2.5 }
    options.headless = takeFlag("--headless")
    if takeFlag("--no-p2p") { options.peerToPeer = false }
    if let k = takeValue("--key") { options.passphrase = k }
    if let e = takeValue("--exit-after") {
        guard let s = Int(e), s > 0 else { fail("invalid --exit-after \(e)") }
        options.exitAfterSeconds = s
    }
    if !args.isEmpty { fail("unknown arguments: \(args.joined(separator: " "))") }
    return options
}

let receiverUsage = """
usage: audiosync-recv [options]

options:
  --connect <host:port>  connect to a specific sender (e.g. macbook.local:7805)
  --browse               discover the first sender via Bonjour (default)
  --sender <name>        with --browse, connect only to the sender with this
                         exact Bonjour name (from --list-senders)
  --list-senders         list discovered senders (sender=<name> lines) and exit
  --list-seconds <secs>  how long to browse in --list-senders mode (default 2.5)
  --headless             run the full pipeline but don't open the speakers
                         (for testing); prints fill statistics
  --exit-after <secs>    exit automatically after N seconds (for testing)
  --no-p2p               disable the peer-to-peer (AWDL) link; use only the
                         router (try if audio gets worse with p2p enabled)
  --key <passphrase>     decrypt an encrypted stream (must match the
                         sender's --key)
"""

let options = parseReceiverOptions()

// Discovery-only mode: browse Bonjour for a couple of seconds, print each
// sender's friendly name as `sender=<name>`, then exit. The app uses this to
// offer a picker when more than one sender is on the network.
var discoveryBrowser: NWBrowser?
if let seconds = options.listSeconds {
    let browser = NWBrowser(for: .bonjour(type: "_audiosync._udp", domain: nil), using: .udp)
    discoveryBrowser = browser
    var seen = Set<String>()
    browser.browseResultsChangedHandler = { results, _ in
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint, seen.insert(name).inserted {
                FileHandle.standardError.write(Data("sender=\(name)\n".utf8))
            }
        }
    }
    browser.start(queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        FileHandle.standardError.write(Data("sender-list-done\n".utf8))
        exit(0)
    }
    dispatchMain()
}

// Top-level globals: these must outlive the setup code below. (A `let`
// inside a switch-case block is released when the block ends, which would
// cancel the browser/engine.)
var playback: SyncedPlayer?
var headless: HeadlessRenderer?
var statsTimer: DispatchSourceTimer?
var vizTimer: DispatchSourceTimer?
var client: ReceiverClient!

func startPipeline() {
    if options.headless {
        let renderer = HeadlessRenderer(client: client)
        renderer.start()
        headless = renderer
    } else {
        let receiverClient = client! // capture strongly for the render thread
        let player = SyncedPlayer(buffer: receiverClient.buffer) { hostNs in
            receiverClient.sync.masterNs(forClientNs: hostNs)
        }
        do {
            try player.start()
        } catch {
            log("failed to start playback: \(error)")
            exit(1)
        }
        playback = player
        log("playback engine started (\(Int(SyncedPlayer.defaultSampleRate)) Hz, \(SyncedPlayer.defaultChannels)ch)")
        startVizTimer()
    }
    startStatsTimer()
}

/// Emit the real audio spectrum ~24×/s on a compact `viz=` line (hex bytes,
/// one per band) for the app's visualizer. Not a log line — the app filters
/// these out of the activity log. Only runs with real playback (not headless).
func startVizTimer() {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    timer.schedule(deadline: .now() + 0.2, repeating: 1.0 / 24.0)
    timer.setEventHandler {
        guard let bands = playback?.spectrum.bands() else { return }
        var hex = "viz="
        hex.reserveCapacity(4 + bands.count * 2)
        for v in bands {
            let byte = Int((min(1, max(0, v)) * 255).rounded())
            hex += String(format: "%02x", byte)
        }
        hex += "\n"
        FileHandle.standardError.write(Data(hex.utf8))
    }
    timer.resume()
    vizTimer = timer
}

func startStatsTimer() {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    timer.schedule(deadline: .now() + 1, repeating: 1)
    var lastLateCount = 0
    timer.setEventHandler {
        let accumulator = options.headless ? headless!.stats : playback!.stats
        let (filled, silent, unsynced, peak) = accumulator.drain()
        let offsetMs = client.sync.offsetNs.map { String(format: "%.3f", Double($0) / 1e6) } ?? "—"
        let rttUs = client.sync.bestRttNs.map { String($0 / 1_000) } ?? "—"
        let driftPpm = client.drift.driftPpm.map { String(format: "%.1f", $0) } ?? "—"
        let bufferedMs = client.buffer.bufferedSpanNs / 1_000_000
        let total = max(1, filled + silent + unsynced)
        // Minimum arrival margin this second = latency headroom. Drain once
        // and reuse for both the log line and the upstream feedback report.
        let marginDrain = client.margin.drain()
        var marginText = "—"
        if let m = marginDrain {
            marginText = String(format: "%.0f", Double(m.minNs) / 1e6)
            if m.minNs < 15_000_000 {
                marginText += "ms (LOW — raise sender --buffer-ms)"
            } else {
                marginText += "ms"
            }
        }

        // Report health upstream so the sender can adapt its buffer to the
        // worst-case receiver. Only while actively receiving (margin present),
        // so a reconnecting receiver's gap doesn't mislead the controller.
        if let m = marginDrain {
            let lateNow = client.buffer.lateCount
            let lateDelta = max(0, lateNow - lastLateCount)
            lastLateCount = lateNow
            // Fill for the controller counts only playable frames: `silent`
            // is a real underrun, but `unsynced` is just clock warmup at
            // startup — excluding it avoids a spurious buffer bump on connect.
            let playable = max(1, filled + silent)
            client.sendFeedback(Feedback(
                marginMinMs: Int32(clamping: m.minNs / 1_000_000),
                lateCount: UInt32(clamping: lateDelta),
                fillPermille: UInt32(clamping: filled * 1000 / playable),
                bufferedMs: UInt32(clamping: client.buffer.bufferedSpanNs / 1_000_000),
                rttMs: UInt32(clamping: (client.sync.bestRttNs ?? 0) / 1_000_000)
            ))
        }

        log("sync offset=\(offsetMs)ms rtt=\(rttUs)µs drift=\(driftPpm)ppm | " +
            "buffered=\(bufferedMs)ms margin=\(marginText) filled=\(filled) silent=\(silent) unsynced=\(unsynced) " +
            "(\(filled * 100 / total)% fill) peak=\(String(format: "%.2f", peak)) | pkts=\(client.audioPacketsReceived) " +
            "dup=\(client.buffer.duplicateCount) late=\(client.buffer.lateCount) " +
            "tsJit=\(client.timestampJitterCount) decodeErr=\(client.decodeErrors)")
    }
    timer.resume()
    statsTimer = timer
}

func scheduleExitIfRequested() {
    guard let seconds = options.exitAfterSeconds else { return }
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) {
        log("exiting after \(seconds)s (--exit-after)")
        exit(0)
    }
}

// The client owns discovery and reconnection internally now: it keeps the
// audio engine, jitter buffer and clock estimate alive for the whole
// process and only rebuilds its connection (re-resolving the sender's port
// over Bonjour) when the network changes. `startPipeline` runs once, on the
// first successful connect.
switch options.target {
case .hostPort(let host, let port):
    client = ReceiverClient(host: host, port: port, peerToPeer: options.peerToPeer, passphrase: options.passphrase) {
        startPipeline()
    }
case .browse:
    client = ReceiverClient(target: .browse(serviceName: options.senderName), peerToPeer: options.peerToPeer, passphrase: options.passphrase) {
        startPipeline()
    }
}
client.start()

scheduleExitIfRequested()
dispatchMain()
