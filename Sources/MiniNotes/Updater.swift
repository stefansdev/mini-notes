import AppKit

extension Notification.Name {
    static let updateAvailable = Notification.Name("MiniNotes.updateAvailable")
}

/// Self-updater backed by GitHub Releases: checks `releases/latest`, downloads `MiniNotes.zip`,
/// verifies the bundle (identifier, version, code signature), swaps it in place and relaunches.
@MainActor
final class Updater {
    static let shared = Updater()
    static let repo = "stefansdev/mini-notes"
    private static let assetName = "MiniNotes.zip"

    struct Release {
        let version: String
        let notes: String
        let zipURL: URL
        let pageURL: URL
    }

    private(set) var available: Release?
    private(set) var isInstalling = false
    private var timer: Timer?
    /// Called with status text for the window footer ("Downloading update…").
    var onStatus: ((String) -> Void)?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    /// Only a real .app bundle can replace itself (not `swift run` / debug builds).
    var canSelfUpdate: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func start() {
        guard canSelfUpdate else { return }
        timer?.invalidate()
        guard Prefs.autoCheckUpdates else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.check(userInitiated: false) }
        }
    }

    // MARK: - Checking

    func check(userInitiated: Bool) {
        Task {
            do {
                let release = try await fetchLatest()
                handle(release, userInitiated: userInitiated)
            } catch {
                if userInitiated { alert("Couldn’t check for updates", error.localizedDescription) }
            }
        }
    }

    func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { $0["name"] as? String == Self.assetName }),
              let zipString = zip["browser_download_url"] as? String, let zipURL = URL(string: zipString) else {
            throw UpdateError.badResponse
        }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(Self.repo)/releases")!
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                       notes: json["body"] as? String ?? "", zipURL: zipURL, pageURL: page)
    }

    private func handle(_ release: Release, userInitiated: Bool) {
        guard Self.isNewer(release.version, than: currentVersion) else {
            available = nil
            if userInitiated { alert("You’re up to date", "Mini Notes \(currentVersion) is the latest version.") }
            return
        }
        if !userInitiated, Prefs.skippedVersion == release.version { return }
        available = release
        NotificationCenter.default.post(name: .updateAvailable, object: nil)
        if userInitiated { promptInstall() }
    }

    /// Semantic-version compare ("1.10.0" > "1.9.2").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    func promptInstall() {
        guard let release = available, !isInstalling else { return }
        let alert = NSAlert()
        alert.messageText = "Mini Notes \(release.version) is available"
        var notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 700 { notes = String(notes.prefix(700)) + "…" }
        alert.informativeText = "You have \(currentVersion).\n\n" + notes
        alert.addButton(withTitle: canSelfUpdate ? "Install and Relaunch" : "Open Download Page")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if canSelfUpdate { install(release) } else { NSWorkspace.shared.open(release.pageURL) }
        case .alertThirdButtonReturn:
            Prefs.skippedVersion = release.version
            available = nil
        default:
            break
        }
    }

    func install(_ release: Release, relaunch: Bool = true) {
        guard !isInstalling else { return }
        isInstalling = true
        onStatus?("Downloading Mini Notes \(release.version)…")
        Task {
            do {
                try await performInstall(release)
                if relaunch { relaunchAndQuit() } else { isInstalling = false; onStatus?("Updated to \(release.version)") }
            } catch {
                isInstalling = false
                onStatus?("")
                alert("Update failed", "\(error.localizedDescription)\n\nYou can download it from \(release.pageURL.absoluteString)")
            }
        }
    }

    enum UpdateError: LocalizedError {
        case badResponse, unzipFailed, verificationFailed(String)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "GitHub returned an unexpected response."
            case .unzipFailed: return "The download couldn’t be unpacked."
            case .verificationFailed(let why): return "The downloaded app didn’t pass verification (\(why))."
            }
        }
    }

    /// Download, verify and swap the app bundle on disk (no UI).
    func performInstall(_ release: Release) async throws {
        let newApp = try await download(release)
        onStatus?("Installing…")
        try replaceRunningApp(with: newApp)
    }

    private func download(_ release: Release) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: release.zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badResponse }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MiniNotesUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent(Self.assetName)
        try FileManager.default.moveItem(at: file, to: zip)
        guard try await run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else { throw UpdateError.unzipFailed }
        let app = work.appendingPathComponent("Mini Notes.app")
        try verify(app, expectedVersion: release.version)
        return app
    }

    private func verify(_ app: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: app) else { throw UpdateError.verificationFailed("not an app bundle") }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.verificationFailed("unexpected bundle identifier")
        }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard version == expectedVersion else { throw UpdateError.verificationFailed("version \(version), expected \(expectedVersion)") }
        let status = try runSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard status == 0 else { throw UpdateError.verificationFailed("invalid code signature") }
    }

    private func replaceRunningApp(with newApp: URL) throws {
        let target = Bundle.main.bundleURL
        _ = try FileManager.default.replaceItemAt(target, withItemAt: newApp, backupItemName: nil, options: [])
    }

    private func relaunchAndQuit() {
        let path = Bundle.main.bundleURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open '\(path)'"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func runSync(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
