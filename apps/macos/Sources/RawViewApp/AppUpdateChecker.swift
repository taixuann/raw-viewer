import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    @Published var updateAvailable: Bool = false
    @Published var latestVersion: String = ""
    @Published var releaseURL: URL?
    @Published var releaseNotes: String = ""

    private let repo = "taixuann/raw-viewer"

    func checkForUpdates(userInitiated: Bool = false) async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("RawView-macOS", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200
            else {
                if userInitiated {
                    showAlert(
                        title: "Update Check Failed",
                        message: "Could not connect to GitHub releases.")
                }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tagName = json["tag_name"] as? String
            else {
                return
            }

            let latest = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let current =
                (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.2.0"

            if isNewer(latest: latest, current: current) {
                let releaseHtmlUrl = (json["html_url"] as? String).flatMap(URL.init)
                let body =
                    (json["body"] as? String) ?? "A new version of RawView is available."

                self.latestVersion = tagName
                self.releaseURL = releaseHtmlUrl
                self.releaseNotes = body
                self.updateAvailable = true

                showUpdateAlert(latestTag: tagName, releaseURL: releaseHtmlUrl, notes: body)
            } else if userInitiated {
                showAlert(
                    title: "You're Up to Date", message: "RawView \(current) is the latest version."
                )
            }
        } catch {
            if userInitiated {
                showAlert(title: "Update Check Failed", message: error.localizedDescription)
            }
        }
    }

    func isNewer(latest: String, current: String) -> Bool {
        let l = parseVersion(latest)
        let c = parseVersion(current)
        if l.0 != c.0 { return l.0 > c.0 }
        if l.1 != c.1 { return l.1 > c.1 }
        return l.2 > c.2
    }

    func parseVersion(_ v: String) -> (Int, Int, Int) {
        let parts = v.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }
        let major = parts.count > 0 ? parts[0] : 0
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        return (major, minor, patch)
    }

    private func showUpdateAlert(latestTag: String, releaseURL: URL?, notes: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available: \(latestTag)"
        alert.informativeText = "A new version of RawView is available.\n\n\(notes.prefix(300))"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = releaseURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
