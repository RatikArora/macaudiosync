import Foundation
import AppKit
import CoreAudio

/// Best-effort guess at what this Mac is about to stream, so the app can
/// pre-select the right latency profile (the user always confirms / overrides —
/// we never switch a running stream out from under them, which would cause an
/// audible blip).
///
/// Two signals, in priority order:
///  1. **Microphone in use** → almost certainly a call. This is the strong one:
///     Zoom, Google Meet, Teams, Webex, FaceTime, Slack huddles all open the
///     input device, and CoreAudio exposes that with zero permissions.
///  2. **Frontmost app** is a video player or a browser → probably video.
///
/// Anything else → music (the dropout-first default).
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

enum ContentDetector {

    /// Bundle IDs that mean "a call is (or is about to be) happening". Used as a
    /// backstop to the mic check — e.g. the app is frontmost but hasn't grabbed
    /// the mic yet.
    private static let conferencingApps: Set<String> = [
        "us.zoom.xos",                  // Zoom
        "com.microsoft.teams",          // Teams (classic)
        "com.microsoft.teams2",         // Teams (new)
        "com.cisco.webexmeetingsapp",   // Webex
        "com.webex.meetingmanager",     // Webex (older)
        "com.apple.FaceTime",           // FaceTime
        "com.tinyspeck.slackmacgap",    // Slack (huddles)
        "com.hnc.Discord",              // Discord
        "com.skype.skype",              // Skype
    ]

    /// Bundle IDs whose frontmost-ness suggests video playback. Browsers are
    /// included because YouTube/Netflix/etc. live there — being frontmost isn't
    /// proof a video is playing, so this only matters as a *suggestion*.
    private static let videoApps: Set<String> = [
        "com.apple.QuickTimePlayerX",
        "com.colliderli.iina",
        "org.videolan.vlc",
        "com.apple.TV",                 // Apple TV app
        "com.netflix.Netflix",
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
    ]

    /// Returns the suggested mode for what's currently happening on this Mac.
    static func suggested() -> ContentMode {
        if microphoneInUse() { return .call }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let front {
            if conferencingApps.contains(front) { return .call }
            if videoApps.contains(front) { return .video }
        }
        return .music
    }

    /// True when *something* on this Mac is actively running the default input
    /// device — the standard "is the mic in use" signal (what menu-bar mic
    /// indicators use). No microphone permission required: we only read device
    /// run state, never audio.
    static func microphoneInUse() -> Bool {
        guard let input = defaultInputDevice() else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(input, &addr, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    private static func defaultInputDevice() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
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
