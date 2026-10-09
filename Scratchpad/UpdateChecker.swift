import AppKit
import Observation

/// Asks GitHub whether there's a newer release: at launch, then once a day.
///
/// It only finds out and points at the download; installing is still unzip
/// and drag. Releases come from `.github/workflows/release.yml`.
@Observable
final class UpdateChecker {

    struct Release: Equatable {
        let version: String
        let url: URL
    }

    /// A release newer than this build, once a check has found one.
    private(set) var available: Release?

    /// This build's version, e.g. "0.2.0".
    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    private static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/hrellirinn/scratchpad/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private var timer: Timer?

    /// Check now and every day after. Failures are silent; the next check retries.
    func startChecking() {
        Task { try? await check() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { try? await self?.check() }
        }
    }

    /// The newer release, or `nil` if this build is the latest.
    @discardableResult
    func check() async throws -> Release? {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: break
        case 404: available = nil; return nil          // no releases published yet
        default: throw URLError(.badServerResponse)
        }
        let latest = try JSONDecoder().decode(GitHubRelease.self, from: data)

        let version = latest.tagName.hasPrefix("v") ? String(latest.tagName.dropFirst()) : latest.tagName
        available = Self.isVersion(version, newerThan: currentVersion)
            ? Release(version: version, url: latest.htmlURL)
            : nil
        return available
    }

    /// The gear menu's "Check for Updates…": check, then say what was found.
    func checkAndReport() async {
        let alert = NSAlert()
        do {
            if let release = try await check() {
                alert.messageText = "Scratchpad \(release.version) is out"
                alert.informativeText = "You have \(currentVersion). Download it, unzip, and drag it into Applications to replace this one."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(release.url)
                }
                return
            }
            alert.messageText = "You're up to date"
            alert.informativeText = "Scratchpad \(currentVersion) is the latest version."
        } catch {
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    /// "1.10.0" is newer than "1.9.2": compare number by number, missing parts are 0.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// The two fields we need from GitHub's "latest release" response.
private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
