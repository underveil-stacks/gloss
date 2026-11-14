import SwiftUI
import UniformTypeIdentifiers
import WebKit

@main
struct GlossApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A viewing document group: there is no save path to get wrong.
        DocumentGroup(viewing: MarkdownDocument.self) { file in
            DocumentView(text: file.document.text, fileURL: file.fileURL)
        }
        .commands { GlossCommands() }
        // A reading window wants the page, not the chrome: the compact
        // toolbar is the thinnest title bar macOS offers with a toolbar in it.
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Answers typed into a form are kept nowhere else, so quitting with some
    /// not yet exported asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard PageRegistry.all.contains(where: { $0.formFieldCount > 0 }) else { return .terminateNow }
        Task { @MainActor in
            sender.reply(toApplicationShouldTerminate: await CloseGuard.confirmQuit())
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        BundleLibrary.shared.startWatching()
        Preferences.shared.applyDockIcon()
    }

    /// Double-clicking a `.glossbundle` installs it. Markdown files are left
    /// to the document group.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension == BundleLibrary.directoryExtension {
                BundleInstaller.install(url)
            } else {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        }
    }
}

extension UTType {
    static let markdown = UTType(importedAs: "net.daringfireball.markdown")
    static let glossBundle = UTType(exportedAs: "io.sigler.webby.gloss.bundle")
}

struct MarkdownDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.markdown]
    static let writableContentTypes: [UTType] = []

    let text: String

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Invalid UTF-8 is shown with replacement characters, never dropped.
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported)
    }
}

extension FocusedValues {
    @Entry var pageModel: PageModel?
}

/// Menu commands that act on the front document.
struct GlossCommands: Commands {
    @FocusedValue(\.pageModel) private var model

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Show in Finder") { model?.showInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.fileURL == nil || model?.fileMissing == true)
        }
        CommandGroup(replacing: .printItem) {
            Button("Export as PDF…") { if let model { PDFExporter.export(model) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Export Form as JSON…") { if let model { Task { await FormExporter.save(model) } } }
                .disabled((model?.formFieldCount ?? 0) == 0)
            Button("Copy Form as JSON") { if let model { Task { await FormExporter.copy(model) } } }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                .disabled((model?.formFieldCount ?? 0) == 0)
            Divider()
            Button("Print…") { if let model { PrintController.print(model) } }
                .keyboardShortcut("p")
                .disabled(model == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { model?.isFinding = true }
                .keyboardShortcut("f")
                .disabled(model == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { Preferences.shared.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { Preferences.shared.zoomOut() }
                .keyboardShortcut("-")
            Button("Actual Size") { Preferences.shared.resetZoom() }
                .keyboardShortcut("0")
            Toggle(
                "Fit Text to Window",
                isOn: Binding(
                    get: { Preferences.shared.textWidth == .window },
                    set: { Preferences.shared.textWidth = $0 ? .window : .theme }))
            Divider()
            Button("Load Remote Images") { if let model { Task { await model.loadRemoteImages() } } }
                .disabled(model?.hasRemoteImages != true || model?.allowsRemoteImages == true)
            Divider()
        }
        // There is no help book, so the stock item would only say so.
        CommandGroup(replacing: .help) {
            Button("Report an Issue…") { IssueReport.open() }
        }
    }
}
