import AppKit
import CryptoKit
import Foundation
import Observation

struct AvailableAppUpdate: Identifiable, Equatable, Codable {
    var id: String { version }
    let version: String
    let assetName: String
    let downloadURL: URL
    let expectedSHA256: String
    let expectedSize: Int
}

@MainActor
@Observable
final class AppUpdater {
    private(set) var availableUpdate: AvailableAppUpdate?
    private(set) var isChecking = false
    private(set) var isInstalling = false
    private(set) var statusMessage = "Updates werden taeglich geprueft."
    var errorMessage: String?

    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/contrango/afmchat/releases/latest")!
    private static let lastCheckDefaultsKey = "AFMChat.lastUpdateCheck"
    private static let cachedUpdateDefaultsKey = "AFMChat.availableUpdate"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let maximumArchiveSize = 250 * 1024 * 1024

    func checkIfNeeded() async {
        if let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckDefaultsKey) as? Date,
           Date().timeIntervalSince(lastCheck) < Self.checkInterval {
            restoreCachedUpdate()
            return
        }
        await checkForUpdates(showErrors: false)
    }

    func checkNow() async {
        await checkForUpdates(showErrors: true)
    }

    func runPeriodicChecks() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 24 * 60 * 60 * 1_000_000_000)
            } catch {
                return
            }
            await checkIfNeeded()
        }
    }

    private func checkForUpdates(showErrors: Bool) async {
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        if showErrors { errorMessage = nil }
        statusMessage = "Suche nach einer neuen Version ..."
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            guard let versionComparison = Self.compareVersions(release.version, currentVersion) else {
                throw UpdateFailure.invalidVersion
            }
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckDefaultsKey)

            guard versionComparison > 0 else {
                availableUpdate = nil
                UserDefaults.standard.removeObject(forKey: Self.cachedUpdateDefaultsKey)
                statusMessage = "AFM Chat ist auf dem aktuellen Stand."
                return
            }

            availableUpdate = release
            if let cachedData = try? JSONEncoder().encode(release) {
                UserDefaults.standard.set(cachedData, forKey: Self.cachedUpdateDefaultsKey)
            }
            statusMessage = "Version \(release.version) ist verfuegbar."
        } catch {
            restoreCachedUpdate()
            if availableUpdate == nil {
                statusMessage = "Die Update-Pruefung ist fehlgeschlagen."
            }
            if showErrors { errorMessage = error.localizedDescription }
        }
    }

    private func restoreCachedUpdate() {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedUpdateDefaultsKey),
              let update = try? JSONDecoder().decode(AvailableAppUpdate.self, from: data),
              Self.compareVersions(update.version, Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") == 1 else {
            UserDefaults.standard.removeObject(forKey: Self.cachedUpdateDefaultsKey)
            return
        }
        availableUpdate = update
        statusMessage = "Version \(update.version) ist verfuegbar."
    }

    private func fetchLatestRelease() async throws -> AvailableAppUpdate {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AFM-Chat-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateFailure.githubUnavailable
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let matchingAssets = release.assets.filter(Self.isAppArchive)
        guard !release.draft, !release.prerelease,
              let version = Self.versionText(from: release.tagName),
              matchingAssets.count == 1,
              let asset = matchingAssets.first else {
            throw UpdateFailure.noInstallAsset
        }
        guard let downloadURL = URL(string: asset.browserDownloadURL),
              downloadURL.scheme?.lowercased() == "https",
              downloadURL.host?.lowercased() == "github.com",
              downloadURL.path.hasPrefix("/contrango/afmchat/releases/download/"),
              !asset.name.contains("/"), !asset.name.contains("\\") else {
            throw UpdateFailure.invalidDownloadURL
        }
        guard let digestValue = asset.digest?.lowercased(),
              let separator = digestValue.firstIndex(of: ":"),
              digestValue[..<separator] == "sha256" else {
            throw UpdateFailure.noChecksum
        }
        let digest = String(digestValue[digestValue.index(after: separator)...])
        guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              asset.size > 0, asset.size <= Self.maximumArchiveSize else {
            throw UpdateFailure.invalidChecksum
        }

        return AvailableAppUpdate(
            version: version,
            assetName: asset.name,
            downloadURL: downloadURL,
            expectedSHA256: digest,
            expectedSize: asset.size
        )
    }

    private static func isAppArchive(_ asset: GitHubAsset) -> Bool {
        let name = asset.name.lowercased()
        let hasAppName = name.hasPrefix("afm.chat.") || name.hasPrefix("afm-chat-") || name.hasPrefix("afm-chat.")
        let isZip = name.hasSuffix(".zip")
        let isNotSourcePackage = !name.contains("source") && !name.contains("repository") && !name.contains("xcode")
        return hasAppName && isZip && isNotSourcePackage
    }

    func downloadAndInstall() async {
        guard let update = availableUpdate, !isInstalling else { return }
        isInstalling = true
        errorMessage = nil
        statusMessage = "Lade Version \(update.version) ..."
        defer { isInstalling = false }

        let fileManager = FileManager.default
        let installedAppURL = Bundle.main.bundleURL.standardizedFileURL
        let destinationDirectory = installedAppURL.deletingLastPathComponent()
        var stagedAppURL: URL?
        var installerStarted = false

        do {
            guard installedAppURL.pathExtension.lowercased() == "app" else {
                throw UpdateFailure.invalidInstalledApp
            }
            try verifyWritableDirectory(destinationDirectory)

            let workDirectory = try updatesDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: workDirectory) }

            let request = URLRequest(url: update.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            defer { try? fileManager.removeItem(at: temporaryURL) }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw UpdateFailure.downloadFailed
            }

            let archiveURL = workDirectory.appendingPathComponent(update.assetName)
            try fileManager.copyItem(at: temporaryURL, to: archiveURL)
            let attributes = try fileManager.attributesOfItem(atPath: archiveURL.path)
            let actualSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard actualSize == update.expectedSize,
                  actualSize > 0, actualSize <= Self.maximumArchiveSize else {
                throw UpdateFailure.archiveSizeMismatch
            }

            let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
            let actualDigest = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
            guard actualDigest == update.expectedSHA256 else {
                throw UpdateFailure.checksumMismatch
            }

            statusMessage = "Pruefe das App-Paket ..."
            let extractionDirectory = workDirectory.appendingPathComponent("Extracted", isDirectory: true)
            try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
            try extractArchive(archiveURL, to: extractionDirectory)
            let downloadedAppURL = try findAppBundle(in: extractionDirectory)
            try verifyDownloadedApp(downloadedAppURL, expectedVersion: update.version)

            let stagedURL = destinationDirectory.appendingPathComponent(".AFMChat-update-\(UUID().uuidString).app", isDirectory: true)
            try fileManager.copyItem(at: downloadedAppURL, to: stagedURL)
            stagedAppURL = stagedURL
            try verifyDownloadedApp(stagedURL, expectedVersion: update.version)

            statusMessage = "Update bereit. AFM Chat wird ersetzt und neu gestartet ..."
            try startInstaller(installedAppURL: installedAppURL, stagedAppURL: stagedURL)
            installerStarted = true
            stagedAppURL = nil

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                NSApplication.shared.terminate(nil)
            }
        } catch {
            if !installerStarted, let stagedAppURL {
                try? fileManager.removeItem(at: stagedAppURL)
            }
            statusMessage = "Das Update konnte nicht installiert werden."
            errorMessage = error.localizedDescription
        }
    }

    private func verifyWritableDirectory(_ directory: URL) throws {
        let probe = directory.appendingPathComponent(".afmchat-update-write-test-\(UUID().uuidString)")
        do {
            try Data("test".utf8).write(to: probe, options: .atomic)
            try FileManager.default.removeItem(at: probe)
        } catch {
            try? FileManager.default.removeItem(at: probe)
            throw UpdateFailure.installLocationNotWritable
        }
    }

    private func extractArchive(_ archiveURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure.archiveExtractionFailed }
    }

    private func findAppBundle(in directory: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw UpdateFailure.archiveExtractionFailed
        }
        var candidates: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension.lowercased() == "app" {
                candidates.append(url)
                enumerator.skipDescendants()
            }
        }
        guard candidates.count == 1, let appURL = candidates.first else {
            throw UpdateFailure.archiveDoesNotContainSingleApp
        }
        return appURL
    }

    private func verifyDownloadedApp(_ appURL: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateFailure.wrongAppBundle
        }
        guard let bundledVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              Self.compareVersions(bundledVersion, expectedVersion) == 0 else {
            throw UpdateFailure.versionDoesNotMatchRelease
        }
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard Self.compareVersions(bundledVersion, currentVersion) == 1 else {
            throw UpdateFailure.versionNotNewer
        }
    }

    private func startInstaller(installedAppURL: URL, stagedAppURL: URL) throws {
        let helperDirectory = try updatesDirectory()
        let helperURL = helperDirectory.appendingPathComponent("install-\(UUID().uuidString).sh")
        let backupURL = installedAppURL.deletingLastPathComponent()
            .appendingPathComponent(".AFMChat-backup-\(UUID().uuidString).app", isDirectory: true)

        let script = """
        #!/bin/sh
        APP="$1"
        STAGED="$2"
        PID="$3"
        BACKUP="$4"
        while /bin/kill -0 "$PID" 2>/dev/null; do /bin/sleep 0.2; done
        if ! /bin/mv "$APP" "$BACKUP"; then
            /usr/bin/open "$APP" >/dev/null 2>&1 || true
            /bin/rm -rf "$STAGED"
            /bin/rm -f "$0"
            exit 1
        fi
        if ! /bin/mv "$STAGED" "$APP"; then
            /bin/mv "$BACKUP" "$APP" 2>/dev/null || true
            /usr/bin/open "$APP" >/dev/null 2>&1 || true
            /bin/rm -rf "$STAGED"
            /bin/rm -f "$0"
            exit 1
        fi
        if ! /usr/bin/open "$APP"; then
            /bin/rm -rf "$APP"
            /bin/mv "$BACKUP" "$APP" 2>/dev/null || true
            /usr/bin/open "$APP" >/dev/null 2>&1 || true
            /bin/rm -f "$0"
            exit 1
        fi
        /bin/sleep 5
        /bin/rm -rf "$BACKUP"
        /bin/rm -f "$0"
        """
        try script.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            helperURL.path,
            installedAppURL.path,
            stagedAppURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            backupURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func updatesDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw UpdateFailure.cannotCreateUpdateFolder
        }
        let directory = support.appendingPathComponent("FMChat/Updates", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw UpdateFailure.cannotCreateUpdateFolder
        }
        return directory
    }

    private static func versionText(from tag: String) -> String? {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") { value.removeFirst() }
        return versionComponents(value) == nil ? nil : value
    }

    private static func versionComponents(_ value: String) -> [Int]? {
        let core = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var result: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            result.append(number)
        }
        return result
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> Int? {
        guard let left = versionComponents(lhs), let right = versionComponents(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String
    let size: Int
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case digest
    }
}

private enum UpdateFailure: LocalizedError {
    case githubUnavailable
    case noInstallAsset
    case invalidDownloadURL
    case noChecksum
    case invalidChecksum
    case invalidVersion
    case invalidInstalledApp
    case installLocationNotWritable
    case downloadFailed
    case archiveSizeMismatch
    case checksumMismatch
    case archiveExtractionFailed
    case archiveDoesNotContainSingleApp
    case wrongAppBundle
    case versionDoesNotMatchRelease
    case versionNotNewer
    case cannotCreateUpdateFolder

    var errorDescription: String? {
        switch self {
        case .githubUnavailable:
            return "GitHub ist gerade nicht erreichbar. Pruefe deine Internetverbindung und versuche es spaeter erneut."
        case .noInstallAsset:
            return "Im neuesten GitHub-Release wurde kein passendes AFM-Chat-App-ZIP gefunden."
        case .invalidDownloadURL:
            return "GitHub hat keine sichere HTTPS-Downloadadresse geliefert."
        case .noChecksum:
            return "GitHub hat fuer das App-Paket keinen SHA-256-Pruefwert geliefert. Das Update wurde aus Sicherheitsgruenden abgebrochen."
        case .invalidChecksum:
            return "Der vom GitHub-Release gelieferte SHA-256-Pruefwert ist ungueltig."
        case .invalidVersion:
            return "Die Versionsnummer im GitHub-Release ist ungueltig."
        case .invalidInstalledApp:
            return "AFM Chat wird nicht aus einem .app-Paket gestartet. Installiere die App zuerst in einen App-Ordner."
        case .installLocationNotWritable:
            return "AFM Chat kann sich an diesem Speicherort nicht selbst ersetzen. Verschiebe die App zum Beispiel nach ~/Applications und starte sie von dort erneut."
        case .downloadFailed:
            return "Das App-Paket konnte nicht von GitHub heruntergeladen werden."
        case .archiveSizeMismatch:
            return "Die heruntergeladene Dateigroesse stimmt nicht mit GitHub ueberein."
        case .checksumMismatch:
            return "Die SHA-256-Pruefung ist fehlgeschlagen. Das App-Paket wurde nicht installiert."
        case .archiveExtractionFailed:
            return "Das App-ZIP konnte nicht sicher entpackt werden."
        case .archiveDoesNotContainSingleApp:
            return "Das ZIP muss genau ein macOS-App-Paket enthalten."
        case .wrongAppBundle:
            return "Das heruntergeladene Paket ist nicht AFM Chat."
        case .versionDoesNotMatchRelease:
            return "Die App-Version im ZIP stimmt nicht mit der GitHub-Release-Version ueberein."
        case .versionNotNewer:
            return "Das heruntergeladene App-Paket ist nicht neuer als die installierte Version."
        case .cannotCreateUpdateFolder:
            return "Der temporaere Update-Ordner konnte nicht angelegt werden."
        }
    }
}
