import SwiftUI
import AppKit

// Sonar — play one Mac's audio on every Mac in the room, in sync.
// This app is a thin shell over the audiosync-send / audiosync-recv engines.

struct MacAudioSyncRootApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 460, minHeight: 540)
        }
        .defaultSize(width: 480, height: 600)
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
        Group {
            switch role {
            case .none: RolePickerView(role: $role, showAbout: $showAbout)
            case .sender: SenderView(role: $role, engine: engine)
            case .receiver: ReceiverView(role: $role, engine: engine)
            }
        }
        .padding(24)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: role)
        .sheet(isPresented: $showAbout) { AboutSheet() }
    }
}

// MARK: - App logo (mirrors the icon)

/// Graphite surface matching the icon. The ripple mark sits on it.
let brandInk = Color(red: 0.12, green: 0.12, blue: 0.135)

/// The signature sonar accent — a single electric teal used only for the
/// ripple mark, the searching pulse and active state indicators. One accent,
/// used sparingly, so it always reads as meaningful.
let sonarTeal = Color(red: 0.00, green: 0.82, blue: 0.93)

struct AppLogo: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(brandInk)
                .shadow(color: .black.opacity(0.22), radius: size * 0.12, y: size * 0.06)
            RipplesMark(tint: sonarTeal)
                .frame(width: size * 0.64, height: size * 0.64)
        }
        .frame(width: size, height: size)
    }
}

/// The signature mark: concentric sound ripples around a luminous core — one
/// source, one sound, radiating in sync. Static (logo / icon); the receiver's
/// searching state animates the same motif via `SearchingRipples`.
struct RipplesMark: View {
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                ring(s: s, scale: 1.00, width: 0.017, opacity: 0.24)
                ring(s: s, scale: 0.733, width: 0.028, opacity: 0.50)
                ring(s: s, scale: 0.467, width: 0.043, opacity: 0.92)
                Circle().fill(tint).frame(width: s * 0.192, height: s * 0.192)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func ring(s: CGFloat, scale: CGFloat, width: CGFloat, opacity: Double) -> some View {
        Circle()
            .stroke(tint.opacity(opacity), lineWidth: s * width)
            .frame(width: s * scale, height: s * scale)
    }
}

// MARK: - Searching animation

/// Sonar ping — the hero searching animation. Teal rings expand and fade from
/// a breathing core, like an actual sonar pulse looking for devices.
struct SearchingRipples: View {
    var size: CGFloat = 160
    private let ripples = 4
    private let period = 2.8
    @State private var go = false

    var body: some View {
        ZStack {
            // Expanding rings — staggered so they flow continuously outward.
            ForEach(0..<ripples, id: \.self) { i in
                Circle()
                    .stroke(sonarTeal, lineWidth: max(1, 2.5 - Double(i) * 0.4))
                    .scaleEffect(go ? 1.0 : 0.04)
                    .opacity(go ? 0.0 : (0.7 - Double(i) * 0.1))
                    .animation(
                        .easeOut(duration: period)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * period / Double(ripples)),
                        value: go
                    )
            }
            // Breathing inner halo — the ambient glow of the core.
            Circle()
                .fill(sonarTeal.opacity(0.12))
                .frame(width: size * 0.35, height: size * 0.35)
                .scaleEffect(go ? 1.0 : 0.80)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: go)
            // The core dot.
            Circle()
                .fill(sonarTeal)
                .frame(width: size * 0.12, height: size * 0.12)
                .shadow(color: sonarTeal.opacity(0.65), radius: go ? 14 : 5)
                .scaleEffect(go ? 1.06 : 0.88)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(0.2), value: go)
        }
        .frame(width: size, height: size)
        .onAppear { go = true }
        .accessibilityLabel("Searching for a sender")
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
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            // Logo + name
            VStack(spacing: 10) {
                AppLogo()
                    .rotationEffect(.degrees(logoSpin ? 360 : 0))
                    .onTapGesture { logoTapped() }
                    .help("What happens if you keep tapping?")
                Text("Sonar")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Every Mac in the room, one sound.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 28)

            // Role cards — full-width, stacked
            VStack(spacing: 10) {
                RoleCard(
                    icon: "waveform.circle.fill",
                    title: "Send",
                    subtitle: "This Mac plays the music",
                    accent: sonarTeal
                ) { role = .sender }
                RoleCard(
                    icon: "speaker.wave.2.circle.fill",
                    title: "Receive",
                    subtitle: "This Mac is a speaker",
                    accent: Color(NSColor.labelColor)
                ) { role = .receiver }
            }

            Spacer(minLength: 24)

            HStack(spacing: 4) {
                Text("Made with").foregroundStyle(.tertiary)
                Image(systemName: "heart.fill").foregroundStyle(.pink).imageScale(.small)
                Text("by Ratik Arora").foregroundStyle(.tertiary)
                Text("·").foregroundStyle(.quaternary)
                Button("About") { showAbout = true }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Spacer(minLength: 8)
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
            withAnimation(.spring(response: 0.8, dampingFraction: 0.55)) { logoSpin.toggle() }
            burstID += 1
            showBurst = true
            NSSound(named: "Funk")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { showBurst = false }
        }
    }
}

struct RoleCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var accent: Color = .accentColor
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon in a tinted circle
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(hovering ? .white : accent)
                    .frame(width: 52, height: 52)
                    .background(
                        Circle().fill(hovering ? accent : accent.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(hovering ? .white : .primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(hovering ? .white.opacity(0.75) : .secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hovering ? Color.white.opacity(0.7) : Color(NSColor.tertiaryLabelColor))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovering ? accent : Color(NSColor.quaternaryLabelColor).opacity(0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(hovering ? Color.clear : Color(NSColor.separatorColor).opacity(0.6), lineWidth: 0.5)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.background)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(pressed ? 0.98 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovering = inside }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
            .onEnded { _ in withAnimation(.spring(response: 0.3)) { pressed = false } }
        )
    }
}

// MARK: - Sender

struct SenderView: View {
    @Binding var role: Role
    @ObservedObject var engine: EngineProcess
    @AppStorage("bufferMs") private var bufferMs = 250.0
    @AppStorage("playLocally") private var playLocally = true
    @AppStorage("streamKey") private var streamKey = ""

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

            if engine.isRunning, let code = engine.joinCode {
                SettingsCard {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Join code").font(.caption).foregroundStyle(.secondary)
                            Text(code).font(.body.monospaced()).textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Only needed if a receiver can't find this Mac automatically — they paste this into Manual Connect.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
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
                Divider()
                HStack {
                    Image(systemName: streamKey.isEmpty ? "lock.open" : "lock.fill")
                        .foregroundStyle(streamKey.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                    SecureField("Password (optional — encrypts the stream)", text: $streamKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(engine.isRunning)
                }
                Text(streamKey.isEmpty
                     ? "No password: anyone on this Wi-Fi could listen. Fine at home; set one on shared networks."
                     : "Encrypted (ChaCha20-Poly1305). Receivers must enter the same password.")
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
                    if !streamKey.isEmpty { args += ["--key", streamKey] }
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
    @AppStorage("streamKey") private var streamKey = ""
    @AppStorage("manualAddress") private var manualAddress = ""

    private var isLoud: Bool { engine.peak > 0.95 }

    private var receiverArgs: [String] {
        var args: [String] = []
        let manual = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { args += ["--connect", manual] }
        if !streamKey.isEmpty { args += ["--key", streamKey] }
        return args
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeaderBar(title: "Receiver", role: $role, engine: engine)

            StatusRow(
                running: engine.isRunning && (engine.fillPercent ?? 0) > 0,
                text: (engine.connectedTo.map { "Playing from \($0)" } ?? engine.statusText)
                    + (isLoud ? "  🔥" : "")
            )

            if engine.isRunning, engine.connectedTo != nil {
                // The hero: flowing waveform + the physics line beneath it.
                VStack(spacing: 8) {
                    WaveformView(level: engine.peak, loud: isLoud)
                        .frame(maxWidth: .infinity)
                    if let jitter = engine.syncJitterUs {
                        Text("Locked to the sender within **±\(jitter) µs** — sound itself travels just \(soundDistance(jitter)) in that time")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let transport = engine.transport {
                        Text("over \(transport)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )

                HStack(spacing: 10) {
                    StatTile(icon: "metronome.fill", title: "Sync",
                             value: engine.syncJitterUs.map { "±\($0) µs" } ?? "—")
                    StatTile(icon: "wifi", title: "Ping",
                             value: engine.rttUs.map { String(format: "%.1f ms", Double($0) / 1000) } ?? "—")
                    StatTile(icon: "shield.lefthalf.filled", title: "Buffer",
                             value: engine.marginMs.map { "\(max($0, 0)) ms" } ?? "—",
                             warn: (engine.marginMs ?? 100) < 20)
                    StatTile(icon: "waveform", title: "Health",
                             value: "\(engine.fillPercent ?? 0)%",
                             warn: (engine.fillPercent ?? 100) < 95)
                }
            }

            // Searching / connecting: the organic ripple loader takes the stage.
            if engine.isRunning, engine.connectedTo == nil {
                VStack(spacing: 16) {
                    SearchingRipples()
                    Text(engine.statusText.isEmpty ? "Looking for a sender…" : engine.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            if !engine.isRunning || engine.connectedTo == nil {
                if let diagnosis = engine.diagnosis {
                    Label(diagnosis, systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                SettingsCard {
                    HStack {
                        Image(systemName: streamKey.isEmpty ? "lock.open" : "lock.fill")
                            .foregroundStyle(streamKey.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                        SecureField("Password (only if the sender set one)", text: $streamKey)
                            .textFieldStyle(.roundedBorder)
                            .disabled(engine.isRunning)
                    }
                    Divider()
                    HStack {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                        TextField("Manual connect — e.g. 192.168.0.107:57239", text: $manualAddress)
                            .textFieldStyle(.roundedBorder)
                            .disabled(engine.isRunning)
                    }
                    Text(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "Leave blank to find the sender automatically over Wi-Fi. If your network blocks discovery, paste the sender's join code here."
                         : "Will connect directly to \(manualAddress.trimmingCharacters(in: .whitespaces)).")
                        .font(.caption).foregroundStyle(.tertiary)
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
                    engine.start(engine: "audiosync-recv", arguments: receiverArgs)
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
                engine.start(engine: "audiosync-recv", arguments: receiverArgs)
            }
        }
    }
}

// MARK: - Music-first widgets

/// Smooth layered waveform driven by the live output level — calm shimmer
/// when quiet, full flowing wave when the music plays.
struct WaveformView: View {
    let level: Double // 0...1+
    let loud: Bool

    private struct Layer {
        let frequency: Double  // wave cycles across the width
        let speed: Double      // phase velocity
        let weight: Double     // relative amplitude
        let opacity: Double
        let lineWidth: Double
    }

    private let layers: [Layer] = [
        Layer(frequency: 1.6, speed: 1.9, weight: 1.00, opacity: 0.95, lineWidth: 2.2),
        Layer(frequency: 2.6, speed: -1.3, weight: 0.62, opacity: 0.45, lineWidth: 1.6),
        Layer(frequency: 3.9, speed: 2.7, weight: 0.38, opacity: 0.25, lineWidth: 1.2),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let midY = size.height / 2
                // Idle shimmer of ~3%, full amplitude with the music.
                let amp = (0.03 + min(level * 1.15, 1.0) * 0.97) * (size.height * 0.42)
                let colors: [Color] = loud
                    ? [.orange, .pink]
                    : [Color.accentColor, Color.accentColor.opacity(0.65)]
                let gradient = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: colors),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                )

                for layer in layers {
                    var path = Path()
                    let steps = 90
                    for i in 0...steps {
                        let x = size.width * Double(i) / Double(steps)
                        let progress = Double(i) / Double(steps)
                        // Taper the wave toward the edges for elegance.
                        let envelope = sin(progress * .pi)
                        let angle = progress * layer.frequency * 2 * .pi + t * layer.speed
                        let y = midY + sin(angle) * amp * layer.weight * envelope
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    ctx.opacity = layer.opacity
                    ctx.stroke(
                        path, with: gradient,
                        style: StrokeStyle(lineWidth: layer.lineWidth, lineCap: .round, lineJoin: .round)
                    )
                }
            }
            .frame(height: 64)
        }
    }
}

/// Sound covers ~0.343 mm per microsecond — turn sync µs into distance.
func soundDistance(_ microseconds: Int) -> String {
    let mm = Double(microseconds) * 0.343
    if mm < 10 { return String(format: "%.1f mm of air", mm) }
    if mm < 1000 { return String(format: "%.0f cm of air", mm / 10) }
    return String(format: "%.1f m of air", mm / 1000)
}

/// Compact metric tile for the receiver dashboard.
struct StatTile: View {
    let icon: String
    let title: String
    let value: String
    var warn = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(warn ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
            Text(value)
                .font(.system(.subheadline, design: .rounded).bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Back")
                        .font(.subheadline)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            // Balance the back button
            Text("Back").font(.subheadline).hidden()
        }
        .padding(.bottom, 4)
    }
}

struct StatusRow: View {
    let running: Bool
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            // Live indicator dot
            ZStack {
                if running {
                    Circle()
                        .fill(Color.green.opacity(0.3))
                        .frame(width: 16, height: 16)
                        .scaleEffect(running ? 1.0 : 0.6)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: running)
                }
                Circle()
                    .fill(running ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
            Text(text)
                .font(.system(size: 14, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
        )
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
            )
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
            Text("Sonar")
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

            Text("Version 2.0")
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
