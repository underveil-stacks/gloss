import AppKit
import Foundation

extension Notification.Name {
    /// Themes, add-ons or appearance changed: open pages must be rebuilt.
    static let glossLookChanged = Notification.Name("io.sigler.webby.gloss.lookChanged")
    static let glossZoomChanged = Notification.Name("io.sigler.webby.gloss.zoomChanged")
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum TextWidth: String, CaseIterable, Identifiable {
    case window, theme
    var id: String { rawValue }
    var label: String {
        switch self {
        case .window: "Fit window"
        case .theme: "Theme measure"
        }
    }
}

enum DockIcon: String, CaseIterable, Identifiable {
    case standard, sheen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: "Colour blocks"
        case .sheen: "Sheen"
        }
    }
    /// The asset shown in the Dock while Gloss runs. The standard icon is the
    /// app's own, so it needs no override.
    var imageName: String? { self == .sheen ? "AltIconSheen" : nil }
    var previewName: String { self == .sheen ? "AltIconSheen" : "IconPreview" }
}

/// The reader's settings, stored in user defaults.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    static let defaultDarkTheme = "io.sigler.webby.gloss.dark"
    static let defaultLightTheme = "io.sigler.webby.gloss.light"
    static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    private let defaults: UserDefaults

    var appearanceMode: AppearanceMode { didSet { save(appearanceMode.rawValue, "appearanceMode", look: true) } }
    var lightThemeID: String { didSet { save(lightThemeID, "lightThemeID", look: true) } }
    var darkThemeID: String { didSet { save(darkThemeID, "darkThemeID", look: true) } }
    var disabledAddOns: Set<String> { didSet { save(Array(disabledAddOns).sorted(), "disabledAddOns", look: true) } }
    var textWidth: TextWidth { didSet { save(textWidth.rawValue, "textWidth", look: true) } }
    var zoom: Double {
        didSet {
            defaults.set(zoom, forKey: "zoom")
            NotificationCenter.default.post(name: .glossZoomChanged, object: nil)
        }
    }
    var dockIcon: DockIcon {
        didSet {
            defaults.set(dockIcon.rawValue, forKey: "dockIcon")
            applyDockIcon()
        }
    }
    var suppressDefaultViewerPrompt: Bool {
        didSet { defaults.set(suppressDefaultViewerPrompt, forKey: "suppressDefaultViewerPrompt") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .auto
        lightThemeID = defaults.string(forKey: "lightThemeID") ?? Self.defaultLightTheme
        darkThemeID = defaults.string(forKey: "darkThemeID") ?? Self.defaultDarkTheme
        disabledAddOns = Set(defaults.stringArray(forKey: "disabledAddOns") ?? [])
        textWidth = TextWidth(rawValue: defaults.string(forKey: "textWidth") ?? "") ?? .window
        let storedZoom = defaults.double(forKey: "zoom")
        zoom = storedZoom > 0 ? storedZoom : 1
        dockIcon = DockIcon(rawValue: defaults.string(forKey: "dockIcon") ?? "") ?? .standard
        suppressDefaultViewerPrompt = defaults.bool(forKey: "suppressDefaultViewerPrompt")
    }

    private func save(_ value: Any, _ key: String, look: Bool) {
        defaults.set(value, forKey: key)
        if look { NotificationCenter.default.post(name: .glossLookChanged, object: nil) }
    }

    func themeID(for appearance: String) -> String {
        appearance == "dark" ? darkThemeID : lightThemeID
    }

    func zoomIn() { zoom = Self.zoomSteps.first { $0 > zoom + 0.001 } ?? zoom }
    func zoomOut() { zoom = Self.zoomSteps.last { $0 < zoom - 0.001 } ?? zoom }
    func resetZoom() { zoom = 1 }

    /// macOS has no supported way to change an installed app's icon in Finder
    /// or Launchpad. This changes the Dock icon for as long as Gloss runs.
    func applyDockIcon() {
        NSApp?.applicationIconImage = dockIcon.imageName.flatMap { NSImage(named: $0) }
    }
}
