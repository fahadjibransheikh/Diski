import AppKit
import CryptoKit
import Security

@MainActor
final class Updater {
    static let shared = Updater()

    private(set) var stagedApp: URL?
    private(set) var stagedVersion: String?
    private var stagingDirectory: URL?
    private var relaunchAfterInstall = false
    private var isChecking = false
    private var started = false
    private var timer: Timer?
    private var announcedVersions = Set<String>()

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if Prefs.automaticUpdates { self?.checkNow(userInitiated: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if Prefs.automaticUpdates { self?.checkNow(userInitiated: false) }
            }
        }
    }

    func checkNow(userInitiated: Bool) {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            var pendingDirectory: URL?
            do {
                guard let url = URL(string: "https://api.github.com/repos/jordylegrand-cpu/Diski/releases/latest") else {
                    throw UpdateError("The release URL is invalid.")
                }
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Diski/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                try Self.requireSuccess(response)
                let release = try JSONDecoder().decode(Release.self, from: data)
                let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
                guard try Self.compareVersions(version, currentVersion) > 0 else {
                    if userInitiated {
                        showAlert("You're up to date", "Diski \(currentVersion) is the latest version.")
                    }
                    return
                }
                if let stagedVersion, try Self.compareVersions(version, stagedVersion) <= 0 {
                    if userInitiated { offerStagedInstall() }
                    return
                }
                guard let asset = release.assets.first(where: { $0.name.hasPrefix("Diski-") && $0.name.hasSuffix(".zip") }),
                      let checksum = try Self.checksum(in: release.body ?? "") else {
                    throw UpdateError("The release is missing its Diski archive or SHA-256 checksum.")
                }
                let bundleURL = Bundle.main.bundleURL
                let path = bundleURL.path
                let (installable, team) = await Task.detached(priority: .utility) { () -> (Bool, String?) in
                    let team = Self.teamIdentifier(of: bundleURL)
                    // Without a team ID there is nothing to pin the update's signer to.
                    let ok = team != nil
                        && !path.contains("/AppTranslocation/") && !path.contains("/DerivedData/")
                        && !path.contains("/Build/Products/")
                        && FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
                    return (ok, team)
                }.value
                guard installable, let team else {
                    if !userInitiated && announcedVersions.contains(version) { return }
                    announcedVersions.insert(version)
                    let alert = NSAlert()
                    alert.messageText = "Diski \(version) is available"
                    alert.informativeText = "Diski can only update itself when it is signed by its developer and sits in a folder it can write to, such as Applications. Download the release and move Diski there to enable in-app updates."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.html_url) }
                    return
                }
                let directory = try await Task.detached(priority: .utility) {
                    try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: bundleURL, create: true)
                }.value
                pendingDirectory = directory
                let (download, downloadResponse) = try await URLSession.shared.download(from: asset.browser_download_url)
                try Self.requireSuccess(downloadResponse)
                let archive = directory.appendingPathComponent("Diski.zip")
                let identifier = Bundle.main.bundleIdentifier
                let app = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.moveItem(at: download, to: archive)
                    return try Self.prepareApp(archive: archive, directory: directory, checksum: checksum,
                                               identifier: identifier, team: team, version: version)
                }.value
                if let previous = stagingDirectory {
                    await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: previous) }.value
                }
                stagingDirectory = directory
                stagedApp = app
                stagedVersion = version
                pendingDirectory = nil
                offerStagedInstall()
            } catch {
                if let pendingDirectory {
                    await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: pendingDirectory) }.value
                }
                if userInitiated { showAlert("Couldn't check for updates", error.localizedDescription) }
            }
        }
    }

    func installStagedUpdateOnTermination() {
        guard let stagedApp, let stagingDirectory else { return }
        let files = FileManager.default
        let destination = Bundle.main.bundleURL
        let oldApp = stagingDirectory.appendingPathComponent("Diski-old.app")
        do {
            try files.moveItem(at: destination, to: oldApp)
        } catch { return }
        do {
            try files.moveItem(at: stagedApp, to: destination)
        } catch {
            // Preserve the backup if restoring it also fails.
            try? files.moveItem(at: oldApp, to: destination)
            return
        }
        try? files.removeItem(at: oldApp)
        try? files.removeItem(at: stagingDirectory)
        if relaunchAfterInstall {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                                 "sh", String(ProcessInfo.processInfo.processIdentifier), destination.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }

    private func offerStagedInstall() {
        guard let stagedVersion else { return }
        let alert = NSAlert()
        alert.messageText = "Diski \(stagedVersion) is ready to install"
        alert.informativeText = "Diski relaunches with your windows and tabs where they were. Choose Later to install it when you quit Diski."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            relaunchAfterInstall = true
            NSApp.terminate(nil)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let body: String?
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    nonisolated private static func requireSuccess(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw UpdateError("GitHub did not return a successful response.")
        }
    }

    nonisolated static func components(_ version: String) throws -> [Int] {
        let stripped = version.hasPrefix("v") ? String(version.dropFirst()) : version
        guard let base = stripped.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first,
              !base.isEmpty else { throw UpdateError("The release version is invalid.") }
        let parts = base.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { throw UpdateError("The release version is invalid.") }
        return try parts.map {
            guard let number = Int($0), number >= 0 else { throw UpdateError("The release version is invalid.") }
            return number
        }
    }

    nonisolated static func compareVersions(_ left: String, _ right: String) throws -> Int {
        let lhs = try components(left)
        let rhs = try components(right)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b ? 1 : -1 }
        }
        return 0
    }

    nonisolated static func checksum(in body: String) throws -> String? {
        let regex = try NSRegularExpression(pattern: "SHA-256:\\s*`([0-9a-fA-F]{64})`")
        guard let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else { return nil }
        return String(body[range]).lowercased()
    }

    nonisolated private static let validityFlags = SecCSFlags(
        rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures))

    nonisolated private static func prepareApp(archive: URL, directory: URL, checksum: String,
                                               identifier: String?, team: String, version: String) throws -> URL {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == checksum else { throw UpdateError("The downloaded archive's SHA-256 checksum does not match.") }
        let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) == 0 else {
            throw UpdateError("The update archive could not be unpacked.")
        }
        let app = unpacked.appendingPathComponent("Diski.app", isDirectory: true)
        let plist = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any],
              let identifier, info["CFBundleIdentifier"] as? String == identifier,
              let appVersion = info["CFBundleShortVersionString"] as? String,
              try compareVersions(appVersion, version) == 0 else {
            throw UpdateError("The update's app identifier or version does not match the release.")
        }
        _ = try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        // A Developer ID build only accepts updates signed by the same team.
        var requirement: SecRequirement?
        if SecRequirementCreateWithString(
            "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &requirement) != errSecSuccess {
            throw UpdateError("The update's signing requirement could not be created.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, Self.validityFlags, requirement) == errSecSuccess else {
            throw UpdateError("The update's code signature is invalid or from another developer.")
        }
        return app
    }

    nonisolated private static func teamIdentifier(of bundle: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
