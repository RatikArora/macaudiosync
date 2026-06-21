import Foundation
import AppKit
import CoreAudio

/// What this Mac is about to stream, used only to *suggest* a latency profile —
/// the user always confirms/overrides, and we never switch a running stream
/// (that would cause an audible blip).
///
/// Honesty matters more than coverage here. From captured system audio you
/// CANNOT tell music from video — they're the same PCM. The only thing the OS
/// reliably tells us is whether the microphone is open (→ a call). So we only
/// claim a mode when we're actually sure:
///   • mic in use, or a dedicated conferencing app up front → **call** (sure)
///   • a dedicated video PLAYER up front → **video** (sure)
///   • a browser up front → **unknown**: it could be a music video, a song, a
///     lecture, or a film. We refuse to guess and ask the user to pick.
///   • nothing notable → music (the safe, dropout-first default)
///
/// Browsers are deliberately NOT treated as "video": that was the bug — YouTube
/// (and Twitch, etc.) is just as often music, and forcing the tight video
/// buffer on music risks dropouts.
enum ContentMode: String {
    case music, video, call
    var display: String {
        switch self {
        case .music: return "Music"
        case .video: return "Video"
        case .call: return "Call"
        }
    }
}

/// The detector's read of the moment.
struct ContentSuggestion: Equatable {
    /// Best guess for the default mode.
    var mode: ContentMode = .music
    /// True only when we're confident (mic / conferencing app / video player).
    /// When false, the UI must NOT assert a mode — it asks the user instead.
    var confident: Bool = false
    /// A browser is up front and audio is playing: genuinely ambiguous
    /// (music vs video), so prompt the user to choose rather than guessing.
    var ambiguousBrowser: Bool = false
}

enum ContentDetector {

    /// Apps that mean "a call is happening" even before/without the mic (a
    /// backstop to the mic check).
    private static let conferencingApps: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams", "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
        "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.skype.skype",
        "com.google.meet",            // Google Meet PWA / standalone
    ]

    /// DEDICATED video players only. Browsers are intentionally excluded — see
    /// the type doc: a frontmost browser is not evidence of video.
    private static let videoPlayers: Set<String> = [
        "com.apple.QuickTimePlayerX",
        "com.colliderli.iina",
        "org.videolan.vlc",
        "com.apple.TV",
        "com.netflix.Netflix",
        "tv.plex.player",
        "com.apple.Music.MusicVideo",
    ]

    private static let browsers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",     // Arc
        "company.thebrowser.dia",         // Dia
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    static func suggested() -> ContentSuggestion {
        // 1. Mic open → almost certainly a call (covers Zoom/Meet/Teams/
        //    FaceTime/Slack regardless of what's frontmost). Highest confidence.
        if microphoneInUse() { return ContentSuggestion(mode: .call, confident: true) }

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let front {
            if conferencingApps.contains(front) { return ContentSuggestion(mode: .call, confident: true) }
            if videoPlayers.contains(front) { return ContentSuggestion(mode: .video, confident: true) }
            if browsers.contains(front) {
                // Could be a music video or a song or a film — we can't know.
                // Only nudge if audio is actually playing right now.
                return ContentSuggestion(mode: .music, confident: false,
                                         ambiguousBrowser: outputAudioPlaying())
            }
        }
        // Music apps (Spotify, Apple Music, etc.) and everything else → the
        // safe default. Not "confident" because we're not really detecting
        // music — we just have no reason to leave the default.
        return ContentSuggestion(mode: .music, confident: false)
    }

    /// True when something is actively running the default INPUT device — the
    /// standard "mic in use" signal. No microphone permission needed (we read
    /// device run state, never audio).
    static func microphoneInUse() -> Bool {
        deviceIsRunning(defaultDevice(input: true))
    }

    /// True when something is actively playing through the default OUTPUT —
    /// used only to decide whether a frontmost browser is worth a nudge.
    static func outputAudioPlaying() -> Bool {
        deviceIsRunning(defaultDevice(input: false))
    }

    private static func deviceIsRunning(_ device: AudioObjectID?) -> Bool {
        guard let device else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    private static func defaultDevice(input: Bool) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
}
