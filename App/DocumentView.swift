import GlossCore
import SwiftUI
import WebKit

struct DocumentView: View {
    let text: String
    let fileURL: URL?

    @State private var model = PageModel()
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    private let preferences = Preferences.shared

    private struct Inputs: Equatable {
        let text: String
        // macOS follows a moved file and hands the document its new URL.
        let fileURL: URL?
        let appearance: String
    }

    private var appearance: String { colorScheme == .dark ? "dark" : "light" }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            OutlineView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if model.fileMissing {
                    Label("This file was moved or deleted. Showing the last version.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.bar)
                        .overlay(alignment: .bottom) { Divider() }
                }
                if model.hasRemoteImages && !model.allowsRemoteImages {
                    RemoteImagesBanner(model: model)
                }
                if model.isFinding {
                    FindBar(model: model)
                }
                WebView(model.page)
            }
        }
        .toolbar {
            if model.formFieldCount > 0 {
                ToolbarItem {
                    Menu {
                        Button("Copy as JSON") { Task { await FormExporter.copy(model) } }
                        Button("Save as JSON\u{2026}") { Task { await FormExporter.save(model) } }
                        Button("Share\u{2026}") { Task { await FormExporter.share(model) } }
                    } label: {
                        Label("Export Form", systemImage: "list.clipboard")
                    }
                    .help("Export what you have filled in, as JSON")
                }
            }
        }
        .background(CloseGuardInstaller(model: model))
        .task(id: Inputs(text: text, fileURL: fileURL, appearance: appearance)) {
            await model.show(text: text, fileURL: fileURL, appearance: appearance)
        }
        .onReceive(NotificationCenter.default.publisher(for: .glossLookChanged)) { _ in
            Task { await model.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .glossZoomChanged)) { _ in
            Task { await model.applyZoom() }
        }
        .preferredColorScheme(preferredScheme)
        .focusedSceneValue(\.pageModel, model)
        .onAppear { SettingsOpener.open = { openSettings() } }
        .frame(minWidth: 480, minHeight: 360)
    }

    private var preferredScheme: ColorScheme? {
        switch preferences.appearanceMode {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The document's headings. Choosing one scrolls the page to it.
private struct OutlineView: View {
    let model: PageModel

    var body: some View {
        if model.headings.isEmpty {
            ContentUnavailableView("No Headings", systemImage: "list.bullet.indent")
        } else {
            List(model.headings, id: \.line) { heading in
                Button {
                    Task { await model.reveal(heading) }
                } label: {
                    Text(heading.text.isEmpty ? "Untitled" : heading.text)
                        .lineLimit(2)
                        .fontWeight(heading.level <= 1 ? .semibold : .regular)
                        .padding(.leading, CGFloat(max(0, heading.level - 1)) * 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }
}

/// Shown when a document refers to images on the network. Nothing is fetched
/// until the reader asks, for this document only.
private struct RemoteImagesBanner: View {
    let model: PageModel

    var body: some View {
        HStack {
            Image(systemName: "photo.badge.exclamationmark")
            Text("Remote images are blocked to protect your privacy.")
            Spacer()
            Button("Load Remote Images") { Task { await model.loadRemoteImages() } }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct FindBar: View {
    @Bindable var model: PageModel
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in document", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { Task { await model.find(query) } }
                .onChange(of: query) { model.findFailed = false }
            if model.findFailed {
                Text("Not found").foregroundStyle(.secondary)
            }
            Button {
                Task { await model.find(query, backwards: true) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("Previous match")
            Button {
                Task { await model.find(query) }
            } label: {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g")
            .help("Next match")
            Button("Done") { model.isFinding = false }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focused = true }
    }
}

/// Puts a `CloseGuard` in front of the window's delegate once the view is in
/// a window, and keeps it alive for as long as the view is.
private struct CloseGuardInstaller: NSViewRepresentable {
    let model: PageModel

    func makeNSView(context: Context) -> WindowWatcher { WindowWatcher(model: model) }
    func updateNSView(_ view: WindowWatcher, context: Context) {}

    final class WindowWatcher: NSView {
        private let closeGuard: CloseGuard

        init(model: PageModel) {
            closeGuard = CloseGuard(model: model)
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { closeGuard.attach(to: window) }
        }
    }
}
