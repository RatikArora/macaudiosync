import Foundation
import CoreAudio

/// Watches whether the sender Mac's default output is muted (the F10 mute key,
/// or volume dragged to zero) so the sender can silence the whole room when the
/// user mutes — capture taps audio *before* the output volume, so without this
/// muting your own Mac wouldn't mute the receivers.
///
/// Polled every 200 ms rather than using Core Audio property listeners: polling
/// is trivially correct across output-device changes and per-channel vs master
/// mute quirks, and 200 ms latency on a mute toggle is imperceptible here.
final class SystemMuteMonitor {
    private let lock = NSLock()
    private var muted = false
    private var timer: DispatchSourceTimer?

    /// Called (on `queue`) whenever the muted state flips.
    var onChange: ((Bool) -> Void)?

    var isMuted: Bool {
        lock.lock(); defer { lock.unlock() }
        return muted
    }

    func start(queue: DispatchQueue) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func refresh() {
        let now = Self.readMuted()
        lock.lock()
        let changed = now != muted
        muted = now
        lock.unlock()
        if changed { onChange?(now) }
    }

    // MARK: - Core Audio reads

    /// True if the default output device is muted, or its volume is ~zero.
    private static func readMuted() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        // Master mute first; some devices only expose per-channel mute.
        if let m = boolProperty(device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain) {
            if m { return true }
        } else if let l = boolProperty(device, kAudioDevicePropertyMute, element: 1),
                  let r = boolProperty(device, kAudioDevicePropertyMute, element: 2) {
            if l && r { return true }
        }
        // Volume at (or essentially at) zero counts as muted too.
        if let v = floatProperty(device, kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain) {
            return v <= 0.0001
        }
        if let l = floatProperty(device, kAudioDevicePropertyVolumeScalar, element: 1),
           let r = floatProperty(device, kAudioDevicePropertyVolumeScalar, element: 2) {
            return max(l, r) <= 0.0001
        }
        return false
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return (status == noErr && device != kAudioObjectUnknown) ? device : nil
    }

    private static func boolProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func floatProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
