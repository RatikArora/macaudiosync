// swift-tools-version:6.0
import PackageDescription

// Language mode v5: the networking/audio executables use shared mutable
// state guarded by locks/queues, which Swift 6 strict concurrency would
// reject without a larger rework.
let v5 : [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "MacAudioSync",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SyncCore", targets: ["SyncCore"]),
        .executable(name: "audiosync-send", targets: ["AudioSyncSender"]),
        .executable(name: "audiosync-recv", targets: ["AudioSyncReceiver"]),
    ],
    targets: [
        // Pure logic: wire protocol, clock sync, jitter buffer, timeline
        // renderer. No networking or audio-hardware dependencies, so it is
        // fully unit-testable.
        .target(name: "SyncCore", swiftSettings: v5),
        // Shared synced-playback engine (AVAudioEngine + TimelineRenderer):
        // used by receivers, and by the sender in --party mode to play its
        // own delayed timeline locally.
        .target(name: "AudioPipeline", dependencies: ["SyncCore"], swiftSettings: v5),
        .executableTarget(name: "AudioSyncSender", dependencies: ["SyncCore", "AudioPipeline"], swiftSettings: v5),
        .executableTarget(name: "AudioSyncReceiver", dependencies: ["SyncCore", "AudioPipeline"], swiftSettings: v5),
        // Thin SwiftUI shell: drives the two CLI executables as child
        // processes and shows their status. No audio/network code of its own.
        .executableTarget(name: "MacAudioSyncApp", swiftSettings: v5),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore", "AudioPipeline"], swiftSettings: v5),
    ]
)
