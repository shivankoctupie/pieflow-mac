import AppKit
import Combine
import CryptoKit

/// Checks GitHub releases for a newer PieFlow and installs it in place.
/// Flow: releases/latest -> compare tag with the running version -> download the DMG -> verify SHA-256
/// against the published .sha256 asset -> mount -> replace the app bundle -> relaunch.
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    struct Release: Equatable {
        let version: String
        let tag: String
        let notes: String
        let dmgURL: URL
        let shaURL: URL?
        let pageURL: URL
    }

    static let repo = "shivankoctupie/pieflow-mac"
    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    let store: Store
    private var timer: Timer?
    private var downloadTask: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    /// The version this build reports. `PIEFLOW_FAKE_VERSION` lets the update path be tested end to end.
    static var currentVersion: String {
        ProcessInfo.processInfo.environment["PIEFLOW_FAKE_VERSION"] ?? AppInfo.version
    }

    init(store: Store) {
        self.store = store
    }

    /// Check shortly after launch, then every 6 hours while running (a check is one small GET).
    func startSchedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check(userInitiated: false) }
    }

    var availableRelease: Release? {
        if case .available(let r) = state { return r }
        return nil
    }

    func check(userInitiated: Bool) {
        if case .downloading = state { return }
        if case .installing = state { return }
        if !userInitiated, let last = lastChecked, Date().timeIntervalSince(last) < 3600 { return }
        state = .checking
        Task { @MainActor in
            do {
                let release = try await Self.fetchLatest()
                lastChecked = Date()
                let newer = Self.isNewer(release.version, than: Self.currentVersion)
                let skipped = !userInitiated && store.settings.skippedVersion == release.version
                Log.write("update check: latest \(release.version), running \(Self.currentVersion), newer=\(newer)\(skipped ? ", skipped" : "")")
                state = (newer && !skipped) ? .available(release) : .upToDate
            } catch {
                lastChecked = Date()
                Log.write("update check failed: \(error.localizedDescription)")
                state = userInitiated ? .failed(error.localizedDescription) : .idle
            }
        }
    }

    func skip(_ r: Release) {
        store.settings.skippedVersion = r.version
        state = .upToDate
    }

    func dismiss() { state = .idle }

    static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PieFlow/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let obj = try await HTTP.send(req)
        guard let tag = obj["tag_name"] as? String, let page = obj["html_url"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else { throw PieError("Unexpected release data from GitHub") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init) }
        }
        guard let dmg = asset(".dmg") else { throw PieError("Release \(tag) has no DMG attached") }
        return Release(version: version, tag: tag, notes: obj["body"] as? String ?? "", dmgURL: dmg,
                       shaURL: asset(".sha256"), pageURL: URL(string: page)!)
    }

    /// Numeric dotted comparison: 1.0.10 > 1.0.9, 1.1 > 1.0.5.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: install

    func installAvailable() {
        guard let r = availableRelease else { return }
        state = .downloading(0)
        Task { @MainActor in
            do {
                try await install(r)
            } catch {
                Log.write("update failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func install(_ r: Release) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pieflow-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let dmg = work.appendingPathComponent("PieFlow.dmg")
        try await download(r.dmgURL, to: dmg)

        if let shaURL = r.shaURL {
            let (data, _) = try await URLSession.shared.data(from: shaURL)
            let expected = String(data: data, encoding: .utf8)?.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
            guard expected.count == 64, expected == actual else { throw PieError("Downloaded file did not match the published checksum. Update aborted.") }
            Log.write("update: checksum verified \(actual.prefix(12))")
        } else {
            Log.write("update: release has no .sha256 asset, skipping checksum")
        }

        state = .installing
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        let (code, _, err) = try await Shell.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                                ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path], timeout: 120)
        guard code == 0 else { throw PieError("Could not open the update image: \(err.suffix(200))") }
        defer { Task { _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path, "-force"], timeout: 60) } }

        let newApp = mount.appendingPathComponent("PieFlow.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw PieError("The update image does not contain PieFlow.app") }
        let (vcode, _, verr) = try await Shell.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", newApp.path], timeout: 60)
        guard vcode == 0 else { throw PieError("The downloaded app failed signature verification: \(verr.suffix(200))") }

        let dest = URL(fileURLWithPath: Bundle.main.bundlePath)
        let staged = dest.deletingLastPathComponent().appendingPathComponent(".PieFlow-update.app")
        let old = dest.deletingLastPathComponent().appendingPathComponent(".PieFlow-old.app")
        try? FileManager.default.removeItem(at: staged)
        try? FileManager.default.removeItem(at: old)
        // Copy next to the install first so the final swap is two renames on the same volume.
        try FileManager.default.copyItem(at: newApp, to: staged)
        _ = try await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", staged.path], timeout: 30)
        do {
            try FileManager.default.moveItem(at: dest, to: old)
            try FileManager.default.moveItem(at: staged, to: dest)
        } catch {
            // Roll back so the user is never left without an app.
            if !FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.moveItem(at: old, to: dest) }
            throw PieError("Could not replace the app in \(dest.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: old)
        Log.write("update: installed \(r.version) at \(dest.path), relaunching")
        store.flush()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(dest.path)\""]
        try p.run()
        NSApp.terminate(nil)
    }

    private func download(_ url: URL, to dest: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var req = URLRequest(url: url, timeoutInterval: 600)
            req.setValue("PieFlow/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let task = URLSession.shared.downloadTask(with: req) { tmp, resp, err in
                if let err { cont.resume(throwing: err); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let tmp else { cont.resume(throwing: PieError("Download failed (HTTP \(code))")); return }
                do { try FileManager.default.moveItem(at: tmp, to: dest); cont.resume() } catch { cont.resume(throwing: error) }
            }
            observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                DispatchQueue.main.async { if case .downloading = self?.state { self?.state = .downloading(p.fractionCompleted) } }
            }
            downloadTask = task
            task.resume()
        }
    }
}
