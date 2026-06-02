import Foundation
import SyncCore

// audiosync-send — master side. Captures audio (system audio or a test
// tone), stamps every packet with "play this at master time T", and serves
// the master clock to receivers.

struct SenderOptions {
    var port: UInt16 = 7805
    var mode: Mode = .tone(frequency: 440)
    var bufferDelayMs = 150
    var name = Host.current().localizedName ?? "MacAudioSync"
    var peerToPeer = true

    enum Mode {
        case tone(frequency: Double)
        case capture
    }
}

func parseSenderOptions() -> SenderOptions {
    var options = SenderOptions()
    var args = Array(CommandLine.arguments.dropFirst())
    func takeValue(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag) else { return nil }
        guard i + 1 < args.count else {
            fail("missing value for \(flag)")
        }
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
        FileHandle.standardError.write(Data("error: \(message)\n\n\(senderUsage)\n".utf8))
        exit(2)
    }

    if takeFlag("--help") || takeFlag("-h") {
        print(senderUsage)
        exit(0)
    }
    if let p = takeValue("--port") {
        guard let port = UInt16(p), port > 0 else { fail("invalid --port \(p)") }
        options.port = port
    }
    if let b = takeValue("--buffer-ms") {
        guard let ms = Int(b), (20...5000).contains(ms) else { fail("--buffer-ms must be 20–5000") }
        options.bufferDelayMs = ms
    }
    if let n = takeValue("--name") { options.name = n }
    if takeFlag("--no-p2p") { options.peerToPeer = false }
    let capture = takeFlag("--capture")
    if let i = args.firstIndex(of: "--tone") {
        args.remove(at: i)
        // Frequency value is optional: consume the next token only if it
        // looks like a number (so `--tone --port 7806` keeps working).
        if i < args.count, let freq = Double(args[i]) {
            guard freq > 0, freq < 20_000 else { fail("invalid --tone frequency \(args[i])") }
            args.remove(at: i)
            options.mode = .tone(frequency: freq)
        } else {
            options.mode = .tone(frequency: 440)
        }
    }
    if capture { options.mode = .capture }
    if !args.isEmpty { fail("unknown arguments: \(args.joined(separator: " "))") }
    return options
}

let senderUsage = """
usage: audiosync-send [options]

options:
  --capture            stream the Mac's system audio (needs Screen Recording
                       permission; macOS prompts on first run)
  --tone [freq]        stream a test tone instead (default mode, 440 Hz)
  --port <port>        UDP port to listen on (default 7805)
  --buffer-ms <ms>     playback delay budget, 40–5000 (default 150);
                       larger = more network-jitter headroom, more latency.
                       Watch "margin=" in the receiver's stats to tune:
                       healthy margin minus ~30ms is your safe buffer floor.
  --name <name>        Bonjour service name (default: computer name)
  --no-p2p             disable the peer-to-peer (AWDL) link; use only the
                       router. Try this if audio gets WORSE after enabling
                       Wi-Fi p2p (AWDL channel-hopping can hurt some setups)
"""

let options = parseSenderOptions()

// Top-level globals: audio sources must outlive the setup code below.
// (A `let` inside the switch block would be released when the block ends,
// which cancels its timers/streams.)
var toneSource: ToneSource?
var audioCapture: SystemAudioCapture?

do {
    let server = try SenderServer(port: options.port, serviceName: options.name, peerToPeer: options.peerToPeer)
    server.start()

    switch options.mode {
    case .tone(let frequency):
        let tone = ToneSource(server: server, frequency: frequency, bufferDelayMs: options.bufferDelayMs)
        toneSource = tone
        tone.start()

    case .capture:
        let bufferDelayNs = UInt64(options.bufferDelayMs) * 1_000_000
        let capture = SystemAudioCapture { samples, captureHostNs, sampleRate, channels in
            // Capture PTS is on our (master) clock; receivers play each
            // frame exactly bufferDelay after it was captured.
            server.sendAudio(
                samples: samples,
                firstFramePlayAtNs: captureHostNs + bufferDelayNs,
                sampleRate: sampleRate,
                channels: channels
            )
        }
        audioCapture = capture
        Task {
            do {
                try await capture.start()
            } catch {
                log("failed to start system audio capture: \(error)")
                log("hint: grant Screen Recording permission in System Settings > Privacy & Security")
                exit(1)
            }
        }
    }

    dispatchMain()
} catch {
    log("fatal: \(error)")
    exit(1)
}
