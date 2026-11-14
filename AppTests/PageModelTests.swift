import Foundation
import GlossCore
import Testing
import WebKit

@testable import Gloss

/// The whole pipeline in a real web page: Markdown in, a themed, highlighted
/// page out, and re-renders that keep the reader's place.
@MainActor
@Suite struct PageModelTests {
    private struct Fixture {
        let base: URL
        let preferences: Preferences
        let library: BundleLibrary
        let model: PageModel

        var document: URL { base.appendingPathComponent("doc/note.md") }

        func eval(_ script: String) async throws -> String {
            let value = try await model.page.callJavaScript(script)
            return (value as? String) ?? String(describing: value ?? "nil")
        }
    }

    private func theme(_ id: String, appearances: String, css: String, in directory: URL, extra: String = "") throws {
        let bundle = directory.appendingPathComponent("\(id).glossbundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(
            """
            {"contract":1,"id":"\(id)","name":"\(id)","version":"1","kind":"theme",
             "appearances":[\(appearances)],"styles":["theme.css"]\(extra)}
            """.utf8
        ).write(to: bundle.appendingPathComponent("manifest.json"))
        try Data(css.utf8).write(to: bundle.appendingPathComponent("theme.css"))
    }

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-model-\(UUID().uuidString)").resolvingSymlinksInPath()
        let builtIn = base.appendingPathComponent("builtin")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("doc"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("user"), withIntermediateDirectories: true)
        try theme(Preferences.defaultDarkTheme, appearances: "\"dark\"", css: "body { background: rgb(10, 20, 30) }", in: builtIn)
        try theme(Preferences.defaultLightTheme, appearances: "\"light\"", css: "body { background: rgb(250, 250, 250) }", in: builtIn)
        try theme("test.both", appearances: "\"light\",\"dark\"", css: "body { background: rgb(7, 7, 7) }", in: builtIn)

        let suite = "gloss-tests-\(UUID().uuidString)"
        let preferences = Preferences(defaults: UserDefaults(suiteName: suite)!)
        let library = BundleLibrary(builtInDirectory: builtIn, userDirectory: base.appendingPathComponent("user"))
        return Fixture(
            base: base, preferences: preferences, library: library,
            model: PageModel(preferences: preferences, library: library))
    }

    @Test func rendersAThemedHighlightedPage() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = """
            ---
            title: Demo
            ---
            # Hello, World

            > [!TIP]
            > Read this.

            ```swift
            let answer = 42
            ```
            """
        await fixture.model.show(text: source, fileURL: fixture.document, appearance: "dark")

        #expect(!fixture.model.isLoading)
        #expect(fixture.model.themeID == Preferences.defaultDarkTheme)
        #expect(fixture.model.headings.map(\.id) == ["hello-world"])
        #expect(try await fixture.eval("return document.documentElement.dataset.appearance") == "dark")
        #expect(try await fixture.eval("return getComputedStyle(document.body).backgroundColor") == "rgb(10, 20, 30)")
        #expect(try await fixture.eval("return String(!!document.getElementById('hello-world'))") == "true")
        #expect(try await fixture.eval("return document.querySelector('.markdown-alert-tip .markdown-alert-title').textContent") == "Tip")
        #expect(try await fixture.eval("return document.querySelector('header.gloss-frontmatter dd').textContent") == "Demo")
        #expect(try await fixture.eval("return String(document.querySelectorAll('code.hljs .hljs-keyword').length > 0)") == "true")
        #expect(fixture.model.snapshot.text.contains("Read this."))
    }

    @Test func followsAppearanceAndTheChosenTheme() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        await fixture.model.show(text: "# a", fileURL: fixture.document, appearance: "light")
        #expect(fixture.model.themeID == Preferences.defaultLightTheme)
        #expect(try await fixture.eval("return getComputedStyle(document.body).backgroundColor") == "rgb(250, 250, 250)")

        fixture.preferences.lightThemeID = "test.both"
        await fixture.model.refresh()
        #expect(fixture.model.themeID == "test.both")
        #expect(try await fixture.eval("return getComputedStyle(document.body).backgroundColor") == "rgb(7, 7, 7)")

        // A theme that is not installed, or does not support the appearance,
        // falls back to the built-in default instead of an unstyled page.
        fixture.preferences.darkThemeID = "not.installed"
        await fixture.model.show(text: "# a", fileURL: fixture.document, appearance: "dark")
        #expect(fixture.model.themeID == Preferences.defaultDarkTheme)
    }

    @Test func reRenderKeepsTheReadersPlaceAndTellsScripts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let paragraphs = (1...200).map { "Paragraph number \($0).\n" }.joined(separator: "\n")
        await fixture.model.show(text: paragraphs, fileURL: fixture.document, appearance: "dark")

        let height = try await fixture.eval("return String(window.innerHeight)")
        try #require(Int(height) ?? 0 > 0, "the page has no viewport to scroll")
        _ = try await fixture.eval(
            """
            window.renders = 0;
            document.addEventListener('gloss:render', () => { window.renders += 1 });
            document.querySelector('[data-sourcepos^="241:"]').scrollIntoView({ block: 'start' });
            window.scrollBy(0, 7);
            return '';
            """)
        let before = try await fixture.eval("return JSON.stringify(gloss.anchor())")
        try #require(before.contains("\"line\":241"))

        // Insert lines above the reader's place. The same paragraph must stay put.
        await fixture.model.show(
            text: "Inserted one.\n\nInserted two.\n\n" + paragraphs, fileURL: fixture.document, appearance: "dark")
        let after = try await fixture.eval(
            """
            const a = gloss.anchor();
            const el = document.querySelector('[data-sourcepos^="' + a.line + ':"]');
            return JSON.stringify({ text: el.textContent, offset: Math.round(a.offset), renders: window.renders });
            """)
        #expect(after.contains("\"renders\":1"), "the page was reloaded instead of updated in place: \(after)")
        #expect(after.contains("\"offset\":-7"), "the reader's position moved: \(after)")
        #expect(after.contains("Inserted") == false)
    }

    private static let form = """
        # Review

        | Item | Answer |
        |---|---|
        | Ship it? |  |
        | Owner | ___ |
        | Notes | done already |

        Due date: ___ please, or ___ at the latest.

        - [ ] Read the spec
        - [x] Ran the tests

        ## Choices

        <label><input type="radio" name="size" value="s"> Small</label>
        <label><input type="radio" name="size" value="l" checked> Large</label>

        <select name="colour"><option>red</option><option>blue</option></select>

        <textarea name="comments"></textarea>
        """

    private func type(_ fixture: Fixture, _ script: String) async throws {
        _ = try await fixture.eval(script + "; return ''")
    }

    @Test func formFieldsAreMadeAndExported() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        await fixture.model.show(text: Self.form, fileURL: fixture.document, appearance: "dark")

        // Two blank cells, two inline blanks, two tasks, two radios, a select, a box.
        #expect(fixture.model.formFieldCount == 10)
        try await type(
            fixture,
            """
            const boxes = document.querySelectorAll('td textarea.gloss-blank');
            boxes[0].value = 'yes'; boxes[1].value = 'Ada';
            document.querySelector('p input.gloss-blank').value = 'Friday';
            document.querySelector('input.gloss-task').checked = true;
            document.querySelector('input[value="s"]').checked = true;
            document.querySelector('select').value = 'blue';
            document.querySelector('textarea[name="user-content-comments"]').value = 'fine'
            """)
        let fields = try await fixture.model.formFields()
        let byKey = Dictionary(fields.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byKey["Review / Ship it? / Answer"]?.value == .text("yes"))
        #expect(byKey["Review / Ship it? / Answer"]?.line == 5)
        #expect(byKey["Review / Owner / Answer"]?.value == .text("Ada"))
        #expect(byKey["Review / Due date"]?.value == .text("Friday"))
        #expect(byKey["Review / Due date: ___ please, or"]?.value == .text(""))
        #expect(byKey["Review / Read the spec"]?.value == .flag(true))
        #expect(byKey["Review / Ran the tests"]?.value == .flag(true))
        #expect(byKey["size"]?.value == .text("s"))
        #expect(byKey["size"]?.options == ["s", "l"])
        #expect(byKey["colour"]?.value == .text("blue"))
        #expect(byKey["comments"]?.value == .text("fine"))
        #expect(byKey["comments"]?.section == "Choices")

        let json = try JSONSerialization.jsonObject(with: try await fixture.model.exportForm()) as? [String: Any]
        #expect(json?["document"] as? String == "note.md")
        #expect((json?["values"] as? [String: Any])?["Review / Owner / Answer"] as? String == "Ada")
        #expect((json?["fields"] as? [Any])?.count == 9)
    }

    @Test func answersSurviveARenderAndAReload() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        await fixture.model.show(text: Self.form, fileURL: fixture.document, appearance: "dark")
        try await type(
            fixture,
            """
            document.querySelector('td textarea.gloss-blank').value = 'yes';
            document.querySelector('textarea[name="user-content-comments"]').value = 'kept'
            """)

        // The file changes above the fields: updated in place.
        await fixture.model.show(text: "Intro.\n\n" + Self.form, fileURL: fixture.document, appearance: "dark")
        // The appearance changes: the page reloads.
        await fixture.model.show(text: "Intro.\n\n" + Self.form, fileURL: fixture.document, appearance: "light")

        let fields = try await fixture.model.formFields()
        #expect(fields.first { $0.row == "Ship it?" }?.value == .text("yes"))
        #expect(fields.first { $0.name == "comments" }?.value == .text("kept"))
    }

    @Test func closingWarnsOnlyAboutAnswersNotYetExported() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        await fixture.model.show(text: Self.form, fileURL: fixture.document, appearance: "dark")
        #expect(await !fixture.model.hasUnexportedAnswers(), "nothing has been typed yet")

        try await type(fixture, "document.querySelector('td textarea.gloss-blank').value = 'yes'")
        #expect(await fixture.model.hasUnexportedAnswers())

        _ = try await fixture.model.exportForm()
        #expect(await !fixture.model.hasUnexportedAnswers(), "the answers were just exported")

        try await type(fixture, "document.querySelector('td textarea.gloss-blank').value = 'no'")
        #expect(await fixture.model.hasUnexportedAnswers(), "the answers changed after the export")
    }

    /// The template in the authoring guide gives the export the guide says it does.
    @Test func theAuthoringGuidesTemplateExportsAsDocumented() async throws {
        let guide = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../skills/gloss/AUTHORING.md").standardizedFileURL,
            encoding: .utf8)
        let start = try #require(guide.range(of: "```markdown\n"))
        let end = try #require(guide.range(of: "\n```", range: start.upperBound..<guide.endIndex))
        let template = String(guide[start.upperBound..<end.lowerBound])

        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        await fixture.model.show(text: template, fileURL: fixture.document, appearance: "dark")
        try await type(
            fixture,
            """
            document.querySelector('td textarea.gloss-blank').value = 'yes';
            document.querySelector('input.gloss-task').checked = true;
            document.querySelector('input[value="low"]').checked = true;
            const blanks = document.querySelectorAll('p input.gloss-blank');
            blanks[0].value = 'Ada'; blanks[1].value = '2026-11-14'
            """)
        let json = try JSONSerialization.jsonObject(with: try await fixture.model.exportForm()) as? [String: Any]
        let values = try #require(json?["values"] as? [String: Any])
        #expect(values["Release review: 4.2 / Ship on Friday? / Answer"] as? String == "yes")
        #expect(values["Checks / Changelog read"] as? Bool == true)
        #expect(values["risk"] as? String == "low")
        #expect(values["Risk / Signed off by"] as? String == "Ada")
        #expect(values["Risk / Signed off by ___ on"] as? String == "2026-11-14")
        let fields = try await fixture.model.formFields()
        #expect(fields.first { $0.row == "Ship on Friday?" }?.line == 5)
        #expect(fields.first { $0.label == "Changelog read" }?.line == 11)
        #expect(fields.first { $0.name == "risk" }?.line == 16)
        #expect(fields.first { $0.name == "risk" }?.options == ["low", "medium", "high"])
    }

    @Test func aDocumentWithoutFieldsHasNone() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        await fixture.model.show(
            text: "| a | b |\n|---|---|\n| 1 | 2 |\n\n`___` and\n\n```\n___\n```\n", fileURL: fixture.document,
            appearance: "dark")
        #expect(fixture.model.formFieldCount == 0)
        #expect(await !fixture.model.hasUnexportedAnswers())
    }

    @Test func remoteImagesStayBlockedUntilAsked() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        await fixture.model.show(
            text: "![x](https://example.com/x.png)", fileURL: fixture.document, appearance: "dark")
        #expect(fixture.model.hasRemoteImages)

        let probe = """
            return await new Promise(resolve => {
              document.addEventListener('securitypolicyviolation', e => resolve('blocked'), { once: true });
              const image = new Image();
              image.src = 'https://example.com/y.png';
              document.body.append(image);
              setTimeout(() => resolve('allowed'), 1500);
            });
            """
        #expect(try await fixture.eval(probe) == "blocked")
        await fixture.model.loadRemoteImages()
        #expect(try await fixture.eval(probe) == "allowed")
    }

    @Test func zoomIsApplied() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        fixture.preferences.zoom = 1.5
        await fixture.model.show(text: "# a", fileURL: fixture.document, appearance: "dark")
        #expect(try await fixture.eval("return document.documentElement.style.zoom") == "1.5")
    }

    @Test func findSelectsMatches() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        await fixture.model.show(text: "alpha beta\n\ngamma beta", fileURL: fixture.document, appearance: "dark")
        await fixture.model.find("beta")
        #expect(!fixture.model.findFailed)
        #expect(try await fixture.eval("return String(window.getSelection())") == "beta")
        await fixture.model.find("nowhere")
        #expect(fixture.model.findFailed)
    }

    @Test func printsAsAPaginatedPDF() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let paragraphs = (1...400).map { "Paragraph number \($0).\n" }.joined(separator: "\n")
        await fixture.model.show(text: paragraphs, fileURL: fixture.document, appearance: "dark")
        let output = fixture.base.appendingPathComponent("out.pdf")
        #expect(await PrintController.writePDF(fixture.model, to: output))
        let pdf = try #require(CGPDFDocument(output as CFURL))
        #expect(pdf.numberOfPages > 3, "expected several pages, got \(pdf.numberOfPages)")
    }
}

@MainActor
@Suite struct BundleLibraryTests {
    private func makeBundle(_ name: String, manifest: String, files: [String: String] = [:], in directory: URL) throws -> URL {
        let bundle = directory.appendingPathComponent("\(name).glossbundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: bundle.appendingPathComponent("manifest.json"))
        for (path, content) in files {
            try Data(content.utf8).write(to: bundle.appendingPathComponent(path))
        }
        return bundle
    }

    private func base() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-bundles-\(UUID().uuidString)").resolvingSymlinksInPath()
        for name in ["builtin", "user", "src"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        return base
    }

    private let good = """
        {"contract":1,"id":"com.example.aurora","name":"Aurora","version":"1.0.0","kind":"theme",
         "appearances":["dark"],"styles":["theme.css"]}
        """

    @Test func refusesBundlesThatBreakTheContract() throws {
        let base = try base()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src")
        let cases: [(String, String, [String: String])] = [
            ("newer", good.replacingOccurrences(of: "\"contract\":1", with: "\"contract\":2"), ["theme.css": ""]),
            ("badid", good.replacingOccurrences(of: "com.example.aurora", with: "../evil"), ["theme.css": ""]),
            ("missing", good, [:]),
            ("escape", good.replacingOccurrences(of: "theme.css", with: "../outside.css"), [:]),
            ("absolute", good.replacingOccurrences(of: "theme.css", with: "/etc/hosts"), [:]),
            ("noappearance", good.replacingOccurrences(of: "\"appearances\":[\"dark\"],", with: ""), ["theme.css": ""]),
            ("badkind", good.replacingOccurrences(of: "\"theme\"", with: "\"plugin\""), ["theme.css": ""]),
            ("notjson", "{", [:]),
        ]
        try Data("x".utf8).write(to: src.appendingPathComponent("outside.css"))
        for (name, manifest, files) in cases {
            let bundle = try makeBundle(name, manifest: manifest, files: files, in: src)
            #expect(throws: BundleError.self, "\(name) was accepted") { try BundleLibrary.validate(bundle) }
        }
        let ok = try makeBundle("ok", manifest: good, files: ["theme.css": ""], in: src)
        #expect(try BundleLibrary.validate(ok).id == "com.example.aurora")
        #expect(throws: BundleError.notABundle) { try BundleLibrary.validate(src.appendingPathComponent("outside.css")) }
    }

    @Test func installsRemovesAndProtectsBuiltIns() throws {
        let base = try base()
        defer { try? FileManager.default.removeItem(at: base) }
        let builtIn = base.appendingPathComponent("builtin")
        _ = try makeBundle(
            "core", manifest: good.replacingOccurrences(of: "com.example.aurora", with: "builtin.theme"),
            files: ["theme.css": ""], in: builtIn)
        let library = BundleLibrary(builtInDirectory: builtIn, userDirectory: base.appendingPathComponent("user"))
        #expect(library.bundles.map(\.id) == ["builtin.theme"])

        let source = try makeBundle("aurora", manifest: good, files: ["theme.css": "a"], in: base.appendingPathComponent("src"))
        let installed = try library.install(from: source)
        #expect(!installed.isBuiltIn)
        #expect(library.themes(for: "dark").map(\.id) == ["builtin.theme", "com.example.aurora"])
        #expect(library.themes(for: "light").isEmpty)
        // The source is copied, not moved.
        #expect(FileManager.default.fileExists(atPath: source.path))

        // Installing again replaces the earlier copy rather than duplicating it.
        try Data("b".utf8).write(to: source.appendingPathComponent("theme.css"))
        try library.install(from: source)
        #expect(library.bundles.count == 2)
        #expect(try String(contentsOf: library.bundle("com.example.aurora")!.directory.appendingPathComponent("theme.css"), encoding: .utf8) == "b")

        // A user bundle cannot take a built-in's identifier, by install or by hand.
        let shadow = try makeBundle(
            "shadow", manifest: good.replacingOccurrences(of: "com.example.aurora", with: "builtin.theme"),
            files: ["theme.css": ""], in: base.appendingPathComponent("src"))
        #expect(throws: BundleError.shadowsBuiltIn("builtin.theme")) { try library.install(from: shadow) }
        try FileManager.default.copyItem(at: shadow, to: library.userDirectory.appendingPathComponent("shadow.glossbundle"))
        library.reload()
        #expect(library.bundle("builtin.theme")?.isBuiltIn == true)
        #expect(library.problems.count == 1)

        try library.remove(try #require(library.bundle("com.example.aurora")))
        #expect(library.bundle("com.example.aurora") == nil)
        try library.remove(try #require(library.bundle("builtin.theme")))
        #expect(library.bundle("builtin.theme") != nil, "a built-in bundle was removed")
    }
}

@MainActor
@Suite struct PreferencesTests {
    @Test func zoomMovesThroughStepsAndStopsAtTheEnds() {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "gloss-tests-\(UUID().uuidString)")!)
        #expect(preferences.zoom == 1)
        preferences.zoomIn()
        #expect(preferences.zoom == 1.1)
        preferences.resetZoom()
        preferences.zoomOut()
        #expect(preferences.zoom == 0.9)
        for _ in 0..<40 { preferences.zoomIn() }
        #expect(preferences.zoom == 3)
        for _ in 0..<40 { preferences.zoomOut() }
        #expect(preferences.zoom == 0.5)
    }
}

/// The built-in add-ons, running in a real page under the real policy.
@MainActor
@Suite struct AddOnTests {
    private func model() throws -> (PageModel, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-addons-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let preferences = Preferences(defaults: UserDefaults(suiteName: "gloss-tests-\(UUID().uuidString)")!)
        let library = BundleLibrary(userDirectory: base.appendingPathComponent("user"))
        return (PageModel(preferences: preferences, library: library), base)
    }

    private func wait(_ model: PageModel, for script: String) async throws -> String {
        for _ in 0..<60 {
            let value = try await model.page.callJavaScript(script) as? String ?? ""
            if !value.isEmpty { return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        return ""
    }

    @Test func builtInBundlesAreValid() {
        let library = BundleLibrary(userDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(library.problems.isEmpty, "\(library.problems)")
        #expect(library.addOns.map(\.id).sorted() == ["io.sigler.webby.gloss.math", "io.sigler.webby.gloss.mermaid"])
        #expect(library.bundle(Preferences.defaultDarkTheme)?.supports("dark") == true)
    }

    @Test func mermaidBlocksBecomeDiagrams() async throws {
        let (model, base) = try model()
        defer { try? FileManager.default.removeItem(at: base) }
        await model.show(
            text: "# d\n\n```mermaid\ngraph TD\n  A[Start] --> B[End]\n```\n", fileURL: base.appendingPathComponent("d.md"),
            appearance: "dark")
        let result = try await wait(
            model,
            for: """
                const figure = document.querySelector('.gloss-mermaid');
                if (!figure) return '';
                return figure.classList.contains('gloss-mermaid-error') ? figure.textContent : (figure.querySelector('svg') ? 'svg:' + figure.textContent.replace(/\\s+/g, ' ') : '');
                """)
        #expect(result.hasPrefix("svg:"), "\(result)")
        #expect(result.contains("Start") && result.contains("End"))
    }

    @Test func mathIsRendered() async throws {
        let (model, base) = try model()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = "Display:\n\n$$ e^{i\\pi} + 1 = 0 $$\n\nInline $`x^2`$ and a price of $5 and $10.\n\n```math\n\\frac{a}{b}\n```\n"
        await model.show(text: source, fileURL: base.appendingPathComponent("m.md"), appearance: "dark")
        let count = try await wait(
            model,
            for: "const n = document.querySelectorAll('.katex').length; return n >= 3 ? String(n) : ''")
        #expect(count == "3", "expected three formulas, got \(count)")
        let text = try await model.page.callJavaScript("return document.body.innerText") as? String ?? ""
        #expect(text.contains("a price of $5 and $10"), "plain dollar amounts were treated as math")
    }

    @Test func addOnsAreLoadedOnlyWhereNeeded() async throws {
        let (model, base) = try model()
        defer { try? FileManager.default.removeItem(at: base) }
        await model.show(text: "# plain\n\ncosts $5\n", fileURL: base.appendingPathComponent("p.md"), appearance: "dark")
        let scripts = try await model.page.callJavaScript(
            "return [...document.scripts].map(s => s.src).join(' ')") as? String ?? ""
        #expect(scripts.contains("gloss://app/gloss.js"))
        #expect(!scripts.contains("mermaid") && !scripts.contains("math"), "\(scripts)")
        // With no add-on in play the page keeps the strict style policy.
        let blocked = try await model.page.callJavaScript(
            """
            return await new Promise(resolve => {
              document.addEventListener('securitypolicyviolation', e => resolve(e.violatedDirective), { once: true });
              const el = document.createElement('p');
              el.setAttribute('style', 'color: red');
              document.body.append(el);
              setTimeout(() => resolve('allowed'), 1000);
            });
            """) as? String ?? ""
        #expect(blocked.hasPrefix("style-src"), "inline styles were allowed: \(blocked)")
    }
}

@Suite struct IssueReportTests {
    @Test func linkCarriesTheVersionsAndNothingElse() throws {
        let url = IssueReport.url(appVersion: "1.2.3", build: "45", system: "27.0.1")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "github.com")
        #expect(components.path == "/underveil-stacks/gloss/issues/new")
        #expect(components.queryItems?.map(\.name) == ["body"])
        let body = try #require(components.queryItems?.first?.value)
        #expect(body.contains("Gloss 1.2.3 (45) · macOS 27.0.1"))
        #expect(body.contains("**What happened**"))
    }
}
