import AppKit

/// Check for Updates: asks GitHub for the newest release and compares it with this app.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    private static let repo = "MrStickman202/TriggerLab"
    private var checking = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    @objc func checkForUpdates() {
        guard !checking else { return }
        checking = true
        Task { @MainActor in
            defer { self.checking = false }
            do {
                let latest = try await self.fetchLatest()
                if Version.isNewer(latest.tag, than: self.currentVersion) {
                    let download = self.ask(
                        title: "Trigger Lab \(latest.tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))) is available",
                        text: "You have \(self.currentVersion). Download the new version, then drag it into Applications to replace this one.",
                        buttons: ["Download", "Later"])
                    if download { NSWorkspace.shared.open(latest.page) }
                } else {
                    _ = self.ask(title: "Trigger Lab is up to date",
                                 text: "You have the newest version, \(self.currentVersion).",
                                 buttons: ["OK"])
                }
            } catch {
                _ = self.ask(title: "Couldn't check for updates",
                             text: "Check your internet connection and try again.\n(\(error.localizedDescription))",
                             buttons: ["OK"])
            }
        }
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }

    private func fetchLatest() async throws -> (tag: String, page: URL) {
        let url = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "TriggerLab", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub answered \(http.statusCode)"])
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let page = URL(string: release.html_url)
            ?? URL(string: "https://github.com/\(Updater.repo)/releases/latest")!
        return (release.tag_name, page)
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
