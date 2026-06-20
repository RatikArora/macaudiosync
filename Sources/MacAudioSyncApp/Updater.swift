import Foundation
import AppKit

/// Self-update from the project's GitHub repo. The app checks a small JSON
/// manifest (`release/appcast.json`), compares versions, and — if a newer one
/// is published — downloads the universal `Sonar.app.zip`, unpacks it, and
/// swaps the running bundle in place via a tiny helper script, then relaunches.
///
/// Everything is user-initiated (a button), fetched over HTTPS, and the
/// download URL is required to live on github.com — so this can only ever
/// pull this app's own releases, never an arbitrary payload.
@MainActor
final class Updater: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String, url: URL)
        case downloading
        case installing
        case error(String)
    }

    @Published var status: Status = .idle

    static let currentVersion =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"

    private let appcastURL = URL(string:
        "https://raw.githubusercontent.com/RatikArora/macaudiosync/main/release/appcast.json")!

    private struct Appcast: Decodable {
        let version: String
        let notes: String?
        let url: String
    }

    // MARK: - Check

    func check() {
        status = .checking
        Task {
            do {
                var request = URLRequest(url: appcastURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw UpdaterError("Couldn't reach the update server.")
                }
                let cast = try JSONDecoder().decode(Appcast.self, from: data)
                guard let url = URL(string: cast.url), let host = url.host,
                      host == "github.com" || host.hasSuffix(".github.com")
                        || host.hasSuffix("githubusercontent.com") else {
                    throw UpdaterError("Update has an unexpected download location.")
                }
                if Self.isNewer(cast.version, than: Self.currentVersion) {
                    status = .available(version: cast.version,
                                        notes: cast.notes ?? "", url: url)
                } else {
                    status = .upToDate
                }
            } catch {
                status = .error((error as? UpdaterError)?.message ?? error.localizedDescription)
            }
        }
    }

    // MARK: - Download + install

    func downloadAndInstall(from url: URL) {
        status = .downloading
        Task {
            do {
                let (downloaded, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw UpdaterError("Download failed.")
                }
                status = .installing
                try await Task.detached(priority: .userInitiated) {
                    try Self.unpackAndSwap(downloadedZip: downloaded)
                }.value
                // unpackAndSwap launches the swap helper; quit so it can replace us.
                NSApp.terminate(nil)
            } catch {
                status = .error((error as? UpdaterError)?.message ?? error.localizedDescription)
            }
        }
    }

    /// Unzip the downloaded bundle to a temp dir and launch a detached helper
    /// script that waits for us to quit, replaces the running .app, and
    /// relaunches it. Runs off the main thread.
    nonisolated private static func unpackAndSwap(downloadedZip: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("SonarUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let zip = work.appendingPathComponent("Sonar.app.zip")
        try fm.moveItem(at: downloadedZip, to: zip)

        let extract = work.appendingPathComponent("extract")
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)
        try runProcess("/usr/bin/ditto", ["-x", "-k", zip.path, extract.path])

        guard let appName = try fm.contentsOfDirectory(atPath: extract.path)
            .first(where: { $0.hasSuffix(".app") }) else {
            throw UpdaterError("Downloaded update didn't contain an app.")
        }
        let newApp = extract.appendingPathComponent(appName)
        let dest = Bundle.main.bundlePath

        // Sanity: make sure we can write where the app lives.
        guard fm.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent) else {
            throw UpdaterError("Can't update \(dest) — move Sonar to Applications and try again.")
        }

        let script = work.appendingPathComponent("install.sh")
        let body = """
        #!/bin/bash
        DEST="$1"; NEWAPP="$2"; PID="$3"; WORK="$4"
        # Wait (up to ~10s) for the running app to fully quit.
        for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        sleep 0.3
        rm -rf "$DEST"
        /usr/bin/ditto "$NEWAPP" "$DEST"
        /usr/bin/xattr -cr "$DEST" 2>/dev/null
        open "$DEST"
        rm -rf "$WORK"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [script.path, dest, newApp.path, String(pid), work.path]
        try helper.run() // detached; do NOT wait — it outlives this process
    }

    nonisolated private static func runProcess(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw UpdaterError("\(path) failed (\(p.terminationStatus)).")
        }
    }

    // MARK: - Version compare

    /// True when `remote` is a strictly higher dotted version than `local`
    /// (e.g. "2.1" > "2.0", "2.0.1" > "2.0").
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let l = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
}

private struct UpdaterError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
