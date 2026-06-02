import Foundation
import Network
import SyncCore

// audiosync-recv — receiver side. Connects to a sender, synchronizes to its
// master clock, and plays the stream through the default output device at
// the master-scheduled time.

struct ReceiverOptions {
    var target: Target = .browse
    var headless = false
    var exitAfterSeconds: Int? = nil

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
    options.headless = takeFlag("--headless")
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
  --headless             run the full pipeline but don't open the speakers
                         (for testing); prints fill statistics
  --exit-after <secs>    exit automatically after N seconds (for testing)
"""

let options = parseReceiverOptions()

// Top-level globals: these must outlive the setup code below. (A `let`
// inside a switch-case block is released when the block ends, which would
// cancel the browser/engine.)
var playback: PlaybackEngine?
var headless: HeadlessRenderer?
var statsTimer: DispatchSourceTimer?
var browser: NWBrowser?
var client: ReceiverClient!

func startPipeline() {
    if options.headless {
        let renderer = HeadlessRenderer(client: client)
        renderer.start()
        headless = renderer
    } else {
        let engine = PlaybackEngine(client: client)
        do {
            try engine.start()
        } catch {
            log("failed to start playback: \(error)")
            exit(1)
        }
        playback = engine
    }
    startStatsTimer()
}

func startStatsTimer() {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        let accumulator = options.headless ? headless!.stats : playback!.stats
        let (filled, silent, unsynced) = accumulator.drain()
        let offsetMs = client.sync.offsetNs.map { String(format: "%.3f", Double($0) / 1e6) } ?? "—"
        let rttUs = client.sync.bestRttNs.map { String($0 / 1_000) } ?? "—"
        let driftPpm = client.drift.driftPpm.map { String(format: "%.1f", $0) } ?? "—"
        let bufferedMs = client.buffer.bufferedSpanNs / 1_000_000
        let total = max(1, filled + silent + unsynced)
        log("sync offset=\(offsetMs)ms rtt=\(rttUs)µs drift=\(driftPpm)ppm | " +
            "buffered=\(bufferedMs)ms filled=\(filled) silent=\(silent) unsynced=\(unsynced) " +
            "(\(filled * 100 / total)% fill) | pkts=\(client.audioPacketsReceived) " +
            "dup=\(client.buffer.duplicateCount) late=\(client.buffer.lateCount) " +
            "decodeErr=\(client.decodeErrors)")
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

switch options.target {
case .hostPort(let host, let port):
    client = ReceiverClient(host: host, port: port) {
        startPipeline()
    }
    client.start()

case .browse:
    log("browsing for senders (_audiosync._udp)...")
    let nwBrowser = NWBrowser(for: .bonjour(type: "_audiosync._udp", domain: nil), using: .udp)
    browser = nwBrowser
    var connected = false
    nwBrowser.browseResultsChangedHandler = { results, _ in
        guard !connected, let first = results.first else { return }
        connected = true
        log("found sender: \(first.endpoint)")
        nwBrowser.cancel()
        client = ReceiverClient(endpoint: first.endpoint) {
            startPipeline()
        }
        client.start()
    }
    nwBrowser.start(queue: DispatchQueue(label: "audiosync.recv.browse"))
}

scheduleExitIfRequested()
dispatchMain()
