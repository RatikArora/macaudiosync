import SwiftUI

// MacAudioSync — play one Mac's audio on every Mac in the room, in sync.
// This app is a thin shell over the audiosync-send / audiosync-recv engines.

struct MacAudioSyncRootApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 460, height: 480)
        }
        .windowResizability(.contentSize)
    }
}

enum Role {
    case none, sender, receiver
}

struct ContentView: View {
    @State private var role: Role = .none
    @StateObject private var engine = EngineProcess()

    var body: some View {
        VStack(spacing: 0) {
            switch role {
            case .none: RolePickerView(role: $role)
            case .sender: SenderView(role: $role, engine: engine)
            case .receiver: ReceiverView(role: $role, engine: engine)
            }
        }
        .padding(24)
    }
}

// MARK: - Role picker

struct RolePickerView: View {
    @Binding var role: Role

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("MacAudioSync")
                .font(.largeTitle.bold())
            Text("Play one Mac's audio on every Mac on the Wi-Fi — in sync.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                RoleCard(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Send",
                    subtitle: "This Mac plays the music"
                ) { role = .sender }
                RoleCard(
                    icon: "hifispeaker.2.fill",
                    title: "Receive",
                    subtitle: "This Mac is a speaker"
                ) { role = .receiver }
            }
            Spacer()
            Text("Both Macs must be on the same Wi-Fi network.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

struct RoleCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 34))
                Text(title).font(.title2.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 170, height: 140)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

// MARK: - Sender

struct SenderView: View {
    @Binding var role: Role
    @ObservedObject var engine: EngineProcess
    @AppStorage("bufferMs") private var bufferMs = 250.0
    @AppStorage("playLocally") private var playLocally = true

    /// Party mode (mute original + play synced locally) needs the Core Audio
    /// process-tap API from macOS 14.2. Older Macs fall back to capture mode
    /// (ScreenCaptureKit): everything still works, but the sender's own
    /// speakers play ahead — the user should mute them or use receivers as
    /// the speakers.
    private var supportsParty: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(title: "Sender", role: $role, engine: engine)

            StatusRow(
                running: engine.isRunning,
                text: engine.isRunning ? "\(engine.statusText) — \(engine.clients) receiver\(engine.clients == 1 ? "" : "s") connected" : "Not streaming"
            )

            if supportsParty {
                Toggle("Play through this Mac's speakers too (in sync)", isOn: $playLocally)
                    .disabled(engine.isRunning)
            }

            HStack {
                Text("Latency buffer")
                Slider(value: $bufferMs, in: 100...500, step: 50)
                    .disabled(engine.isRunning)
                Text("\(Int(bufferMs)) ms").monospacedDigit().frame(width: 56, alignment: .trailing)
            }
            Text("Higher = more resistant to Wi-Fi hiccups. 250 ms is a good default.")
                .font(.caption).foregroundStyle(.tertiary)

            Button {
                if engine.isRunning {
                    engine.stop()
                } else {
                    var args = ["--buffer-ms", String(Int(bufferMs))]
                    if supportsParty {
                        args.append("--party")
                        if !playLocally { args.append("--no-local-play") }
                    } else {
                        args.append("--capture")
                    }
                    engine.autoRestart = false
                    engine.start(engine: "audiosync-send", arguments: args)
                }
            } label: {
                Text(engine.isRunning ? "Stop Streaming" : "Start Streaming")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(engine.isRunning ? .red : .accentColor)

            if let error = engine.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            Text(supportsParty
                 ? "While streaming, this Mac's normal audio output is muted and replaced by the synced stream — every speaker plays together. First run asks for System Audio Recording permission."
                 : "This Mac is on an older macOS: its own speakers will play ahead of the receivers — mute them and let the receivers be the speakers. First run asks for Screen Recording permission.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LogView(lines: engine.logLines)
        }
    }
}

// MARK: - Receiver

struct ReceiverView: View {
    @Binding var role: Role
    @ObservedObject var engine: EngineProcess

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(title: "Receiver", role: $role, engine: engine)

            StatusRow(
                running: engine.isRunning && engine.fillPercent ?? 0 > 0,
                text: engine.connectedTo.map { "Playing from \($0)" } ?? engine.statusText
            )

            if engine.isRunning, engine.connectedTo != nil {
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("Stream health").font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: Double(engine.fillPercent ?? 0), total: 100)
                        Text("\(engine.fillPercent ?? 0)%").font(.caption).monospacedDigit()
                    }
                    VStack(alignment: .leading) {
                        Text("Level").font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: min(engine.peak, 1.0))
                        Text(engine.peak > 0.005 ? "playing" : "silent").font(.caption)
                    }
                }
            }

            Button {
                if engine.isRunning {
                    engine.stop()
                } else {
                    engine.autoRestart = true
                    engine.start(engine: "audiosync-recv", arguments: [])
                }
            } label: {
                Text(engine.isRunning ? "Stop" : "Start Listening")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(engine.isRunning ? .red : .accentColor)

            if let error = engine.errorText {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }

            Text("Finds the sender automatically over Wi-Fi (Bonjour). Allow \"local network\" access if macOS asks.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LogView(lines: engine.logLines)
        }
        .onAppear {
            if !engine.isRunning {
                engine.autoRestart = true
                engine.start(engine: "audiosync-recv", arguments: [])
            }
        }
    }
}

// MARK: - Shared bits

@ViewBuilder
func header(title: String, role: Binding<Role>, engine: EngineProcess) -> some View {
    HStack {
        Button {
            engine.stop()
            role.wrappedValue = .none
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .buttonStyle(.borderless)
        Spacer()
        Text(title).font(.title2.bold())
        Spacer()
        // Balance the back button so the title centers.
        Label("Back", systemImage: "chevron.left").hidden()
    }
}

struct StatusRow: View {
    let running: Bool
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(running ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
            Text(text).font(.headline)
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.suffix(60).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) { _ in
                proxy.scrollTo("bottom")
            }
        }
    }
}

// Entry point (main.swift can't use @main with top-level code).
MacAudioSyncRootApp.main()
