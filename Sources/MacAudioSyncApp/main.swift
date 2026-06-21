import SwiftUI
import AppKit

// Sonar — play one Mac's audio on every Mac in the room, in sync.
// This app is a thin shell over the audiosync-send / audiosync-recv engines.
//
// The visual design is a faithful port of the "Synced Ripples" prototype
// (claude.ai/design · MacAudioSync.html): a fixed 480×640 macOS window, a
// single muted-teal "sonar" accent, and the organic ripple loader as the
// searching hero. Light + dark are both first-class.

struct MacAudioSyncRootApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 480, height: 640)
        }
        // Hidden title bar = content fills the whole window (no native title
        // strip above ours) while the traffic-light buttons stay, floating over
        // our bar — one clean unified title bar instead of a stacked double bar.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

enum Role { case none, sender, receiver }

// MARK: - Design tokens (the "Synced Ripples" theme, light + dark)

struct Theme {
    let isDark: Bool

    let winBg, surface, surface2, surface3: Color
    let text, text2, text3: Color
    let sep, sepStrong, field, fieldEdge: Color
    let accent, accentLite, accentStrong, accentText: Color
    let good, goodBg, warn, warnBg, bad, badBg: Color

    /// The single same-hue tonal fill used for primary controls, the ripple
    /// core and the logo mark — dimensional without reading as an AI gradient.
    var grad: LinearGradient {
        LinearGradient(colors: [accentLite, accent, accentStrong],
                       startPoint: .top, endPoint: .bottom)
    }

    static func resolve(_ scheme: ColorScheme) -> Theme {
        scheme == .dark ? .dark : .light
    }

    static let light = Theme(
        isDark: false,
        winBg: Color(hex: 0xFFFFFF), surface: Color(hex: 0xFFFFFF),
        surface2: Color(hex: 0xF4F4F6), surface3: Color(hex: 0xECECEF),
        text: Color(hex: 0x1D1D1F), text2: Color(hex: 0x62626A), text3: Color(hex: 0x9A9AA1),
        sep: .black.opacity(0.09), sepStrong: .black.opacity(0.15),
        field: Color(hex: 0xFFFFFF), fieldEdge: .black.opacity(0.14),
        accent: Color(hex: 0x0E9E92), accentLite: Color(hex: 0x16B6A8),
        accentStrong: Color(hex: 0x0A7E74), accentText: Color(hex: 0x0A7E74),
        good: Color(hex: 0x2EB85F), goodBg: Color(hex: 0x2EB85F).opacity(0.12),
        warn: Color(hex: 0xE8890B), warnBg: Color(hex: 0xE8890B).opacity(0.12),
        bad: Color(hex: 0xE5484D), badBg: Color(hex: 0xE5484D).opacity(0.10)
    )

    static let dark = Theme(
        isDark: true,
        winBg: Color(hex: 0x1C1C1E), surface: Color(hex: 0x1C1C1E),
        surface2: Color(hex: 0x2A2A2C), surface3: Color(hex: 0x38383A),
        text: Color(hex: 0xF5F5F7), text2: Color(hex: 0xA6A6AD), text3: Color(hex: 0x79797F),
        sep: .white.opacity(0.11), sepStrong: .white.opacity(0.18),
        field: Color(hex: 0x2A2A2C), fieldEdge: .white.opacity(0.14),
        accent: Color(hex: 0x29D2C1), accentLite: Color(hex: 0x45E2D2),
        accentStrong: Color(hex: 0x15B0A1), accentText: Color(hex: 0x45E2D2),
        good: Color(hex: 0x32D74B), goodBg: Color(hex: 0x32D74B).opacity(0.14),
        warn: Color(hex: 0xFF9F0A), warnBg: Color(hex: 0xFF9F0A).opacity(0.14),
        bad: Color(hex: 0xFF453A), badBg: Color(hex: 0xFF453A).opacity(0.14)
    )
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.light }
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// True while the app's window is actually on screen. The 60fps visualizer /
/// radar / ripple animations read this and pause when the window is hidden,
/// minimized, or fully occluded — so a backgrounded Sonar costs ~no CPU while
/// the audio engine keeps streaming.
private struct AnimationsActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var animationsActive: Bool {
        get { self[AnimationsActiveKey.self] }
        set { self[AnimationsActiveKey.self] = newValue }
    }
}

/// Tracks whether any Sonar window is visible to the user (occlusion +
/// miniaturization), so we can pause non-essential animation work when it's
/// not. Audio is unaffected — that runs in the engine subprocess.
final class AppActivity: ObservableObject {
    @Published var windowVisible = true

    init() {
        let nc = NotificationCenter.default
        for name: NSNotification.Name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.recompute()
            }
        }
    }

    private func recompute() {
        let visible = !NSApp.isHidden && NSApp.windows.contains { win in
            win.isVisible && !win.isMiniaturized && win.occlusionState.contains(.visible)
        }
        if visible != windowVisible { windowVisible = visible }
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Root

struct ContentView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var role: Role = .none
    @State private var showAbout = false
    @StateObject private var engine = EngineProcess()
    @StateObject private var updater = Updater()
    @StateObject private var activity = AppActivity()

    private var theme: Theme { Theme.resolve(scheme) }

    private var titleText: String {
        switch role {
        case .none: return "Sonar"
        case .sender: return "Sender"
        case .receiver: return "Receiver"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(title: titleText, showBack: role != .none,
                     onBack: { engine.stop(); role = .none },
                     onAbout: { showAbout = true })

            UpdateBanner(updater: updater)

            ScrollView {
                Group {
                    switch role {
                    case .none: RolePickerView(role: $role, updater: updater)
                    case .sender: SenderView(role: $role, engine: engine)
                    case .receiver: ReceiverView(role: $role, engine: engine)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        // Slide our title bar UP under the traffic lights instead of leaving
        // SwiftUI's reserved titlebar safe-area gap above it (that gap was the
        // "second bar"). With hidden-title-bar + this, it's one unified bar.
        .ignoresSafeArea(.all, edges: .top)
        .frame(width: 480, height: 640)
        .background(theme.winBg)
        .background(WindowConfigurator())
        .environment(\.theme, theme)
        .environment(\.animationsActive, activity.windowVisible)
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: role)
        .sheet(isPresented: $showAbout) {
            AboutSheet(updater: updater).environment(\.theme, theme)
        }
        .onAppear { updater.check() }
    }
}

/// A slim bar below the title bar that appears only when an update is in play —
/// available, downloading, or installing — so the update control is right there
/// in the app, not buried in a menu.
struct UpdateBanner: View {
    @Environment(\.theme) private var t
    @ObservedObject var updater: Updater

    var body: some View {
        switch updater.status {
        case .available(let version, _, let url, let sha):
            bar {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(t.accentText)
                Text("Sonar \(version) is available")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(t.text)
                Spacer()
                Button { updater.downloadAndInstall(from: url, sha256: sha) } label: {
                    Text("Update")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(Capsule().fill(t.accent))
                }
                .buttonStyle(.plain)
            }
        case .downloading:
            bar { progress("Downloading update…") }
        case .installing:
            bar { progress("Installing — Sonar will relaunch…") }
        default:
            EmptyView()
        }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(t.accent.opacity(0.12))
            .overlay(alignment: .bottom) { Rectangle().fill(t.sep).frame(height: 0.5) }
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.system(size: 12.5)).foregroundStyle(t.text2)
            Spacer()
        }
    }
}

/// HIDES the native window buttons and lets the bar drag the window. We draw
/// our OWN traffic-light dots in the title bar (see `WindowDots`) so the whole
/// bar is one SwiftUI surface with perfect alignment — no native chrome to
/// stack a second strip or sit off-line.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configure(from: view, attempt: 0)
        return view
    }

    private func configure(from view: NSView, attempt: Int) {
        DispatchQueue.main.async {
            guard let window = view.window else {
                if attempt < 5 { configure(from: view, attempt: attempt + 1) }
                return
            }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            // Hide the native dots — we draw our own in the bar.
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Our own macOS-style traffic lights, drawn in the title bar so they line up
/// with everything else. Red closes, yellow minimizes; the glyphs appear on
/// hover, exactly like the system buttons.
struct WindowDots: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            dot(Color(hex: 0xFF5F57), glyph: "xmark") { NSApp.keyWindow?.performClose(nil) }
            dot(Color(hex: 0xFEBC2E), glyph: "minus") { NSApp.keyWindow?.miniaturize(nil) }
            dot(Color(hex: 0x28C840), glyph: "arrow.up.left.and.arrow.down.right") {}
        }
        .onHover { hovering = $0 }
    }

    private func dot(_ color: Color, glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(color).frame(width: 12, height: 12)
                .overlay(Circle().stroke(.black.opacity(0.12), lineWidth: 0.5))
                .overlay(
                    Image(systemName: glyph)
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.black.opacity(hovering ? 0.55 : 0))
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

// MARK: - Window chrome

/// Custom 44px title bar: our own traffic-light dots and a back chevron on the
/// left, a centered ripple-mark + title, and an info button on the right — all
/// one SwiftUI surface, so it's a single perfectly-aligned bar (no native
/// chrome). Mirrors the prototype, which also drew its own dots.
struct TitleBar: View {
    @Environment(\.theme) private var t
    let title: String
    let showBack: Bool
    let onBack: () -> Void
    let onAbout: () -> Void

    var body: some View {
        ZStack {
            // Centered title.
            HStack(spacing: 7) {
                RippleMark(size: 15)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(t.text)
            }

            // Leading controls + trailing info, vertically centered in the bar.
            HStack(spacing: 12) {
                WindowDots()
                if showBack {
                    TitleBarButton(system: "chevron.left", action: onBack).help("Back")
                }
                Spacer()
                TitleBarButton(system: "info", action: onAbout).help("About Sonar")
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(t.winBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(t.sep.opacity(0.6)).frame(height: 0.5)
        }
    }
}

struct TitleBarButton: View {
    @Environment(\.theme) private var t
    let system: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hover ? t.text : t.text2)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hover ? t.surface3 : .clear))
        }
        .buttonStyle(.plain)
        .focusable(false) // no blue focus-ring outline around the icon
        .onHover { hover = $0 }
    }
}

// MARK: - Ripple mark (logo)

/// The signature mark: concentric rings around a luminous core — one source,
/// one sound, radiating in sync. Static; the searching state animates the
/// same motif via `RippleLoader`.
struct RippleMark: View {
    @Environment(\.theme) private var t
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            Circle()
                .stroke(t.accent.opacity(0.35), lineWidth: max(1.5, size * 0.035))
                .frame(width: size, height: size)
            Circle()
                .stroke(t.accent.opacity(0.6), lineWidth: max(1.5, size * 0.035))
                .frame(width: size * 0.68, height: size * 0.68)
            Circle()
                .fill(t.grad)
                .frame(width: size * 0.42, height: size * 0.42)
                .shadow(color: t.accent.opacity(0.45), radius: size * 0.18, y: size * 0.06)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Organic ripple loader (the searching hero)

/// Slow, breathing concentric ripples flowing out from a luminous core —
/// the "last loader" from the Organic Loaders set. Time-driven (TimelineView)
/// so the waves stay perfectly staggered and smooth at 60fps.
struct RippleLoader: View {
    @Environment(\.theme) private var t
    @Environment(\.animationsActive) private var animate
    var size: CGFloat = 168
    var duration: Double = 5

    private let waveCount = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !animate)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                // Soft glow behind the core (own slow pulse, 5.5s).
                let g = (sin(now / 5.5 * 2 * .pi) + 1) / 2
                Circle()
                    .fill(
                        RadialGradient(colors: [t.accent.opacity(0.26), .clear],
                                       center: .center, startRadius: 0, endRadius: size * 0.30)
                    )
                    .frame(width: size * 0.6, height: size * 0.6)
                    .scaleEffect(0.85 + g * 0.27)
                    .opacity(0.5 + g * 0.45)
                    .blur(radius: 14)

                // Expanding waves.
                ForEach(0..<waveCount, id: \.self) { i in
                    let delay = Double(i) * duration / Double(waveCount)
                    let phase = (((now - delay) / duration).truncatingRemainder(dividingBy: 1) + 1)
                        .truncatingRemainder(dividingBy: 1)
                    let scale = 0.24 + phase * (1.05 - 0.24)
                    let opacity: Double = phase < 0.12
                        ? (phase / 0.12) * 0.85
                        : max(0, 0.85 * (1 - (phase - 0.12) / 0.88))
                    Circle()
                        .stroke(i == 1 ? t.accentLite : t.accent, lineWidth: 2.5)
                        .frame(width: size, height: size)
                        .scaleEffect(scale)
                        .opacity(opacity)
                }

                // Breathing core with a glossy highlight (2.8s).
                let c = (sin(now / 2.8 * 2 * .pi) + 1) / 2
                ZStack {
                    Circle().fill(t.grad)
                    Circle()
                        .fill(RadialGradient(
                            colors: [.white.opacity(0.85), .clear],
                            center: UnitPoint(x: 0.38, y: 0.32),
                            startRadius: 0, endRadius: size * 0.18))
                        .padding(size * 0.30 * 0.22)
                }
                .frame(width: size * 0.30, height: size * 0.30)
                .scaleEffect(0.9 + c * 0.14)
                .shadow(color: t.accent.opacity(0.32 + c * 0.18), radius: 14 + c * 8, y: 6)
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Searching")
    }
}

// MARK: - Home / role picker

struct RolePickerView: View {
    @Environment(\.theme) private var t
    @Binding var role: Role
    @ObservedObject var updater: Updater
    @State private var taps = 0
    @State private var burstID = 0
    @State private var showBurst = false

    var body: some View {
        VStack(spacing: 0) {
            // Hero
            VStack(spacing: 0) {
                RippleLoader(size: 120, duration: 6)
                    .onTapGesture { heroTapped() }
                Text("Sonar")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(t.text)
                    .padding(.top, 18)
                Text("Play one Mac's sound on every Mac in the room — perfectly in sync, over your own Wi-Fi.")
                    .font(.system(size: 14))
                    .foregroundStyle(t.text2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 320)
                    .padding(.top, 8)
            }
            .padding(.top, 18)
            .padding(.bottom, 26)

            // Role cards
            HStack(spacing: 12) {
                RoleCard(icon: "antenna.radiowaves.left.and.right",
                         name: "Send",
                         desc: "This Mac plays the music. Everyone else hears it.",
                         filled: true) { role = .sender }
                RoleCard(icon: "speaker.wave.2.fill",
                         name: "Receive",
                         desc: "This Mac becomes a synced speaker in the room.",
                         filled: false) { role = .receiver }
            }

            Spacer(minLength: 22)

            HowToStrip()

            HomeUpdateRow(updater: updater)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .overlay { if showBurst { EmojiBurst().id(burstID).allowsHitTesting(false) } }
    }

    private func heroTapped() {
        taps += 1
        if taps % 5 == 0 {
            burstID += 1
            showBurst = true
            NSSound(named: "Funk")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { showBurst = false }
        }
    }
}

struct RoleCard: View {
    @Environment(\.theme) private var t
    let icon: String
    let name: String
    let desc: String
    let filled: Bool
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if filled {
                        RoundedRectangle(cornerRadius: 13, style: .continuous).fill(t.grad)
                        Image(systemName: icon).foregroundStyle(.white)
                    } else {
                        RoundedRectangle(cornerRadius: 13, style: .continuous).fill(t.surface3)
                            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(t.sepStrong, lineWidth: 1))
                        Image(systemName: icon).foregroundStyle(t.accentText)
                    }
                }
                .font(.system(size: 19, weight: .medium))
                .frame(width: 46, height: 46)
                .shadow(color: filled ? t.accent.opacity(0.34) : .clear, radius: 8, y: 6)
                .padding(.bottom, 14)

                Text(name)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(t.text)
                Text(desc)
                    .font(.system(size: 12.5))
                    .foregroundStyle(t.text2)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1.5)
                    .padding(.top, 5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 18)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(t.surface2)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(t.sep, lineWidth: 0.5))
                    .shadow(color: hover ? .black.opacity(0.06) : .clear, radius: 12, y: 6)
            )
            .offset(y: hover ? -3 : 0)
            .scaleEffect(pressed ? 0.98 : 1)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.2)) { hover = inside } }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
            .onEnded { _ in withAnimation(.spring(response: 0.3)) { pressed = false } })
    }
}

struct HowToStrip: View {
    @Environment(\.theme) private var t
    private let steps = ["Pick a role", "Same Wi-Fi", "Press play"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, label in
                HStack(spacing: 7) {
                    Text("\(i + 1)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(t.text2)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(t.surface3))
                    Text(label).font(.system(size: 12)).foregroundStyle(t.text2)
                }
                if i < steps.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(t.text3)
                }
            }
        }
    }
}

/// Small update affordance on Home: a one-tap check, with inline status. When
/// a newer build is found the prominent banner under the title bar takes over.
struct HomeUpdateRow: View {
    @Environment(\.theme) private var t
    @ObservedObject var updater: Updater

    var body: some View {
        switch updater.status {
        case .idle, .checking:
            label("Checking for updates…", color: t.text3)
        case .upToDate:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").imageScale(.small).foregroundStyle(t.good)
                Text("Sonar \(Updater.currentVersion) — up to date")
                    .font(.system(size: 11.5)).foregroundStyle(t.text3)
                Button("Check again") { updater.check() }
                    .font(.system(size: 11.5)).buttonStyle(.plain).foregroundStyle(t.accentText)
            }
        case .available, .downloading, .installing:
            // The banner under the title bar is already showing the action.
            label("Update ready — see the banner above", color: t.accentText)
        case .error:
            Button("Check for updates") { updater.check() }
                .font(.system(size: 11.5)).buttonStyle(.plain).foregroundStyle(t.accentText)
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(color)
    }
}

// MARK: - Sender

struct SenderView: View {
    @Environment(\.theme) private var t
    @Binding var role: Role
    @ObservedObject var engine: EngineProcess
    @AppStorage("bufferMs") private var bufferMs = 150.0
    @AppStorage("playLocally") private var playLocally = true
    @AppStorage("encryptOn") private var encryptOn = false
    @AppStorage("streamKey") private var streamKey = ""
    @AppStorage("senderName") private var senderDisplayName = ""

    private var supportsParty: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sender").font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                        .foregroundStyle(t.text)
                    StatusRow(state: !engine.isRunning ? .idle : (engine.muted ? .warn : .live),
                              label: !engine.isRunning ? "Not streaming"
                                  : (engine.muted ? "Muted — room is silent" : "Streaming"))
                }
                Spacer()
                if engine.isRunning, let code = engine.joinCode {
                    TransportChip(text: code.replacingOccurrences(of: ":", with: " · port "))
                }
            }

            if engine.isRunning {
                FleetCard(clients: engine.clients)
            }

            if engine.isRunning, let code = engine.joinCode {
                JoinCodeCard(code: code, label: "Share this to join manually")
            }

            // Output settings
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Output")
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "tag.fill").font(.system(size: 13)).foregroundStyle(t.text2)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.surface3))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Broadcast name").font(.system(size: 14, weight: .medium)).foregroundStyle(t.text)
                            Text("How this Mac appears to receivers").font(.system(size: 12)).foregroundStyle(t.text3)
                        }
                        Spacer()
                        TextField(Host.current().localizedName ?? "This Mac", text: $senderDisplayName)
                            .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            .font(.system(size: 13)).foregroundStyle(t.accentText)
                            .frame(maxWidth: 150).disabled(engine.isRunning)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    RowDivider()
                    if supportsParty {
                        SettingRow(icon: "laptopcomputer", title: "Play on this Mac too",
                                   sub: "Hear it here, locked to the room") {
                            Toggle("", isOn: $playLocally).labelsHidden()
                                .toggleStyle(.switch).tint(t.accent)
                                .disabled(engine.isRunning)
                        }
                        RowDivider()
                    }
                    SliderRow(title: "Latency buffer", value: $bufferMs,
                              range: 20...250, suffix: " ms", disabled: engine.isRunning)
                    RowDivider()
                    SettingRow(icon: encryptOn ? "lock.fill" : "lock.open",
                               title: "Encrypt this stream",
                               sub: "Require a password for receivers to join") {
                        Toggle("", isOn: $encryptOn).labelsHidden()
                            .toggleStyle(.switch).tint(t.accent)
                            .disabled(engine.isRunning)
                    }
                    if encryptOn {
                        RowDivider()
                        MasField(icon: "key.fill", placeholder: "Stream password",
                                 text: $streamKey, secure: true, mono: false)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .disabled(engine.isRunning)
                    }
                }
                .cardBackground(t)
            }

            MasButton(title: engine.isRunning ? "Stop Streaming" : "Start Streaming",
                      systemImage: engine.isRunning ? "stop.fill" : "play.fill",
                      style: engine.isRunning ? .stop : .primary) {
                if engine.isRunning { engine.stop() } else { startSending() }
            }

            if let issue = engine.permissionIssue {
                PermissionCard(issue: issue) { engine.restart() }
            } else if let error = engine.errorText {
                ErrorText(error)
            }

            HelperText(supportsParty
                ? "While streaming, this Mac's normal output is muted and replaced by the synced stream — every speaker plays together. First run asks for System Audio Recording permission."
                : "On this older macOS, this Mac's speakers play ahead of receivers — mute them and let the receivers be the speakers. First run asks for Screen Recording permission.")

            CollapsibleLogs(lines: engine.logLines)
        }
    }

    private func startSending() {
        var args = ["--buffer-ms", String(Int(bufferMs))]
        if supportsParty {
            args.append("--party")
            if !playLocally { args.append("--no-local-play") }
        } else {
            args.append("--capture")
        }
        if encryptOn && !streamKey.isEmpty { args += ["--key", streamKey] }
        let name = senderDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { args += ["--name", name] }
        engine.autoRestart = false
        engine.start(engine: "audiosync-send", arguments: args)
    }
}

/// The sender's fleet shown as a live sonar scope: this Mac at the centre, a
/// rotating sweep over concentric range rings, and one blip per connected Mac
/// that lights up as the sweep passes it. On-brand with the name, and it turns
/// "N Macs in sync" into something you watch.
struct FleetCard: View {
    @Environment(\.theme) private var t
    let clients: Int

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(clients)").font(.system(size: 30, weight: .bold)).tracking(-0.6)
                    .foregroundStyle(t.text)
                Text(clients == 0 ? "listening for Macs to join…"
                     : "Mac\(clients == 1 ? "" : "s") locked in sync")
                    .font(.system(size: 14)).foregroundStyle(t.text2)
                Spacer()
            }
            SonarRadar(clients: clients).frame(height: 196)
            if clients == 0 {
                Text("Open Sonar on another Mac and tap Receive.")
                    .font(.system(size: 12.5)).foregroundStyle(t.text3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(t)
    }
}

/// A genuine radar sweep: range rings, a rotating beam with a fading wedge
/// trail, and blips that flash when the beam crosses them. Pure Canvas at
/// 60fps; positions are stable per receiver so blips don't jump around.
struct SonarRadar: View {
    @Environment(\.theme) private var t
    @Environment(\.animationsActive) private var animate
    let clients: Int

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !animate)) { tl in
            let now = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let r = min(size.width, size.height) / 2 - 4
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let twoPi = 2 * Double.pi

                // Range rings (the ripple motif).
                for k in 1...3 {
                    let rr = r * CGFloat(k) / 3
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                               with: .color(t.accent.opacity(0.16)), lineWidth: 1)
                }

                // Sweep: a soft wedge trailing the beam, plus the bright beam line.
                let sweep = now.truncatingRemainder(dividingBy: twoPi / 0.55) * 0.55 // ~0.55 rev/s
                let trail = 0.7 // radians of trailing wedge
                var wedge = Path()
                wedge.move(to: c)
                wedge.addArc(center: c, radius: r,
                             startAngle: .radians(sweep - trail), endAngle: .radians(sweep),
                             clockwise: false)
                wedge.closeSubpath()
                ctx.fill(wedge, with: .color(t.accent.opacity(0.14)))
                let beamEnd = CGPoint(x: c.x + CGFloat(cos(sweep)) * r, y: c.y + CGFloat(sin(sweep)) * r)
                ctx.stroke(Path { $0.move(to: c); $0.addLine(to: beamEnd) },
                           with: .color(t.accent.opacity(0.85)), lineWidth: 1.5)

                // Blips: one per connected Mac, stable angle, flashing as the
                // beam passes (echo) and fading until the next pass.
                let n = max(0, min(clients, 12))
                for i in 0..<n {
                    let ba = (Double(i) + 0.5) / Double(n) * twoPi
                    let br = r * (0.55 + 0.18 * sin(Double(i) * 2.3)) // varied range, deterministic
                    let bp = CGPoint(x: c.x + CGFloat(cos(ba)) * br, y: c.y + CGFloat(sin(ba)) * br)
                    var since = (sweep - ba).truncatingRemainder(dividingBy: twoPi)
                    if since < 0 { since += twoPi }
                    let echo = max(0, 1 - since / 1.1) // bright right after the beam passes
                    let base: CGFloat = 3
                    let dot = base + CGFloat(echo) * 2.5
                    if echo > 0.02 {
                        let halo = dot + CGFloat(echo) * 10
                        ctx.fill(Path(ellipseIn: CGRect(x: bp.x - halo, y: bp.y - halo, width: halo * 2, height: halo * 2)),
                                 with: .color(t.accent.opacity(0.22 * echo)))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: bp.x - dot, y: bp.y - dot, width: dot * 2, height: dot * 2)),
                             with: .color(t.accent.opacity(0.55 + 0.45 * echo)))
                }

                // Centre = this Mac (the sender): a small breathing ripple.
                let pulse = (sin(now * 1.6) + 1) / 2
                for (ringR, op) in [(8.0 + pulse * 4, 0.5), (4.0, 0.9)] {
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2)),
                               with: .color(t.accent.opacity(op)), lineWidth: 1.5)
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)),
                         with: .color(t.accentLite))
            }
        }
        .accessibilityLabel(clients == 0 ? "Searching for receivers" : "\(clients) receivers in sync")
    }
}

// MARK: - Receiver

struct ReceiverView: View {
    @Environment(\.theme) private var t
    @Binding var role: Role
    @ObservedObject var engine: EngineProcess
    @AppStorage("streamKey") private var streamKey = ""
    @AppStorage("manualAddress") private var manualAddress = ""
    @State private var manualOpen = false

    // Sender discovery / picker, before the engine starts.
    @State private var pickState: PickState = .discovering
    @State private var senders: [String] = []
    @State private var chosenSender: String?
    private enum PickState { case discovering, choosing, started }

    private enum Phase { case searching, connecting, playing, error }
    private var phase: Phase {
        if !engine.isRunning { return .searching }
        if engine.diagnosis != nil && (engine.fillPercent ?? 0) == 0 { return .error }
        if engine.connectedTo != nil && (engine.fillPercent ?? 0) > 0 { return .playing }
        if engine.connectedTo != nil { return .connecting }
        return .searching
    }

    private var receiverArgs: [String] {
        var args: [String] = []
        let manual = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty {
            args += ["--connect", manual]
        } else if let s = chosenSender, !s.isEmpty {
            args += ["--sender", s] // connect to the picked sender by name
        }
        if !streamKey.isEmpty { args += ["--key", streamKey] }
        return args
    }

    var body: some View {
        Group {
            switch pickState {
            case .discovering: discoveringView
            case .choosing: choosingView
            case .started: startedView
            }
        }
        .onAppear(perform: beginDiscovery)
    }

    // MARK: discovery + picker (pre-engine)

    private func beginDiscovery() {
        if engine.isRunning { pickState = .started; return }
        guard pickState == .discovering else { return }
        // A saved manual address skips discovery entirely.
        if !manualAddress.trimmingCharacters(in: .whitespaces).isEmpty { startListening(); return }
        engine.discoverSenders { found in
            senders = found
            if found.count > 1 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { pickState = .choosing }
            } else {
                chosenSender = found.first   // 0 → plain browse; 1 → that one
                startListening()
            }
        }
    }

    private func startListening() {
        pickState = .started
        restart()
    }

    private func pick(_ name: String) {
        chosenSender = name
        startListening()
    }

    private var discoveringView: some View {
        VStack(alignment: .leading, spacing: 16) {
            receiverHeader(state: .warn, label: "Looking for senders")
            VStack(spacing: 26) {
                RippleLoader(size: 168, duration: 2.6)
                VStack(spacing: 5) {
                    Text("Finding senders…")
                        .font(.system(size: 17, weight: .semibold)).tracking(-0.2).foregroundStyle(t.text)
                    Text("Scanning your Wi-Fi network").font(.system(size: 12.5)).foregroundStyle(t.text2)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 18)
            Spacer(minLength: 0)
        }
    }

    private var choosingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            receiverHeader(state: .warn, label: "\(senders.count) Macs are streaming")
            Text("Choose a sender")
                .font(.system(size: 17, weight: .semibold)).tracking(-0.2).foregroundStyle(t.text)
            VStack(spacing: 8) {
                ForEach(senders, id: \.self) { name in
                    Button { pick(name) } label: { SenderPickRow(name: name) }
                        .buttonStyle(.plain)
                }
            }
            Button { chosenSender = nil; startListening() } label: {
                Text("Connect automatically")
                    .font(.system(size: 12.5)).foregroundStyle(t.accentText)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            CollapsibleLogs(lines: engine.logLines)
        }
    }

    private func receiverHeader(state: StatusRow.State, label: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Receiver").font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                    .foregroundStyle(t.text)
                StatusRow(state: state, label: label)
            }
            Spacer()
        }
    }

    private var startedView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Receiver").font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                        .foregroundStyle(t.text)
                    StatusRow(state: headerState, label: headerLabel)
                }
                Spacer()
                if phase == .playing, let transport = engine.transport {
                    TransportChip(text: "over \(transport)")
                }
            }

            switch phase {
            case .searching, .connecting:
                searchingHero
                ManualConnectCard(open: $manualOpen, address: $manualAddress,
                                  key: $streamKey, disabled: engine.isRunning,
                                  onConnect: restart)
            case .playing:
                playingHero
            case .error:
                let d = diagnosisPresentation
                DiagnosisBanner(tone: d.tone, icon: d.icon, title: d.title,
                    text: engine.diagnosis ?? "This network may block device discovery. Try Manual Connect with a join code, or put both Macs on a personal hotspot.")
                ManualConnectCard(open: .constant(true), address: $manualAddress,
                                  key: $streamKey, disabled: engine.isRunning,
                                  onConnect: restart)
            }

            MasButton(title: engine.isRunning ? "Stop" : "Start Listening",
                      systemImage: engine.isRunning ? "stop.fill" : "arrow.clockwise",
                      style: engine.isRunning ? .stop : .primary) {
                if engine.isRunning { engine.stop() } else { restart() }
            }

            if let error = engine.errorText { ErrorText(error) }

            HelperText("Finds the sender automatically over Wi-Fi and reconnects by itself if anything drops. Allow \"local network\" access if macOS asks.")

            CollapsibleLogs(lines: engine.logLines)
        }
    }

    /// Title/icon/tone for the error banner, keyed off the engine's diagnosis
    /// kind so each failure reads accurately.
    private var diagnosisPresentation: (title: String, icon: String, tone: DiagnosisBanner.Tone) {
        switch engine.diagnosisKind {
        case "isolated":    return ("This network is blocking the audio", "wifi.exclamationmark", .bad)
        case "key":         return ("Password doesn't match the sender", "lock.trianglebadge.exclamationmark", .bad)
        case "version":     return ("Update needed — different versions", "arrow.triangle.2.circlepath", .warn)
        case "unreachable": return ("Couldn't reach that address", "network.slash", .bad)
        default:            return ("Couldn't find a sender", "magnifyingglass", .warn)
        }
    }

    private var headerState: StatusRow.State {
        switch phase {
        case .searching, .connecting: return .warn
        case .playing: return .live
        case .error: return .bad
        }
    }
    private var headerLabel: String {
        if !engine.isRunning { return "Not listening" }
        switch phase {
        case .searching: return "Searching"
        case .connecting: return "Connecting"
        case .playing: return "Playing"
        case .error: return "No sender found"
        }
    }

    @ViewBuilder private var searchingHero: some View {
        let connecting = phase == .connecting
        VStack(spacing: 26) {
            RippleLoader(size: 168, duration: connecting ? 2.6 : 5)
            VStack(spacing: 5) {
                Text(connecting
                     ? "Connecting to \(engine.connectedTo ?? "the sender")…"
                     : "Looking for a sender…")
                    .font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                    .foregroundStyle(t.text)
                    .multilineTextAlignment(.center)
                Text(connecting ? "Syncing clocks and filling the buffer"
                     : "Listening on your Wi-Fi network")
                    .font(.system(size: 12.5)).foregroundStyle(t.text2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var playingHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                RippleMark(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.connectedTo ?? "Sender")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(t.text)
                    Text("the sender").font(.system(size: 12)).foregroundStyle(t.text3)
                }
                Spacer()
            }
            Waveform(bands: engine.spectrum)
            if let jitter = engine.syncJitterUs {
                (Text("Locked to the sender within ")
                 + Text("±\(jitter) µs").foregroundColor(t.text).bold()
                 + Text(" — sound itself travels just ")
                 + Text(soundDistance(jitter)).foregroundColor(t.text).bold()
                 + Text(" in that time."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(t.text2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .cardBackground(t)

        HStack(spacing: 8) {
            StatTile(label: "Sync", value: engine.syncJitterUs.map { "±\($0)" } ?? "—",
                     unit: "µs", tone: .good)
            StatTile(label: "Ping",
                     value: engine.rttUs.map { String(format: "%.0f", Double($0) / 1000) } ?? "—",
                     unit: "ms", tone: .good)
            StatTile(label: "Buffer", value: engine.marginMs.map { "\(max($0, 0))" } ?? "—",
                     unit: "ms", tone: (engine.marginMs ?? 100) < 20 ? .warn : .plain)
            StatTile(label: "Health", value: "\(engine.fillPercent ?? 0)", unit: "%",
                     tone: (engine.fillPercent ?? 100) < 95 ? .warn : .good)
        }
    }

    private func restart() {
        engine.autoRestart = true
        engine.start(engine: "audiosync-recv", arguments: receiverArgs)
    }
}

// MARK: - Status row

struct StatusRow: View {
    enum State { case idle, live, warn, bad }
    @Environment(\.theme) private var t
    let state: State
    let label: String

    private var color: Color {
        switch state {
        case .idle: return t.text3
        case .live: return t.good
        case .warn: return t.warn
        case .bad: return t.bad
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                if state == .live {
                    Circle().fill(t.good)
                        .frame(width: 9, height: 9)
                        .modifier(PulseRing(color: t.good))
                } else {
                    Circle().fill(color).frame(width: 9, height: 9)
                }
            }
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(t.text2)
        }
    }
}

struct PulseRing: ViewModifier {
    let color: Color
    @State private var on = false
    func body(content: Content) -> some View {
        content.background(
            Circle().stroke(color, lineWidth: 4)
                .scaleEffect(on ? 2.2 : 1)
                .opacity(on ? 0 : 0.5)
                .animation(.easeOut(duration: 2).repeatForever(autoreverses: false), value: on)
        )
        .onAppear { on = true }
    }
}

// MARK: - Transport chip

struct TransportChip: View {
    @Environment(\.theme) private var t
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(t.accentLite).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(t.text2)
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(Capsule().fill(t.surface2)
            .overlay(Capsule().stroke(t.sep, lineWidth: 0.5)))
    }
}

// MARK: - Join code

struct JoinCodeCard: View {
    @Environment(\.theme) private var t
    let code: String
    let label: String
    @State private var done = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased()).font(.system(size: 11, weight: .semibold))
                    .tracking(0.5).foregroundStyle(t.text3)
                Text(code).font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(t.text).textSelection(.enabled)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                done = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { done = false }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: done ? "checkmark" : "doc.on.doc")
                    Text(done ? "Copied" : "Copy")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(done ? t.good : t.accentText)
                .padding(.horizontal, 13).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(t.surface)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(t.sepStrong, lineWidth: 1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 13).padding(.leading, 16).padding(.trailing, 13)
        .cardBackground(t)
    }
}

// MARK: - Speaker chip

struct SpeakerChip: View {
    @Environment(\.theme) private var t
    let name: String
    let sub: String
    let playing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.grad))
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(t.text)
                Text(sub).font(.system(size: 11)).foregroundStyle(t.text3)
            }
            if playing { EqBars() }
        }
        .padding(.leading, 11).padding(.trailing, 14).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.surface2)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(t.sep, lineWidth: 0.5)))
    }
}

struct EqBars: View {
    @Environment(\.theme) private var t
    var body: some View {
        TimelineView(.animation) { tl in
            let now = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let h = 4 + (sin(now / 0.9 * 2 * .pi + Double(i) * 1.4) * 0.5 + 0.5) * 9
                    Capsule().fill(t.good).frame(width: 2.5, height: h)
                }
            }
            .frame(width: 12, height: 13, alignment: .bottom)
        }
    }
}

// MARK: - Waveform (playing)

/// Smooths the engine's ~24 Hz spectrum frames up to 60 fps with a fast attack
/// / slow decay so the bars rise sharply and fall gracefully — the natural feel
/// of a real spectrum analyzer. Held by reference so the per-frame update never
/// trips SwiftUI's "modifying state during update".
final class SpectrumBars {
    var values: [Float] = []

    func advance(target: [Float], fallbackCount: Int) {
        let n = target.isEmpty ? fallbackCount : target.count
        if values.count != n { values = [Float](repeating: 0, count: n) }
        for i in 0..<n {
            let goal = target.isEmpty ? 0 : target[i]
            let k: Float = goal > values[i] ? 0.55 : 0.16
            values[i] += (goal - values[i]) * k
        }
    }
}

/// Real frequency-spectrum visualizer: log-spaced bands of the audio actually
/// playing (FFT computed in the engine, see `SpectrumAnalyzer`), rendered as
/// rounded bars mirrored about the centre line. Bass on the left, treble on the
/// right. Falls back to a flat idle line when nothing is playing.
struct Waveform: View {
    @Environment(\.theme) private var t
    @Environment(\.animationsActive) private var animate
    let bands: [Float]
    @State private var bars = SpectrumBars()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !animate)) { _ in
            Canvas { ctx, size in
                bars.advance(target: bands, fallbackCount: 32)
                let vals = bars.values
                let n = vals.count
                guard n > 0 else { return }

                let gap: CGFloat = 3
                let bw = max(2.5, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
                let totalW = bw * CGFloat(n) + gap * CGFloat(n - 1)
                var x = (size.width - totalW) / 2
                let midY = size.height / 2

                // Always the sonar teal — consistent, no color-shifting.
                let colors = [t.accentLite, t.accent, t.accentStrong]
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: colors),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height))

                for i in 0..<n {
                    let v = CGFloat(min(1, max(0, vals[i])))
                    let h = max(3, v * (size.height - 2))
                    let rect = CGRect(x: x, y: midY - h / 2, width: bw, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: bw / 2), with: shading)
                    x += bw + gap
                }
            }
            .frame(height: 76)
        }
        .frame(height: 76)
    }
}

// MARK: - Stat tile

struct StatTile: View {
    enum Tone { case plain, good, warn }
    @Environment(\.theme) private var t
    let label: String
    let value: String
    let unit: String
    var tone: Tone = .plain

    private var valueColor: Color {
        switch tone { case .plain: return t.text; case .good: return t.good; case .warn: return t.warn }
    }
    private var borderColor: Color {
        switch tone {
        case .plain: return t.sep
        case .good: return t.good.opacity(0.38)
        case .warn: return t.warn.opacity(0.42)
        }
    }
    private var washColor: Color {
        switch tone { case .plain: return .clear; case .good: return t.goodBg; case .warn: return t.warnBg }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased()).font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4).foregroundStyle(t.text3)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 19, weight: .heavy)).tracking(-0.4)
                    .foregroundStyle(valueColor).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.top, 12).padding(.bottom, 13)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(t.surface2)
                .overlay(LinearGradient(colors: [washColor, .clear], startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.5))
        )
    }
}

// MARK: - Diagnosis banner

struct DiagnosisBanner: View {
    enum Tone { case warn, bad }
    @Environment(\.theme) private var t
    let tone: Tone
    let icon: String
    let title: String
    let text: String

    private var accent: Color { tone == .bad ? t.bad : t.warn }
    private var bg: Color { tone == .bad ? t.badBg : t.warnBg }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(Circle().fill(accent))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(t.text)
                Text(text).font(.system(size: 12.5)).foregroundStyle(t.text2)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(bg)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accent.opacity(0.4), lineWidth: 0.5)))
    }
}

// MARK: - Permission remediation

/// Turns a cryptic permission failure into a clear, actionable card: what's
/// missing, why, a button straight to the right System Settings pane, and a
/// "Try Again" once granted.
struct PermissionCard: View {
    @Environment(\.theme) private var t
    let issue: EngineProcess.PermissionIssue
    let onRetry: () -> Void

    private var title: String {
        issue == .systemAudio ? "Allow System Audio Recording" : "Allow Screen Recording"
    }
    private var detail: String {
        issue == .systemAudio
            ? "Sonar needs System Audio Recording to capture this Mac's sound and stream it in sync. Turn it on for Sonar in System Settings, then tap Try Again."
            : "Sonar captures this Mac's audio via Screen Recording (no video is ever recorded). Turn it on for Sonar, then tap Try Again."
    }
    private var settingsURL: URL {
        URL(string: issue == .screenRecording
            ? "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").font(.system(size: 15)).foregroundStyle(t.warn)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(t.text)
            }
            Text(detail).font(.system(size: 12.5)).foregroundStyle(t.text2)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                MasButton(title: "Open System Settings", systemImage: "gearshape.fill",
                          style: .primary, large: false) {
                    NSWorkspace.shared.open(settingsURL)
                }
                MasButton(title: "Try Again", systemImage: "arrow.clockwise",
                          style: .secondary, large: false, action: onRetry)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.warnBg)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(t.warn.opacity(0.4), lineWidth: 0.5)))
    }
}

// MARK: - Manual connect

struct ManualConnectCard: View {
    @Environment(\.theme) private var t
    @Binding var open: Bool
    @Binding var address: String
    @Binding var key: String
    let disabled: Bool
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(t.text3).rotationEffect(.degrees(open ? 90 : 0))
                    Text("Manual connect").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(t.text2)
                    Spacer()
                    Text("paste a join code").font(.system(size: 11)).foregroundStyle(t.text3)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(spacing: 9) {
                    MasField(icon: "link", placeholder: "192.168.x.x:port",
                             text: $address, secure: false, mono: true)
                    MasField(icon: "key.fill", placeholder: "Password (if required)",
                             text: $key, secure: true, mono: false)
                    MasButton(title: "Connect", systemImage: nil, style: .secondary, large: false,
                              action: onConnect)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
                .disabled(disabled)
            }
        }
        .cardBackground(t)
    }
}

/// A tappable row in the "choose a sender" list: the ripple mark, the sender's
/// friendly name, and a chevron.
struct SenderPickRow: View {
    @Environment(\.theme) private var t
    let name: String
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            RippleMark(size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 14, weight: .medium)).foregroundStyle(t.text)
                Text("Tap to listen").font(.system(size: 11.5)).foregroundStyle(t.text3)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(t.text3)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(hover ? t.surface3 : t.surface2)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(t.sep, lineWidth: 0.5)))
        .onHover { hover = $0 }
    }
}

// MARK: - Settings rows

struct SectionLabel: View {
    @Environment(\.theme) private var t
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 10) {
            Text(text.uppercased()).font(.system(size: 11, weight: .semibold))
                .tracking(0.5).foregroundStyle(t.text3)
            Rectangle().fill(t.sep).frame(height: 0.5)
        }
        .padding(.bottom, 8)
    }
}

struct SettingRow<Trailing: View>: View {
    @Environment(\.theme) private var t
    let icon: String
    let title: String
    let sub: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(t.text2)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.surface3))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(t.text)
                Text(sub).font(.system(size: 12)).foregroundStyle(t.text3)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }
}

struct SliderRow: View {
    @Environment(\.theme) private var t
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    let disabled: Bool

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(t.text)
                Spacer()
                Text("\(Int(value))\(suffix)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(t.accentText)
            }
            Slider(value: $value, in: range, step: 10).tint(t.accent).disabled(disabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }
}

struct RowDivider: View {
    @Environment(\.theme) private var t
    var body: some View {
        Rectangle().fill(t.sep).frame(height: 0.5).padding(.leading, 16)
    }
}

struct MasField: View {
    @Environment(\.theme) private var t
    let icon: String
    let placeholder: String
    @Binding var text: String
    let secure: Bool
    let mono: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(t.text3)
                .frame(width: 16)
            Group {
                if secure { SecureField(placeholder, text: $text) }
                else { TextField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13.5, design: mono ? .monospaced : .default))
            .foregroundStyle(t.text)
        }
        .padding(.horizontal, 11).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.field)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(t.fieldEdge, lineWidth: 1)))
    }
}

// MARK: - Buttons

struct MasButton: View {
    enum Style { case primary, stop, secondary }
    @Environment(\.theme) private var t
    let title: String
    var systemImage: String? = nil
    var style: Style = .primary
    var large: Bool = true
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let s = systemImage { Image(systemName: s) }
                Text(title)
            }
            .font(.system(size: large ? 16 : 14, weight: .semibold))
            .frame(maxWidth: .infinity).frame(height: large ? 50 : 40)
            .foregroundStyle(fg)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: large ? 10 : 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: large ? 10 : 8, style: .continuous)
                .stroke(border, lineWidth: 1))
            .shadow(color: style == .primary ? t.accent.opacity(0.36) : .clear, radius: 12, y: 4)
            .scaleEffect(pressed ? 0.975 : 1)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
            .onEnded { _ in withAnimation(.spring(response: 0.3)) { pressed = false } })
    }

    @ViewBuilder private var bg: some View {
        switch style {
        case .primary: t.grad
        case .stop: t.bad.opacity(0.15)
        case .secondary: t.surface2
        }
    }
    private var fg: Color {
        switch style { case .primary: return .white; case .stop: return t.bad; case .secondary: return t.text }
    }
    private var border: Color {
        switch style {
        case .primary: return .clear
        case .stop: return t.bad.opacity(0.28)
        case .secondary: return t.sep
        }
    }
}

// MARK: - Logs

struct CollapsibleLogs: View {
    @Environment(\.theme) private var t
    let lines: [String]
    @AppStorage("logsExpanded") private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(t.text3).rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Activity log").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(t.text2)
                    Spacer()
                    Text("\(lines.count) events").font(.system(size: 11)).foregroundStyle(t.text3)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(logColor(line))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                    .onChange(of: lines.count) { _ in proxy.scrollTo("bottom") }
                    .onAppear { proxy.scrollTo("bottom") }
                }
            }
        }
        .cardBackground(t)
    }

    private func logColor(_ line: String) -> Color {
        if line.contains("failed") || line.contains("WARNING") || line.contains("diag=") { return t.warn }
        if line.contains("started") || line.contains("connected") || line.contains("synced") { return t.good }
        return t.text2
    }
}

// MARK: - Small helpers

struct ErrorText: View {
    @Environment(\.theme) private var t
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12)).foregroundStyle(t.bad).lineLimit(3)
    }
}

struct HelperText: View {
    @Environment(\.theme) private var t
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(t.text2)
            .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }
}

/// Card surface used across the app (surface-2 + hairline inset border).
extension View {
    func cardBackground(_ t: Theme) -> some View {
        self.background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.surface2))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(t.sep, lineWidth: 0.5))
    }
}

/// Simple wrapping layout for the speaker chips.
struct FlexChips<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        // A vertical stack of chips reads cleanly in this narrow window.
        VStack(alignment: .leading, spacing: 8) { content }
    }
}

/// Sound covers ~0.343 mm per microsecond — turn sync µs into distance.
func soundDistance(_ microseconds: Int) -> String {
    let mm = Double(microseconds) * 0.343
    if mm < 10 { return String(format: "%.1f mm of air", mm) }
    if mm < 1000 { return String(format: "%.0f cm of air", mm / 10) }
    return String(format: "%.1f m of air", mm / 1000)
}

// MARK: - About

struct AboutSheet: View {
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var updater: Updater
    @State private var versionTaps = 0

    var body: some View {
        VStack(spacing: 6) {
            RippleLoader(size: 96, duration: 6)
            Text("Sonar").font(.system(size: 20, weight: .semibold)).foregroundStyle(t.text)
                .padding(.top, 6)
            Text("Version \(Updater.currentVersion) · Synced Ripples")
                .font(.system(size: 12.5)).foregroundStyle(t.text2)
                .onTapGesture {
                    versionTaps += 1
                    if versionTaps == 3 { NSSound(named: "Glass")?.play() }
                }
            Text("Multi-room audio for any Mac. No hardware, no accounts — just your Wi-Fi. Receivers lock to the sender's clock within a few microseconds.")
                .font(.system(size: 13)).foregroundStyle(t.text2)
                .multilineTextAlignment(.center).lineSpacing(2)
                .padding(.top, 6).padding(.horizontal, 8)

            if versionTaps >= 3 {
                Text("🤫 First ever two-Mac sync test: 13 µs apart.\nSonos, you may call us.")
                    .font(.system(size: 12).italic())
                    .foregroundStyle(t.accentText)
                    .multilineTextAlignment(.center)
                    .transition(.scale.combined(with: .opacity))
            }

            UpdateSection(updater: updater)
                .padding(.top, 10)

            if let url = URL(string: "https://github.com/RatikArora/macaudiosync") {
                Link(destination: url) {
                    Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12))
                }
                .padding(.top, 2)
            }

            MasButton(title: "Close", style: .secondary, large: false) { dismiss() }
                .padding(.top, 8)
        }
        .animation(.spring(response: 0.4), value: versionTaps >= 3)
        .padding(24)
        .frame(width: 320)
        .background(t.winBg)
    }
}

/// In-app update control inside the About sheet: auto-checks on open, then
/// offers a one-click download + install when a newer build is published.
struct UpdateSection: View {
    @Environment(\.theme) private var t
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(spacing: 8) {
            switch updater.status {
            case .idle, .checking:
                busy("Checking for updates…")
            case .upToDate:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(t.good)
                    Text("You're on the latest version").foregroundStyle(t.text2)
                }
                .font(.system(size: 12.5))
            case .available(let version, let notes, let url, let sha):
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(t.accentText)
                        Text("Version \(version) is available").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(t.text)
                    }
                    if !notes.isEmpty {
                        Text(notes).font(.system(size: 12)).foregroundStyle(t.text2)
                            .multilineTextAlignment(.center).lineSpacing(2)
                    }
                    MasButton(title: "Download & Install", systemImage: "square.and.arrow.down",
                              style: .primary, large: false) {
                        updater.downloadAndInstall(from: url, sha256: sha)
                    }
                }
            case .downloading:
                busy("Downloading update…")
            case .installing:
                busy("Installing — Sonar will relaunch…")
            case .error(let message):
                VStack(spacing: 6) {
                    Text(message).font(.system(size: 12)).foregroundStyle(t.warn)
                        .multilineTextAlignment(.center)
                    Button("Try again") { updater.check() }
                        .font(.system(size: 12)).buttonStyle(.link)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { if updater.status == .idle { updater.check() } }
    }

    private func busy(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.system(size: 12.5)).foregroundStyle(t.text2)
        }
    }
}

// MARK: - Easter egg: emoji burst

struct EmojiBurst: View {
    private let emojis = ["🎵", "🎶", "🎧", "🔊", "🩵", "✨", "🪩", "🎉"]
    var body: some View {
        GeometryReader { geo in
            ForEach(0..<16, id: \.self) { i in
                BurstParticle(emoji: emojis[i % emojis.count],
                              startX: CGFloat.random(in: 20...(geo.size.width - 20)),
                              height: geo.size.height, delay: Double(i) * 0.06)
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
        Text(emoji).font(.system(size: CGFloat.random(in: 20...34)))
            .position(x: startX, y: up ? -30 : height + 30)
            .opacity(up ? 0.9 : 1)
            .rotationEffect(.degrees(up ? Double.random(in: -40...40) : 0))
            .onAppear {
                withAnimation(.easeOut(duration: Double.random(in: 1.4...2.2)).delay(delay)) { up = true }
            }
    }
}

// Entry point (main.swift can't use @main with top-level code).
MacAudioSyncRootApp.main()
