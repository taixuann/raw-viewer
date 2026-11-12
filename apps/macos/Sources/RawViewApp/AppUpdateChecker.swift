import AppKit
import Foundation
import RawViewCore
import SwiftUI

@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    @Published var updateAvailable: Bool = false
    @Published var latestVersion: String = ""
    @Published var releaseURL: URL?
    @Published var assetDownloadURL: URL?
    @Published var releaseNotes: String = ""

    private var apiAssetURL: URL?
    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?
    private var progressSubtitle: NSTextField?

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
                (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.3.8"

            if isNewer(latest: latest, current: current) {
                let releaseHtmlUrl = (json["html_url"] as? String).flatMap(URL.init)
                let body =
                    (json["body"] as? String) ?? "A new version of RawView is available."

                var appAssetURL: URL? = nil
                var apiAssetURL: URL? = nil
                if let assets = json["assets"] as? [[String: Any]] {
                    for asset in assets {
                        if let name = asset["name"] as? String, name == "RawView-macOS.zip" {
                            if let downloadUrlStr = asset["browser_download_url"] as? String {
                                appAssetURL = URL(string: downloadUrlStr)
                            }
                            if let apiUrlStr = asset["url"] as? String {
                                apiAssetURL = URL(string: apiUrlStr)
                            }
                        }
                    }
                }
                if appAssetURL == nil {
                    appAssetURL = URL(
                        string:
                            "https://github.com/\(repo)/releases/download/\(tagName)/RawView-macOS.zip"
                    )
                }

                self.latestVersion = tagName
                self.releaseURL = releaseHtmlUrl
                self.assetDownloadURL = appAssetURL
                self.apiAssetURL = apiAssetURL
                self.releaseNotes = body
                self.updateAvailable = true

                if userInitiated {
                    showUpdateAlert(
                        latestTag: tagName, assetURL: appAssetURL, releaseURL: releaseHtmlUrl,
                        notes: body)
                }
            } else {
                self.updateAvailable = false
                if userInitiated {
                    showAlert(
                        title: "You're Up to Date",
                        message: "RawView v\(current) is currently the newest version available.")
                }
            }
        } catch {
            if userInitiated {
                showAlert(title: "Update Check Failed", message: error.localizedDescription)
            }
        }
    }

    func isNewer(latest: String, current: String) -> Bool {
        SemanticVersion.isNewer(latest: latest, current: current)
    }

    func parseVersion(_ v: String) -> (Int, Int, Int) {
        let ver = SemanticVersion(v)
        return (ver.major, ver.minor, ver.patch)
    }

    private func showUpdateAlert(
        latestTag: String, assetURL: URL?, releaseURL: URL?, notes: String
    ) {
        let alert = NSAlert()
        alert.messageText = "Update Available: \(latestTag)"
        alert.informativeText =
            "A new version of RawView is available.\n\n\(notes.prefix(300))\n\nWould you like to install the update now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let assetURL = assetURL {
                Task {
                    await downloadAndInstall(assetURL: assetURL, latestTag: latestTag)
                }
            } else if let url = releaseURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showProgressWindow(title: String, subtitle: String) {
        if let window = progressWindow {
            progressLabel?.stringValue = title
            progressSubtitle?.stringValue = subtitle
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "RawView Update"
        window.center()
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 130))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.frame = NSRect(x: 24, y: 76, width: 312, height: 20)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: 24, y: 52, width: 312, height: 18)

        let indicator = NSProgressIndicator(frame: NSRect(x: 24, y: 22, width: 312, height: 20))
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)

        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(indicator)
        window.contentView = contentView

        self.progressLabel = titleLabel
        self.progressSubtitle = subtitleLabel
        self.progressWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeProgressWindow() {
        progressWindow?.close()
        progressWindow = nil
        progressLabel = nil
        progressSubtitle = nil
    }

    func applyUpdateAndRestart() async {
        guard let assetURL = assetDownloadURL else {
            if let url = releaseURL {
                NSWorkspace.shared.open(url)
            }
            return
        }
        await downloadAndInstall(assetURL: assetURL, latestTag: latestVersion)
    }

    private func downloadAndInstall(assetURL: URL, latestTag: String) async {
        showProgressWindow(
            title: "Updating RawView to \(latestTag)",
            subtitle: "Downloading update package..."
        )

        do {
            var downloadResult: (URL, URLResponse)? = nil

            // 1. Try direct GitHub API asset endpoint with Accept: application/octet-stream
            // (bypasses GitHub web 504 gateway timeouts on /releases/download)
            if let apiURL = apiAssetURL {
                var req = URLRequest(url: apiURL)
                req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                req.setValue("RawView-macOS", forHTTPHeaderField: "User-Agent")
                if let res = try? await URLSession.shared.download(for: req),
                   let http = res.1 as? HTTPURLResponse, http.statusCode == 200 {
                    downloadResult = res
                }
            }

            // 2. Fallback to browser_download_url if API endpoint didn't succeed
            if downloadResult == nil {
                let res = try await URLSession.shared.download(from: assetURL)
                if let http = res.1 as? HTTPURLResponse, http.statusCode == 200 {
                    downloadResult = res
                } else {
                    let code = (res.1 as? HTTPURLResponse)?.statusCode ?? 0
                    closeProgressWindow()
                    showAlert(
                        title: "Update Failed",
                        message: "Could not download update archive (HTTP \(code)). Please check your connection or download directly from GitHub."
                    )
                    return
                }
            }

            guard let (tempLocalURL, _) = downloadResult else {
                closeProgressWindow()
                showAlert(title: "Update Failed", message: "Failed to download update package.")
                return
            }

            progressSubtitle?.stringValue = "Extracting and preparing update..."

            let fileManager = FileManager.default
            let extractDir = fileManager.temporaryDirectory.appendingPathComponent(
                "RawViewUpdate-\(UUID().uuidString)")
            try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)

            // Extract with /usr/bin/ditto preserving macOS attributes and signatures
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-xk", tempLocalURL.path, extractDir.path]
            try ditto.run()
            ditto.waitUntilExit()

            guard ditto.terminationStatus == 0 else {
                closeProgressWindow()
                showAlert(title: "Update Failed", message: "Failed to extract update package.")
                return
            }

            let newAppURL = extractDir.appendingPathComponent("RawView.app")
            guard fileManager.fileExists(atPath: newAppURL.path) else {
                closeProgressWindow()
                showAlert(
                    title: "Update Failed",
                    message: "Extracted archive did not contain RawView.app.")
                return
            }

            // Determine target destination
            var targetAppURL = Bundle.main.bundleURL
            let targetPath = targetAppURL.path
            if !targetPath.hasSuffix(".app") {
                targetAppURL = URL(fileURLWithPath: "/Applications/RawView.app")
            }

            progressSubtitle?.stringValue = "Installing and restarting..."

            // Write helper relaunch script
            let scriptURL = fileManager.temporaryDirectory.appendingPathComponent(
                "rawview_relaunch_\(UUID().uuidString).sh")
            let pid = ProcessInfo.processInfo.processIdentifier

            let script = """
                #!/bin/sh
                while kill -0 \(pid) 2>/dev/null; do
                    sleep 0.1
                done

                /usr/bin/xattr -dr com.apple.quarantine "\(newAppURL.path)" 2>/dev/null || true

                rm -rf "\(targetAppURL.path)"
                cp -R "\(newAppURL.path)" "\(targetAppURL.path)"

                /usr/bin/xattr -dr com.apple.quarantine "\(targetAppURL.path)" 2>/dev/null || true

                rm -rf "\(extractDir.path)"
                rm -f "$0"

                open "\(targetAppURL.path)"
                """

            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let relauncher = Process()
            relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
            relauncher.arguments = [scriptURL.path]
            try relauncher.run()

            closeProgressWindow()
            NSApp.terminate(nil)
        } catch {
            closeProgressWindow()
            showAlert(title: "Update Failed", message: error.localizedDescription)
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
