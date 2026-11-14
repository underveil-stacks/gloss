import CoreServices
import Foundation
import OSLog

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "gloss", category: "bundles")

/// `manifest.json` of a `.glossbundle`. See docs/bundles.md.
struct BundleManifest: Decodable, Equatable, Sendable {
    static let contractVersion = 1

    enum Kind: String, Decodable, Sendable {
        case theme
        case addOn = "add-on"
    }

    let contract: Int
    let id: String
    let name: String
    let author: String?
    let version: String
    let kind: Kind
    let appearances: [String]?
    let styles: [String]?
    let scripts: [String]?
    let printStyles: [String]?
    /// The bundle's scripts write styles into the page (diagram and math
    /// libraries do), so the page's policy must allow inline styles.
    let inlineStyles: Bool?
    /// Limits an add-on to the documents that need it. Without it, the
    /// add-on is loaded on every page.
    let when: Condition?

    struct Condition: Decodable, Equatable, Sendable {
        /// Fenced code block languages that call for the add-on.
        let languages: [String]?
        /// Pieces of text that call for the add-on when the source has one.
        let text: [String]?
    }

    func applies(languages: Set<String>, source: String) -> Bool {
        guard let when else { return true }
        if let wanted = when.languages, wanted.contains(where: { languages.contains($0.lowercased()) }) { return true }
        if let text = when.text, text.contains(where: { source.contains($0) }) { return true }
        return false
    }
}

struct InstalledBundle: Identifiable, Equatable, Sendable {
    let manifest: BundleManifest
    let directory: URL
    let isBuiltIn: Bool

    var id: String { manifest.id }
    var hasScripts: Bool { !(manifest.scripts ?? []).isEmpty }
    func supports(_ appearance: String) -> Bool { manifest.appearances?.contains(appearance) ?? false }
}

enum BundleError: LocalizedError, Equatable {
    case notABundle
    case unreadableManifest(String)
    case newerContract(Int)
    case invalid(String)
    case shadowsBuiltIn(String)

    var errorDescription: String? {
        switch self {
        case .notABundle: "This is not a Gloss bundle. A bundle is a folder ending in .glossbundle with a manifest.json inside."
        case .unreadableManifest(let why): "The bundle's manifest.json could not be read: \(why)"
        case .newerContract(let version):
            "This bundle was written for a newer version of Gloss (bundle contract \(version)). Update Gloss to use it."
        case .invalid(let why): "The bundle is not valid: \(why)"
        case .shadowsBuiltIn(let id): "A bundle cannot use the identifier of a built-in bundle (\(id))."
        }
    }
}

/// The installed themes and add-ons: the built-in ones inside the app, and
/// the reader's own in Application Support.
@MainActor
@Observable
final class BundleLibrary {
    static let shared = BundleLibrary()
    nonisolated static let directoryExtension = "glossbundle"

    private(set) var bundles: [InstalledBundle] = []
    /// Bundles in the user folder that were refused, with the reason.
    private(set) var problems: [String] = []

    let builtInDirectory: URL?
    let userDirectory: URL
    private var watcher: DirectoryWatcher?

    init(
        builtInDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Bundles"),
        userDirectory: URL? = nil
    ) {
        self.builtInDirectory = builtInDirectory
        self.userDirectory =
            userDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gloss/Bundles", isDirectory: true)
        reload()
    }

    var themes: [InstalledBundle] { bundles.filter { $0.manifest.kind == .theme } }
    var addOns: [InstalledBundle] { bundles.filter { $0.manifest.kind == .addOn } }
    func themes(for appearance: String) -> [InstalledBundle] { themes.filter { $0.supports(appearance) } }
    func bundle(_ id: String) -> InstalledBundle? { bundles.first { $0.id == id } }

    /// Re-renders open pages when a bundle is added, removed or edited.
    func startWatching() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(directory: userDirectory) { [weak self] in
            Task { @MainActor in
                self?.reload()
                NotificationCenter.default.post(name: .glossLookChanged, object: nil)
            }
        }
    }

    func reload() {
        var found: [InstalledBundle] = []
        var problems: [String] = []
        for (directory, builtIn) in [(builtInDirectory, true), (userDirectory, false)] {
            guard let directory,
                let entries = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where entry.pathExtension == Self.directoryExtension {
                do {
                    let manifest = try Self.validate(entry)
                    if found.contains(where: { $0.id == manifest.id }) {
                        throw builtIn
                            ? BundleError.invalid("duplicate identifier \(manifest.id)")
                            : BundleError.shadowsBuiltIn(manifest.id)
                    }
                    found.append(InstalledBundle(manifest: manifest, directory: entry, isBuiltIn: builtIn))
                } catch {
                    problems.append("\(entry.lastPathComponent): \(error.localizedDescription)")
                    log.error("refused bundle \(entry.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        bundles = found
        self.problems = problems
    }

    /// Checks a bundle folder against the contract and returns its manifest.
    nonisolated static func validate(_ directory: URL) throws -> BundleManifest {
        var isDirectory: ObjCBool = false
        guard directory.pathExtension == directoryExtension,
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw BundleError.notABundle }

        let manifest: BundleManifest
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            manifest = try JSONDecoder().decode(BundleManifest.self, from: data)
        } catch let error as DecodingError {
            throw BundleError.unreadableManifest(describe(error))
        } catch {
            throw BundleError.unreadableManifest(error.localizedDescription)
        }

        guard manifest.contract >= 1 else { throw BundleError.invalid("contract must be 1 or higher") }
        guard manifest.contract <= BundleManifest.contractVersion else {
            throw BundleError.newerContract(manifest.contract)
        }
        guard manifest.id.wholeMatch(of: /[A-Za-z0-9]+([.\-][A-Za-z0-9]+)*/) != nil else {
            throw BundleError.invalid("id may contain only letters, digits, dots and hyphens")
        }
        guard !manifest.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BundleError.invalid("name is empty")
        }
        if manifest.kind == .theme {
            let appearances = manifest.appearances ?? []
            guard !appearances.isEmpty, appearances.allSatisfy({ $0 == "light" || $0 == "dark" }) else {
                throw BundleError.invalid("a theme must list its appearances: light, dark or both")
            }
        }

        let root = directory.resolvingSymlinksInPath().path + "/"
        for path in (manifest.styles ?? []) + (manifest.scripts ?? []) + (manifest.printStyles ?? []) {
            let file = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard !path.hasPrefix("/"), file.path.hasPrefix(root) else {
                throw BundleError.invalid("\(path) is outside the bundle")
            }
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw BundleError.invalid("\(path) is listed in the manifest but missing")
            }
        }
        return manifest
    }

    private nonisolated static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): "missing \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            "wrong type for \"\(context.codingPath.map(\.stringValue).joined(separator: "."))\""
        case .dataCorrupted(let context):
            context.codingPath.isEmpty
                ? "not valid JSON"
                : "bad value for \"\(context.codingPath.map(\.stringValue).joined(separator: "."))\""
        @unknown default: "not readable"
        }
    }

    /// Copies a bundle into the user folder. Replaces an earlier copy with the
    /// same identifier; refuses one that would shadow a built-in.
    @discardableResult
    func install(from source: URL) throws -> InstalledBundle {
        let manifest = try Self.validate(source)
        if let existing = bundle(manifest.id), existing.isBuiltIn {
            throw BundleError.shadowsBuiltIn(manifest.id)
        }
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        if let existing = bundle(manifest.id), existing.directory.standardizedFileURL != source.standardizedFileURL {
            try FileManager.default.trashItem(at: existing.directory, resultingItemURL: nil)
        }
        let destination = userDirectory.appendingPathComponent("\(manifest.id).\(Self.directoryExtension)")
        if destination.standardizedFileURL != source.standardizedFileURL {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        reload()
        NotificationCenter.default.post(name: .glossLookChanged, object: nil)
        guard let installed = bundle(manifest.id) else { throw BundleError.invalid("the bundle did not install") }
        return installed
    }

    /// Moves a user bundle to the Trash. Built-in bundles cannot be removed.
    func remove(_ bundle: InstalledBundle) throws {
        guard !bundle.isBuiltIn else { return }
        try FileManager.default.trashItem(at: bundle.directory, resultingItemURL: nil)
        reload()
        NotificationCenter.default.post(name: .glossLookChanged, object: nil)
    }
}

/// Calls back, a moment after the last change, when anything under a
/// directory changes.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void

    init?(directory: URL, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, [directory.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
