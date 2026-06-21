import Foundation
import SyncCore
import AudioPipeline

// audiosync-send — master side. Captures audio (system audio or a test
// tone), stamps every packet with "play this at master time T", and serves
// the master clock to receivers.

struct SenderOptions {
    // 0 = let the OS pick an ephemeral port (49152–65535). Corporate Wi-Fi
    // controllers sometimes blocklist specific known ports (we hit 7805
    // filtered on one office network); the dynamic range is not. Bonjour
    // publishes the actual port, so --browse receivers don't notice.
    var port: UInt16 = 0
    var mode: Mode = .tone(frequency: 440)
    var bufferDelayMs = 150
    var name = Host.current().localizedName ?? "MacAudioSync"
    var peerToPeer = true
    var localPlayback = true
    var followSystemMute = true
    var adapt = true
    var passphrase: String? = nil
    var latency: LatencyProfile = .music

    enum Mode {
        case tone(frequency: Double)
        case capture
        case party
    }

    /// What you're streaming decides the latency tradeoff. Music can buffer
    /// generously (dropout-free matters, nobody sees lip-sync); video and calls
    /// must stay tight or the sender's own screen drifts out of lip-sync and a
    /// conversation feels laggy. Each profile is a (floor, ceiling) the adaptive
    /// buffer lives within — `--buffer-ms` overrides the floor.
    enum LatencyProfile: String {
        case music   // generous: floor 150, climb to 400 if the network needs it
        case video   // tight: ~100ms so the sender's video stays in lip-sync
        case call    // tight: ~100ms for natural back-and-forth (Zoom/Meet/etc.)

        var defaultFloorMs: Int { self == .music ? 150 : 80 }
        var ceilingMs: Int { self == .music ? 400 : 130 }
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
        guard let port = UInt16(p) else { fail("invalid --port \(p)") }
        options.port = port
    }
    if let l = takeValue("--latency") {
        guard let p = SenderOptions.LatencyProfile(rawValue: l.lowercased()) else {
            fail("--latency must be music, video, or call")
        }
        options.latency = p
        options.bufferDelayMs = p.defaultFloorMs // profile sets the floor…
    }
    if let b = takeValue("--buffer-ms") {
        guard let ms = Int(b), (20...5000).contains(ms) else { fail("--buffer-ms must be 20–5000") }
        options.bufferDelayMs = ms // …an explicit --buffer-ms overrides it
    }
    if let n = takeValue("--name") { options.name = n }
    if takeFlag("--no-p2p") { options.peerToPeer = false }
    if let k = takeValue("--key") { options.passphrase = k }
    let capture = takeFlag("--capture")
    let party = takeFlag("--party") || takeFlag("--capture-mute")
    if takeFlag("--no-local-play") { options.localPlayback = false }
    if takeFlag("--no-follow-mute") { options.followSystemMute = false }
    if takeFlag("--no-adapt") { options.adapt = false }
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
    if party { options.mode = .party }
    if !args.isEmpty { fail("unknown arguments: \(args.joined(separator: " "))") }
    return options
}

let senderUsage = """
usage: audiosync-send [options]

options:
  --party              ZERO perceived latency mode (macOS 14.2+): tap system
                       audio, MUTE the original output, and play the synced
                       delayed timeline through this Mac's speakers too — so
                       every speaker in the room (this Mac + all receivers)
                       plays in unison. Needs "System Audio Recording"
                       permission (macOS prompts on first run).
  --no-local-play      with --party: capture+mute but don't play locally
  --capture            stream the Mac's system audio via ScreenCaptureKit
                       (original keeps playing; needs Screen Recording
                       permission; macOS prompts on first run)
  --tone [freq]        stream a test tone instead (default mode, 440 Hz)
  --port <port>        UDP port to listen on (default 0 = OS-assigned
                       ephemeral port; survives office Wi-Fi that filters
                       specific ports like 7805). Receivers using --browse
                       auto-discover the port via Bonjour; --connect users
                       read it from the sender's startup log.
  --latency <profile>  what you're streaming, which sets the latency tradeoff:
                         music (default) — buffer climbs to 400ms if needed so
                           it never drops out (lip-sync doesn't matter for audio)
                         video — keep it tight (~100ms, ceiling 130) so this
                           Mac's own screen stays in lip-sync with the audio
                         call — tight (~100ms) for natural Zoom/Meet/Teams/
                           FaceTime back-and-forth
  --buffer-ms <ms>     playback delay FLOOR, 20–5000 (overrides the profile
                       floor). Adaptation (on by default) only climbs from here,
                       never below, up to the profile's ceiling. larger = more
                       jitter headroom, more latency. Watch "margin=" in the
                       receiver's stats: healthy margin minus ~30ms is a safe floor.
  --no-adapt           don't auto-raise the buffer; pin it at --buffer-ms for
                       the whole stream (default: the sender ratchets the buffer
                       UP when a receiver reports low margin/fill — each raise is
                       one brief concealed dip — then holds, so audio stops
                       breaking on a jittery network without you touching a flag)
  --name <name>        Bonjour service name (default: computer name)
  --no-follow-mute     don't mute receivers when this Mac is muted (default:
                       muting your Mac mutes the whole room)
  --no-p2p             disable the peer-to-peer (AWDL) link; use only the
                       router. Try this if audio gets WORSE after enabling
                       Wi-Fi p2p (AWDL channel-hopping can hurt some setups)
  --key <passphrase>   encrypt + authenticate the stream (ChaCha20-Poly1305).
                       Receivers must use the same --key. Recommended on any
                       shared Wi-Fi; without it, anyone on the network can
                       listen to this Mac's audio.
"""

let options = parseSenderOptions()

// Top-level globals: audio sources must outlive the setup code below.
// (A `let` inside the switch block would be released when the block ends,
// which cancels its timers/streams.)
var toneSource: ToneSource?
var audioCapture: SystemAudioCapture?
var tapCapture: AnyObject? // ProcessTapCapture (macOS 14.2+ only type)
var localPlayer: SyncedPlayer?
var localBuffer: JitterBuffer?

do {
    let server = try SenderServer(
        port: options.port,
        serviceName: options.name,
        peerToPeer: options.peerToPeer,
        passphrase: options.passphrase,
        bufferDelayMs: options.bufferDelayMs,
        ceilingMs: options.latency.ceilingMs,
        followSystemMute: options.followSystemMute,
        adapt: options.adapt
    )
    if options.passphrase != nil { log("stream encryption: ON (receivers need the same --key)") }
    server.start()

    switch options.mode {
    case .tone(let frequency):
        let tone = ToneSource(server: server, frequency: frequency)
        toneSource = tone
        tone.start()

    case .capture:
        let capture = SystemAudioCapture { samples, captureHostNs, sampleRate, channels in
            // Capture PTS is on our (master) clock; the server adds its
            // adaptive buffer to schedule each frame's play time.
            server.sendAudio(
                samples: samples,
                sourceClockNs: captureHostNs,
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

    case .party:
        guard #available(macOS 14.2, *) else {
            log("--party needs macOS 14.2+ (Core Audio process taps); use --capture instead")
            exit(1)
        }
        // Local synced playback: the sender's own speakers join the fleet,
        // playing the exact same delayed master timeline as every receiver.
        // The master clock is our own clock, so the conversion is identity.
        if options.localPlayback {
            let buffer = JitterBuffer()
            let player = SyncedPlayer(buffer: buffer) { hostNs in hostNs }
            do {
                try player.start()
            } catch {
                log("failed to start local playback: \(error)")
                exit(1)
            }
            localBuffer = buffer
            localPlayer = player
            server.localSink = { chunk in buffer.insert(chunk) }
            log("local synced playback started — this Mac's speakers are part of the fleet")
        }

        let tap = ProcessTapCapture { samples, captureHostNs, sampleRate, channels in
            server.sendAudio(
                samples: samples,
                sourceClockNs: captureHostNs,
                sampleRate: sampleRate,
                channels: channels
            )
        }
        tapCapture = tap
        do {
            try tap.start()
        } catch {
            log("failed to start party mode: \(error)")
            exit(1)
        }
    }

    dispatchMain()
} catch {
    log("fatal: \(error)")
    exit(1)
}
