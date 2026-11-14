import AppKit
import UniformTypeIdentifiers

/// Offers, once, to make Gloss the app that opens Markdown files.
@MainActor
enum DefaultViewer {
    private static var asked = false

    static var isDefault: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: .markdown)?.standardizedFileURL
            == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Only an installed copy should offer itself: a development build that
    /// became the default would vanish with its build folder.
    static var isInstalled: Bool {
        Bundle.main.bundlePath.contains("/Applications/")
    }

    /// Returns a message if the change failed.
    static func makeDefault() async -> String? {
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .markdown)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Called after a document has been shown, never on a bare launch.
    static func promptIfNeeded() {
        guard !asked, isInstalled, !isDefault, !Preferences.shared.suppressDefaultViewerPrompt else { return }
        asked = true
        let alert = NSAlert()
        alert.messageText = "Open Markdown files with Gloss?"
        alert.informativeText =
            "Gloss is not the default app for Markdown files. You can change this later in Settings."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            Preferences.shared.suppressDefaultViewerPrompt = true
        }
        if response == .alertFirstButtonReturn {
            Task {
                if let message = await makeDefault() {
                    let failure = NSAlert()
                    failure.alertStyle = .warning
                    failure.messageText = "Gloss could not be made the default."
                    failure.informativeText = message
                    failure.runModal()
                }
            }
        }
    }
}
