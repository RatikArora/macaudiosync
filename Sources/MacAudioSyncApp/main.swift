import SwiftUI
import AppKit

// MacAudioSync — play one Mac's audio on every Mac in the room, in sync.
// This app is a thin shell over the audiosync-send / audiosync-recv engines.

struct MacAudioSyncRootApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 560)
        }
        .defaultSize(width: 540, height: 600)
    }
}

enum Role {
    case none, sender, receiver
}

struct ContentView: View {
    @State private var role: Role = .none
    @State private var showAbout = false
    @StateObject private var engine = EngineProcess()

    var body: some View {
        ZStack {
            // Subtle brand wash behind everything.
            LinearGradient(
                colors: [Color(red: 0.32, green: 0.18, blue: 0.92).opacity(0.10),
                         Color(red: 0.10, green: 0.52, blue: 1.00).opacity(0.04),
                         Color.clear],
                startPoint: .topLeading, endPoint: .bottom
            )
            .ignoresSafeArea()

            Group {
                switch role {
                case .none: RolePickerView(role: $role, showAbout: $showAbout)
                case .sender: SenderView(role: $role, engine: engine)
                case .receiver: ReceiverView(role: $role, engine: engine)
                }
            }
            .padding(26)
        }
        .animation(.easeInOut(duration: 0.18), value: role)
        .sheet(isPresented: $showAbout) { AboutSheet() }
    }
}

// MARK: - App logo (mirrors the icon)

struct AppLogo: View {
    var size: CGFloat = 76

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.32, green: 0.18, blue: 0.92),
                             Color(red: 0.10, green: 0.52, blue: 1.00)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .shadow(color: .black.opacity(0.25), radius: size * 0.10, y: size * 0.05)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Role picker

struct RolePickerView: View {
    @Binding var role: Role
    @Binding var showAbout: Bool
    @State private var logoTaps = 0
    @State private var burstID = 0
    @State private var showBurst = false
    @State private var logoSpin = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 4)

            AppLogo()
                .rotationEffect(.degrees(logoSpin ? 360 : 0))
                .onTapGesture { logoTapped() }
                .help("What happens if you keep tapping?")

            VStack(spacing: 6) {
                Text("MacAudioSync")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Every Mac in the room. One perfectly synced sound.")
                    .foregroundStyle(.secondary)
            }

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
            .padding(.top, 6)

            // How it works, in one breath.
            HStack(spacing: 14) {
                HowToStep(number: "1", text: "Open this on every Mac")
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).imageScale(.small)
                HowToStep(number: "2", text: "One sends, the rest receive")
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).imageScale(.small)
                HowToStep(number: "3", text: "Same beat, same instant")
            }
            .padding(.top, 8)

            Spacer()

            HStack(spacing: 4) {
                Text("Made with")
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .imageScale(.small)
                Text("by Ratik Arora")
                Text("·").foregroundStyle(.tertiary)
                Button("About") { showAbout = true }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .overlay {
            if showBurst {
                EmojiBurst().id(burstID).allowsHitTesting(false)
            }
        }
    }

    private func logoTapped() {
        logoTaps += 1
        if logoTaps % 5 == 0 {
            // 🥚 Five taps: the logo drops the beat.
            withAnimation(.spring(response: 0.8, dampingFraction: 0.55)) { logoSpin.toggle() }
            burstID += 1
            showBurst = true
            NSSound(named: "Funk")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { showBurst = false }
        }
    }
}

struct HowToStep: View {
    let number: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(number)
                .font(.caption2.bold())
                .frame(width: 16, height: 16)
                .background(Circle().fill(.tint.opacity(0.2)))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RoleCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                Text(title).font(.title2.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(hovering ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.center)
            }
            .frame(width: 180, height: 150)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(hovering
                          ? AnyShapeStyle(LinearGradient(
                                colors: [Color(red: 0.32, green: 0.18, blue: 0.92),
                                         Color(red: 0.10, green: 0.52, blue: 1.00)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(.quaternary.opacity(0.5)))
            )
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .scaleEffect(hovering ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
    }
}

// MARK: - Sender

struct SenderView: View {
    @Binding var role: Role
    @ObservedObject var engine: EngineProcess
    @AppStorage("bufferMs") private var bufferMs = 250.0
    @AppStorage("playLocally") private var playLocally = true

    /// Party mode (mute original + play synced locally) needs the Core Audio
    /// process-tap API from macOS 14.2. Older Macs fall back to capture mode.
    private var supportsParty: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeaderBar(title: "Sender", role: $role, engine: engine)

            StatusRow(
                running: engine.isRunning,
                text: engine.isRunning ? engine.statusText : "Not streaming"
            )

            if engine.isRunning {
                FleetView(clients: engine.clients)
            }

            SettingsCard {
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
            }

            BigButton(
                title: engine.isRunning ? "Stop Streaming" : "Start Streaming",
                running: engine.isRunning
            ) {
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
            }

            if let error = engine.errorText {
                ErrorText(error)
            }

            Text(supportsParty
                 ? "While streaming, this Mac's normal audio output is muted and replaced by the synced stream — every speaker plays together. First run asks for System Audio Recording permission."
                 : "This Mac is on an older macOS: its own speakers will play ahead of the receivers — mute them and let the receivers be the speakers. First run asks for Screen Recording permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LogsSection(lines: engine.logLines)
        }
    }
}

// MARK: - Receiver

struct ReceiverView: View {
    @Binding var role: Role
    @ObservedObject var engine: EngineProcess

    private var isLoud: Bool { engine.peak > 0.95 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeaderBar(title: "Receiver", role: $role, engine: engine)

            StatusRow(
                running: engine.isRunning && (engine.fillPercent ?? 0) > 0,
                text: (engine.connectedTo.map { "Playing from \($0)" } ?? engine.statusText)
                    + (isLoud ? "  🔥" : "")
            )

            if engine.isRunning, engine.connectedTo != nil {
                // Live level visualizer — the proof there's music in the air.
                SettingsCard {
                    EQView(level: engine.peak, loud: isLoud)
                        .frame(maxWidth: .infinity)
                }

                // The number that justifies this whole app.
                if let jitter = engine.syncJitterUs {
                    SyncHeroRow(jitterUs: jitter, rttUs: engine.rttUs)
                }

                SettingsCard {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Stream health").font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: Double(engine.fillPercent ?? 0), total: 100)
                            Text("\(engine.fillPercent ?? 0)%").font(.caption).monospacedDigit()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Safety buffer").font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: min(Double(max(engine.marginMs ?? 0, 0)), 150), total: 150)
                                .tint((engine.marginMs ?? 0) < 20 ? .orange : nil)
                            Text("\(max(engine.marginMs ?? 0, 0)) ms headroom")
                                .font(.caption).monospacedDigit()
                        }
                    }
                }
            }

            BigButton(
                title: engine.isRunning ? "Stop" : "Start Listening",
                running: engine.isRunning
            ) {
                if engine.isRunning {
                    engine.stop()
                } else {
                    engine.autoRestart = true
                    engine.start(engine: "audiosync-recv", arguments: [])
                }
            }

            if let error = engine.errorText {
                ErrorText(error)
            }

            Text("Finds the sender automatically over Wi-Fi (Bonjour) and reconnects by itself if anything drops. Allow \"local network\" access if macOS asks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LogsSection(lines: engine.logLines)
        }
        .onAppear {
            if !engine.isRunning {
                engine.autoRestart = true
                engine.start(engine: "audiosync-recv", arguments: [])
            }
        }
    }
}

// MARK: - Music-first widgets

/// Animated equalizer bars driven by the live output level.
struct EQView: View {
    let level: Double // 0...1+
    let loud: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let amp = min(level * 1.3, 1.0)
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<21, id: \.self) { i in
                    let phase = Double(i) * 0.83
                    let speed = 5.0 + Double((i * 7) % 9)
                    let wiggle = (sin(t * speed + phase) + 1) / 2
                    let height = amp <= 0.004 ? 3.0 : 4.0 + wiggle * 40.0 * amp
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(
                            colors: loud
                                ? [.orange, .pink]
                                : [Color(red: 0.32, green: 0.18, blue: 0.92),
                                   Color(red: 0.10, green: 0.52, blue: 1.00)],
                            startPoint: .bottom, endPoint: .top))
                        .frame(width: 6, height: height)
                }
            }
            .frame(height: 48)
            .animation(nil, value: t)
        }
    }
}

/// The headline: how tightly this Mac is locked to the sender's clock,
/// translated into something physical.
struct SyncHeroRow: View {
    let jitterUs: Int
    let rttUs: Int?

    /// Sound covers ~0.343 mm per microsecond.
    private var soundDistance: String {
        let mm = Double(jitterUs) * 0.343
        if mm < 10 { return String(format: "%.1f mm", mm) }
        if mm < 1000 { return String(format: "%.0f cm", mm / 10) }
        return String(format: "%.1f m", mm / 1000)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "metronome.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Locked to the sender's clock within ±\(jitterUs) µs")
                    .font(.subheadline.bold())
                Text("Sound itself only travels \(soundDistance) in that time" +
                     (rttUs.map { " · Wi-Fi ping \(String(format: "%.1f", Double($0) / 1000)) ms" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.32, green: 0.18, blue: 0.92).opacity(0.18),
                             Color(red: 0.10, green: 0.52, blue: 1.00).opacity(0.10)],
                    startPoint: .leading, endPoint: .trailing))
        )
    }
}

/// The sender's fleet: one speaker per connected receiver, beaming.
struct FleetView: View {
    let clients: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "laptopcomputer")
                .font(.title2)
                .foregroundStyle(.tint)
            Image(systemName: "wave.3.right")
                .font(.callout)
                .foregroundStyle(clients > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .symbolEffectIfAvailable(active: clients > 0)
            if clients == 0 {
                Text("Waiting for receivers — open the app on another Mac and tap Receive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(0..<min(clients, 8), id: \.self) { _ in
                        Image(systemName: "hifispeaker.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .transition(.scale.combined(with: .opacity))
                    }
                    if clients > 8 { Text("+\(clients - 8)").font(.caption.bold()) }
                }
                Text(clients == 1 ? "1 Mac locked to this beat" : "\(clients) Macs locked to this beat")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.spring(response: 0.4), value: clients)
    }
}

extension View {
    /// Pulse the Wi-Fi waves on macOS 14+; no-op earlier.
    @ViewBuilder
    func symbolEffectIfAvailable(active: Bool) -> some View {
        if #available(macOS 14.0, *), active {
            self.symbolEffect(.variableColor.iterative, options: .repeating)
        } else {
            self
        }
    }
}

// MARK: - Shared components

struct HeaderBar: View {
    let title: String
    @Binding var role: Role
    let engine: EngineProcess

    var body: some View {
        HStack {
            Button {
                engine.stop()
                role = .none
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Spacer()
            Text(title).font(.title2.bold())
            Spacer()
            Label("Back", systemImage: "chevron.left").hidden() // balance
        }
    }
}

struct StatusRow: View {
    let running: Bool
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(running ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
                .shadow(color: running ? .green.opacity(0.6) : .clear, radius: 4)
            Text(text).font(.headline)
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct BigButton: View {
    let title: String
    let running: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity).padding(.vertical, 2)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(running ? .red : .accentColor)
    }
}

struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(3)
    }
}

// MARK: - Logs

struct LogsSection: View {
    let lines: [String]
    @AppStorage("logsExpanded") private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Label("Logs", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderless)
                Spacer()
                if expanded {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy all log lines")
                }
            }

            if expanded {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    .frame(minHeight: 120)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onChange(of: lines.count) { _ in
                        proxy.scrollTo("bottom")
                    }
                    .onAppear { proxy.scrollTo("bottom") }
                }
            }
        }
        .frame(maxHeight: expanded ? .infinity : nil, alignment: .top)
    }
}

// MARK: - About

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var versionTaps = 0

    var body: some View {
        VStack(spacing: 14) {
            AppLogo(size: 64)
            Text("MacAudioSync")
                .font(.title.bold())
            Text("Every Mac in the room, one perfectly synced speaker system.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider().padding(.horizontal, 30)

            VStack(spacing: 8) {
                Text("Built by **Ratik Arora**, pair-programmed with Claude — from a \"can two MacBooks play the same song together?\" idea to clock-synchronized audio streaming in one sitting.")
                Text("Receivers align to the sender's clock with NTP-style sync over Wi-Fi — typically within a few **microseconds**. Sound needs ~3 ms just to cross one metre of air; the network sync is not the weakest link in the room. 🎯")
            }
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .fixedSize(horizontal: false, vertical: true)

            if let url = URL(string: "https://github.com/RatikArora/macaudiosync") {
                Link(destination: url) {
                    Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }

            Text("Version 1.1")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .onTapGesture {
                    versionTaps += 1
                    if versionTaps == 3 { NSSound(named: "Glass")?.play() }
                }

            if versionTaps >= 3 {
                // 🥚 Three taps on the version number.
                Text("🤫 First ever two-Mac sync test: 13 µs apart.\nSonos, you may call us.")
                    .font(.caption.italic())
                    .foregroundStyle(.purple)
                    .multilineTextAlignment(.center)
                    .transition(.scale.combined(with: .opacity))
            }

            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .animation(.spring(response: 0.4), value: versionTaps >= 3)
        .padding(28)
        .frame(width: 400)
    }
}

// MARK: - Easter egg: emoji burst

struct EmojiBurst: View {
    private let emojis = ["🎵", "🎶", "🎧", "🔊", "💜", "✨", "🪩", "🎉"]

    var body: some View {
        GeometryReader { geo in
            ForEach(0..<16, id: \.self) { i in
                BurstParticle(
                    emoji: emojis[i % emojis.count],
                    startX: CGFloat.random(in: 20...(geo.size.width - 20)),
                    height: geo.size.height,
                    delay: Double(i) * 0.06
                )
            }
        }
    }
}

struct BurstParticle: View {
    let emoji: String
    let startX: CGFloat
    let height: CGFloat
    let delay: Double
    @State private var up = false

    var body: some View {
        Text(emoji)
            .font(.system(size: CGFloat.random(in: 20...34)))
            .position(x: startX, y: up ? -30 : height + 30)
            .opacity(up ? 0.9 : 1)
            .rotationEffect(.degrees(up ? Double.random(in: -40...40) : 0))
            .onAppear {
                withAnimation(.easeOut(duration: Double.random(in: 1.4...2.2)).delay(delay)) {
                    up = true
                }
            }
    }
}

// Entry point (main.swift can't use @main with top-level code).
MacAudioSyncRootApp.main()
