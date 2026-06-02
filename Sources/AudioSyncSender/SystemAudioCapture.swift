import Foundation
import ScreenCaptureKit
import CoreMedia
import AVFoundation
import SyncCore

/// Captures the Mac's system audio output via ScreenCaptureKit and hands
/// interleaved Float32 blocks (with their capture host-time) to a callback.
///
/// Requires the Screen Recording permission (System Settings > Privacy &
/// Security > Screen Recording) — macOS prompts on first run.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias Block = (_ samples: [Float], _ captureHostNs: UInt64, _ sampleRate: Double, _ channels: Int) -> Void

    private let onAudio: Block
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "audiosync.sender.capture")
    private let sampleRate: Int
    private let channels: Int

    init(sampleRate: Int = 48_000, channels: Int = 2, onAudio: @escaping Block) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.onAudio = onAudio
    }

    func start() async throws {
        // Capturing "the display" with audio enabled is how SCK exposes
        // system-wide audio; we shrink video to 2x2 @ 1fps to keep it cheap
        // and simply never attach a video output.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw RuntimeError("no display found to capture")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = sampleRate
        config.channelCount = channels
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log("system audio capture started (\(sampleRate) Hz, \(channels)ch)")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = formatDescription.audioStreamBasicDescription else { return }

        let frameCount = sampleBuffer.numSamples
        guard frameCount > 0 else { return }
        let bufferChannels = Int(asbd.mChannelsPerFrame)
        guard bufferChannels > 0 else { return }
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else {
            return // SCK delivers Float32 PCM; anything else we don't handle
        }
        let isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        // Capture timestamp (mach host clock — same domain as MonotonicClock).
        let pts = sampleBuffer.presentationTimeStamp
        let ptsSeconds = CMTimeGetSeconds(pts)
        guard ptsSeconds.isFinite, ptsSeconds > 0 else { return }
        let captureHostNs = UInt64(ptsSeconds * 1e9)

        // Copy samples out as interleaved Float32 *inside* the closure — the
        // buffer list memory is only valid within it.
        let interleaved: [Float]? = try? sampleBuffer.withAudioBufferList { ablPointer, _ in
            var out = [Float](repeating: 0, count: frameCount * bufferChannels)
            if isInterleaved {
                guard let buf = ablPointer.first, let data = buf.mData else { return nil }
                let ptr = data.assumingMemoryBound(to: Float.self)
                let n = min(frameCount * bufferChannels, Int(buf.mDataByteSize) / 4)
                for i in 0..<n { out[i] = ptr[i] }
            } else {
                for (ch, buf) in ablPointer.enumerated() where ch < bufferChannels {
                    guard let data = buf.mData else { continue }
                    let ptr = data.assumingMemoryBound(to: Float.self)
                    let n = min(frameCount, Int(buf.mDataByteSize) / 4)
                    for frame in 0..<n { out[frame * bufferChannels + ch] = ptr[frame] }
                }
            }
            return out
        }

        if let interleaved {
            onAudio(interleaved, captureHostNs, asbd.mSampleRate, bufferChannels)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture stopped with error: \(error.localizedDescription)")
        exit(1)
    }
}
