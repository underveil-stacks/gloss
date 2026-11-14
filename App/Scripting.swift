import AppKit

/// What AppleScript can read about a page. Captured when a load finishes,
/// because script property getters are synchronous and the page is not.
struct PageSnapshot {
    var text = ""
    var html = ""
    var outline: [String] = []
}

/// Finds the page showing a given file, so a scripted `document` can answer
/// questions about what is on screen.
@MainActor
enum PageRegistry {
    private struct Entry { weak var model: PageModel? }
    private static var entries: [URL: Entry] = [:]

    static func register(_ model: PageModel, for file: URL) {
        entries = entries.filter { $0.value.model != nil }
        entries[file.standardizedFileURL] = Entry(model: model)
    }

    static var all: [PageModel] {
        entries.values.compactMap(\.model)
    }

    static func model(for file: URL?) -> PageModel? {
        guard let file else { return nil }
        return entries[file.standardizedFileURL]?.model
    }
}

extension NSApplication {
    /// The agent skill, bundled so the guide always matches the running version.
    /// The agent skill, then the reference for writing Markdown for Gloss,
    /// bundled so both always match the running version.
    @objc var glossAgentGuide: String {
        ["SKILL", "AUTHORING"].compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }.joined(separator: "\n\n")
    }

    // Settings are the one thing scripting may change. Documents stay
    // read-only.

    @objc var glossAppearanceMode: String {
        get { MainActor.assumeIsolated { Preferences.shared.appearanceMode.rawValue } }
        set {
            MainActor.assumeIsolated {
                if let mode = AppearanceMode(rawValue: newValue.lowercased()) { Preferences.shared.appearanceMode = mode }
            }
        }
    }

    @objc var glossLightTheme: String {
        get { MainActor.assumeIsolated { Preferences.shared.lightThemeID } }
        set { MainActor.assumeIsolated { Preferences.shared.lightThemeID = newValue } }
    }

    @objc var glossDarkTheme: String {
        get { MainActor.assumeIsolated { Preferences.shared.darkThemeID } }
        set { MainActor.assumeIsolated { Preferences.shared.darkThemeID = newValue } }
    }

    @objc var glossTextWidth: String {
        get { MainActor.assumeIsolated { Preferences.shared.textWidth.rawValue } }
        set {
            MainActor.assumeIsolated {
                if let width = TextWidth(rawValue: newValue.lowercased()) { Preferences.shared.textWidth = width }
            }
        }
    }

    @objc var glossZoom: Double {
        get { MainActor.assumeIsolated { Preferences.shared.zoom } }
        set { MainActor.assumeIsolated { Preferences.shared.zoom = min(max(newValue, 0.5), 3) } }
    }

    /// Identifiers of every installed theme and add-on.
    @objc var glossBundleIdentifiers: [String] {
        MainActor.assumeIsolated { BundleLibrary.shared.bundles.map(\.id) }
    }
}

/// The scripting dictionary (`Gloss.sdef`) maps its document properties to
/// these keys. All are read-only: scripting can inspect Gloss, not change a
/// document.
extension NSDocument {
    private var glossPage: PageModel? {
        MainActor.assumeIsolated { PageRegistry.model(for: fileURL) }
    }

    /// A document whose page has not registered yet is still loading.
    @objc var glossLoading: Bool {
        MainActor.assumeIsolated { glossPage?.isLoading ?? true }
    }

    @objc var glossPageText: String {
        MainActor.assumeIsolated { glossPage?.snapshot.text ?? "" }
    }

    @objc var glossPageHTML: String {
        MainActor.assumeIsolated { glossPage?.snapshot.html ?? "" }
    }

    @objc var glossOutline: [String] {
        MainActor.assumeIsolated { glossPage?.snapshot.outline ?? [] }
    }

    @objc var glossTheme: String {
        MainActor.assumeIsolated { glossPage?.themeID ?? "" }
    }

    @objc var glossFileMissing: Bool {
        MainActor.assumeIsolated { glossPage?.fileMissing ?? false }
    }

    @objc var glossAppearance: String {
        MainActor.assumeIsolated { glossPage?.appearance ?? "" }
    }
}

/// `show settings`: opens the Settings window.
@objc(GlossShowSettingsCommand)
final class ShowSettingsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            NSApp.activate()
            SettingsOpener.open?()
        }
        return nil
    }
}

/// Holds SwiftUI's own "open Settings" action, which only a view can obtain.
@MainActor
enum SettingsOpener {
    static var open: (() -> Void)?
}
