import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            BundleSettings()
                .tabItem { Label("Bundles", systemImage: "shippingbox") }
        }
        .frame(width: 520, height: 600)
    }
}

private struct GeneralSettings: View {
    @Bindable private var preferences = Preferences.shared
    private let library = BundleLibrary.shared
    @State private var isDefault = DefaultViewer.isDefault
    @State private var defaultError: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $preferences.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                ThemePicker(title: "Light theme", appearance: "light", selection: $preferences.lightThemeID)
                ThemePicker(title: "Dark theme", appearance: "dark", selection: $preferences.darkThemeID)
                Text("Auto follows the system and uses the light or dark theme to match.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Text width", selection: $preferences.textWidth) {
                    ForEach(TextWidth.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Theme measure keeps lines to the width the theme was designed for.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Default viewer") {
                LabeledContent("Markdown files") {
                    if isDefault {
                        Label("Open in Gloss", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    } else {
                        Button("Make Gloss the Default") {
                            Task {
                                defaultError = await DefaultViewer.makeDefault()
                                isDefault = DefaultViewer.isDefault
                            }
                        }
                    }
                }
                if let defaultError {
                    Text(defaultError).font(.footnote).foregroundStyle(.red)
                }
                Toggle(
                    "Ask when Gloss is not the default",
                    isOn: Binding(
                        get: { !preferences.suppressDefaultViewerPrompt },
                        set: { preferences.suppressDefaultViewerPrompt = !$0 }))
            }

            Section("Dock icon") {
                Picker("Icon", selection: $preferences.dockIcon) {
                    ForEach(DockIcon.allCases) { icon in
                        Label {
                            Text(icon.label)
                        } icon: {
                            Image(icon.previewName).resizable().frame(width: 28, height: 28)
                        }
                        .tag(icon)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Changes the Dock icon while Gloss is running. Finder and Launchpad always show the standard icon.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ThemePicker: View {
    let title: String
    let appearance: String
    @Binding var selection: String
    private let library = BundleLibrary.shared

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(library.themes(for: appearance)) { Text($0.manifest.name).tag($0.id) }
            if library.bundle(selection)?.supports(appearance) != true {
                Text("Not installed").tag(selection)
            }
        }
    }
}

private struct BundleSettings: View {
    @Bindable private var preferences = Preferences.shared
    private let library = BundleLibrary.shared
    @State private var error: String?

    var body: some View {
        Form {
            Section("Add-ons") {
                if library.addOns.isEmpty {
                    Text("No add-ons installed.").foregroundStyle(.secondary)
                }
                ForEach(library.addOns) { addOn in
                    Toggle(
                        isOn: Binding(
                            get: { !preferences.disabledAddOns.contains(addOn.id) },
                            set: { on in
                                if on {
                                    preferences.disabledAddOns.remove(addOn.id)
                                } else {
                                    preferences.disabledAddOns.insert(addOn.id)
                                }
                            })
                    ) {
                        BundleLabel(bundle: addOn)
                    }
                }
            }

            Section("Installed") {
                ForEach(library.bundles) { bundle in
                    HStack {
                        BundleLabel(bundle: bundle)
                        Spacer()
                        if bundle.isBuiltIn {
                            Text("Built in").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Button("Remove") { remove(bundle) }
                        }
                    }
                }
                ForEach(library.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button("Install Bundle…") { BundleInstaller.choose() }
                    Button("Reveal Bundles Folder") {
                        try? FileManager.default.createDirectory(
                            at: library.userDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([library.userDirectory])
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func remove(_ bundle: InstalledBundle) {
        do {
            try library.remove(bundle)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct BundleLabel: View {
    let bundle: InstalledBundle

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bundle.manifest.name)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        var parts = [bundle.manifest.kind == .theme ? "Theme" : "Add-on", "version \(bundle.manifest.version)"]
        if let author = bundle.manifest.author, !author.isEmpty { parts.append("by \(author)") }
        if bundle.hasScripts { parts.append("contains scripts") }
        return parts.joined(separator: " · ")
    }
}

/// Installing a bundle always shows what it is, and whether it runs scripts,
/// before anything is copied.
@MainActor
enum BundleInstaller {
    static func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.glossBundle]
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a .glossbundle to install."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        install(url)
    }

    static func install(_ url: URL) {
        let manifest: BundleManifest
        do {
            manifest = try BundleLibrary.validate(url)
        } catch {
            show(title: "This bundle can't be installed.", text: error.localizedDescription)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Install “\(manifest.name)”?"
        var lines = ["\(manifest.kind == .theme ? "Theme" : "Add-on"), version \(manifest.version)"]
        if let author = manifest.author, !author.isEmpty { lines[0] += ", by \(author)" }
        if !(manifest.scripts ?? []).isEmpty {
            lines.append(
                "This bundle contains scripts. They run on every page you open and can read its text. They cannot use the network or change files."
            )
        }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try BundleLibrary.shared.install(from: url)
        } catch {
            show(title: "This bundle can't be installed.", text: error.localizedDescription)
        }
    }

    private static func show(title: String, text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
