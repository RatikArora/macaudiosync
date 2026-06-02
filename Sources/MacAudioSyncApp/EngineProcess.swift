import Foundation
import AppKit

/// Runs one of the bundled CLI engines (audiosync-send / audiosync-recv) as
/// a child process and publishes parsed status for the UI. The app contains
/// no audio or networking code of its own — the battle-tested CLIs do all
/// the work; this just drives them.
final class EngineProcess: ObservableObject {
    @Published var isRunning = false
    @Published var statusText = ""
    @Published var clients = 0
    @Published var fillPercent: Int?
    @Published var peak: Double = 0
    @Published var connectedTo: String?
    @Published var logLines: [String] = []
    @Published var errorText: String?
    /// Clock-sync stability: spread of recent offset estimates, in µs.
    /// This is the headline number — how tightly this Mac tracks the
    /// sender's clock.
    @Published var syncJitterUs: Int?
    /// Network round-trip of the best clock probe, µs.
    @Published var rttUs: Int?
    /// Arrival headroom (ms): how early audio lands vs its deadline.
    @Published var marginMs: Int?

    private var recentOffsetsMs: [Double] = []

    /// When true (receiver), an engine that dies for any reason — Wi-Fi
    /// drop, sender restart, crash — is relaunched automatically after a
    /// short pause, forever, until the user presses Stop. The flow never
    /// breaks; worst case is a few seconds of silence and a reconnect.
    var autoRestart = false

    private var process: Process?
    private var lineBuffer = ""
    private var userStopped = false
    private var lastEngine = ""
    private var lastArguments: [String] = []

    init() {
        // Never leave orphaned engines running after the app quits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
    }

    /// Locate a bundled engine binary: next to the app executable inside the
    /// bundle; falls back to the SwiftPM build dir for development runs.
    static func engineURL(_ name: String) -> URL? {
        if let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(name),
            FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/release/\(name)")
        if FileManager.default.isExecutableFile(atPath: dev.path) {
            return dev
        }
        return nil
    }

    func start(engine: String, arguments: [String]) {
        stop()
        userStopped = false
        lastEngine = engine
        lastArguments = arguments
        logLines = []
        launch()
    }

    private func launch() {
        let engine = lastEngine
        guard let url = Self.engineURL(engine) else {
            errorText = "\(engine) binary not found in the app bundle"
            return
        }
        errorText = nil
        clients = 0
        fillPercent = nil
        peak = 0
        connectedTo = nil
        syncJitterUs = nil
        rttUs = nil
        marginMs = nil
        recentOffsetsMs = []
        statusText = "Starting…"

        let process = Process()
        process.executableURL = url
        process.arguments = lastArguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe // engine logs go to stderr

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.ingest(text) }
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                if self.userStopped {
                    self.statusText = "Stopped"
                    return
                }
                if proc.terminationStatus != 0 && proc.terminationReason == .exit {
                    self.errorText = self.errorText ?? "Engine exited (status \(proc.terminationStatus)) — see log"
                }
                if self.autoRestart {
                    // Self-heal: relaunch after a short pause.
                    self.statusText = "Reconnecting…"
                    self.logLines.append("— engine stopped, reconnecting in 2 s —")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, !self.userStopped, !self.isRunning else { return }
                        self.launch()
                    }
                } else {
                    self.statusText = "Stopped"
                }
            }
        }

        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            errorText = "Could not start engine: \(error.localizedDescription)"
        }
    }

    func stop() {
        userStopped = true
        process?.terminate()
        process = nil
        isRunning = false
        statusText = "Stopped"
    }

    // MARK: - Log parsing

    private func ingest(_ text: String) {
        lineBuffer += text
        while let newline = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newline])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
            if !line.isEmpty { parse(line) }
        }
    }

    private func parse(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }

        // Sender signals
        if line.contains("process-tap capture started") || line.contains("system audio capture started") {
            statusText = "Streaming"
        }
        if let count = capture(#"clients=(\d+)"#, in: line) {
            clients = Int(count) ?? clients
            if isRunning && statusText != "Streaming" { statusText = "Streaming" }
        }

        // Receiver signals
        if line.contains("browsing for senders") {
            statusText = "Searching for a sender…"
        }
        if line.contains("connected to ") {
            let raw = line.components(separatedBy: "connected to ").last ?? ""
            connectedTo = raw
                .replacingOccurrences(of: "\\032", with: " ")
                .replacingOccurrences(of: "._audiosync._udp.local.", with: "")
            statusText = "Connected"
        }
        if let fill = capture(#"\((\d+)% fill\)"#, in: line) {
            fillPercent = Int(fill)
        }
        if let p = capture(#"peak=([0-9.]+)"#, in: line) {
            peak = Double(p) ?? peak
        }
        if let rtt = capture(#"rtt=(\d+)µs"#, in: line) {
            rttUs = Int(rtt)
        }
        if let margin = capture(#"margin=(-?\d+)ms"#, in: line) {
            marginMs = Int(margin)
        }
        if let offset = capture(#"offset=(-?[0-9.]+)ms"#, in: line), let value = Double(offset) {
            // The absolute offset is just the two Macs' boot-time difference;
            // its VARIATION over the last few seconds is the sync stability.
            recentOffsetsMs.append(value)
            if recentOffsetsMs.count > 12 { recentOffsetsMs.removeFirst() }
            if recentOffsetsMs.count >= 4,
               let lo = recentOffsetsMs.min(), let hi = recentOffsetsMs.max() {
                syncJitterUs = max(1, Int(((hi - lo) / 2 * 1000).rounded()))
            }
        }

        // Failures worth surfacing prominently
        if line.contains("grant") || line.contains("failed") || line.contains("WARNING") {
            errorText = line.components(separatedBy: "] ").last ?? line
        }
    }

    private func capture(_ pattern: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }
}
