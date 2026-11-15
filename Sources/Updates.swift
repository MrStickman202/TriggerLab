import AppKit

/// Updates: asks GitHub for the newest release, compares it with this app and, when it is
/// newer, downloads it, replaces this app with it and reopens it.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    private static let repo = "MrStickman202/TriggerLab"
    private static let autoKey = "TriggerLab.autoUpdate"
    private var busy = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Update without asking each time the app opens (on unless switched off).
    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: Updater.autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Updater.autoKey) }
    }

    @objc func toggleAutomatic() {
        automatic.toggle()
    }

    /// Called once when the app opens: if a newer version is out, installs it and reopens the
    /// app. Says nothing when there's no update or it can't be installed, so opening the app
    /// never nags; Check for Updates explains what's wrong.
    func checkOnLaunch() {
        guard automatic, !busy else { return }
        busy = true
        Task { @MainActor in
            defer { self.busy = false }
            guard let latest = try? await self.fetchLatest(),
                  Version.isNewer(latest.tag_name, than: self.currentVersion) else { return }
            try? await self.install(latest)
        }
    }

    @objc func checkForUpdates() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { self.busy = false }
            do {
                let latest = try await self.fetchLatest()
                guard Version.isNewer(latest.tag_name, than: self.currentVersion) else {
                    _ = self.ask(title: "Trigger Lab is up to date",
                                 text: "You have the newest version, \(self.currentVersion).",
                                 buttons: ["OK"])
                    return
                }
                let name = latest.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard self.ask(title: "Trigger Lab \(name) is available",
                               text: "You have \(self.currentVersion). Updating replaces this app and reopens it.",
                               buttons: ["Update Now", "Later"]) else { return }
                do {
                    try await self.install(latest)
                } catch {
                    // Couldn't replace the app here (for example it isn't in a folder that can
                    // be written to): offer the download page instead.
                    if self.ask(title: "Couldn't update automatically",
                                text: "\(error.localizedDescription)\nDownload the new version and drag it into Applications instead.",
                                buttons: ["Download", "Cancel"]) {
                        NSWorkspace.shared.open(latest.page)
                    }
                }
            } catch {
                _ = self.ask(title: "Couldn't check for updates",
                             text: "Check your internet connection and try again.\n(\(error.localizedDescription))",
                             buttons: ["OK"])
            }
        }
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let html_url: String
        let assets: [Asset]

        var page: URL {
            URL(string: html_url) ?? URL(string: "https://github.com/\(Updater.repo)/releases/latest")!
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "TriggerLab", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func fetchLatest() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw failure("GitHub answered \(http.statusCode).")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Downloads the release's TriggerLab.zip, checks it really is a newer Trigger Lab, puts it
    /// where this app is and reopens it. Throws, leaving this app untouched, if anything is off.
    private func install(_ release: Release) async throws {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL
        // macOS runs an app that was never moved out of Downloads from a read-only copy.
        guard appURL.pathExtension == "app", !appURL.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            throw failure("Trigger Lab can't replace itself where it is now. Move it into Applications first.")
        }
        guard let asset = release.assets.first(where: { $0.name == "TriggerLab.zip" }),
              let url = URL(string: asset.browser_download_url),
              url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/\(Updater.repo)/releases/download/") else {
            throw failure("The release has no TriggerLab.zip to download.")
        }

        let (downloaded, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw failure("The download failed (\(http.statusCode)).")
        }
        let work = fm.temporaryDirectory.appendingPathComponent("TriggerLabUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent("TriggerLab.zip")
        try fm.moveItem(at: downloaded, to: zip)
        let unpacked = work.appendingPathComponent("unpacked")
        try await Updater.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])

        // Only ever replace this app with a newer version of the same app. The version check
        // also stops an update loop if a release were tagged wrongly.
        let newApp = unpacked.appendingPathComponent("Trigger Lab.app")
        guard let bundle = Bundle(url: newApp),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              Version.isNewer(version, than: currentVersion) else {
            throw failure("The download wasn't a newer Trigger Lab.")
        }

        _ = try fm.replaceItemAt(appURL, withItemAt: newApp)

        // Reopen once this copy has quit (quitting resets the triggers).
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", appURL.path]
        try reopen.run()
        NSApp.terminate(nil)
    }

    /// Runs a command off the main thread and throws if it fails.
    private nonisolated static func run(_ path: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw NSError(domain: "TriggerLab", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "Couldn't unpack the update."])
            }
        }.value
    }

    /// Shows an alert; true when the first button was chosen.
    private func ask(title: String, text: String, buttons: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The menu on a right-click (or Control-click) of the menu bar icon. SwiftUI's MenuBarExtra
/// has no right-click hook, so this watches for the click on the status bar's own window.
@MainActor
final class StatusMenu: NSObject {
    static let shared = StatusMenu()
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        // A few seconds after opening, so the controller is set up first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { Updater.shared.checkOnLaunch() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            let secondary = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard secondary, let window = event.window, let view = window.contentView,
                  window.className.contains("StatusBar") else { return event }
            MainActor.assumeIsolated { StatusMenu.shared.show(in: view, at: event.locationInWindow) }
            return nil
        }
    }

    private func show(in view: NSView, at point: NSPoint) {
        let menu = NSMenu()
        let version = NSMenuItem(title: "Trigger Lab \(Updater.shared.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(Updater.checkForUpdates), keyEquivalent: "")
        update.target = Updater.shared
        menu.addItem(update)
        let auto = NSMenuItem(title: "Update Automatically", action: #selector(Updater.toggleAutomatic), keyEquivalent: "")
        auto.target = Updater.shared
        auto.state = Updater.shared.automatic ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Trigger Lab", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: view.convert(point, from: nil), in: view)
    }

    /// Quitting resets the triggers (the engine listens for the app closing).
    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
