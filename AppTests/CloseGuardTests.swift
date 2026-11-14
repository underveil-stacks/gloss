import AppKit
import Testing

@testable import Gloss

/// The close guard against a real window. Whether SwiftUI's own document
/// window still routes a close through the delegate cannot be tested here (a
/// test cannot host a document group); `docs/notes.md` lists it as a release
/// check.
@MainActor
@Suite struct CloseGuardTests {
    private final class Original: NSObject, NSWindowDelegate {
        var resized = 0
        var allowsClose = true
        func windowDidResize(_ notification: Notification) { resized += 1 }
        func windowShouldClose(_ sender: NSWindow) -> Bool { allowsClose }
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func standsInFrontAndForwardsEverythingElse() {
        let window = window()
        let original = Original()
        window.delegate = original
        let closeGuard = CloseGuard(model: PageModel())
        closeGuard.attach(to: window)

        #expect(window.delegate === closeGuard)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        #expect(original.resized == 1, "a delegate message was not forwarded")
        // No fields: the original delegate decides.
        original.allowsClose = false
        #expect(closeGuard.windowShouldClose(window) == false)
        original.allowsClose = true
        #expect(closeGuard.windowShouldClose(window) == true)
    }

    @Test func holdsACloseWhileThePageHasFields() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let model = PageModel()
        await model.show(text: "| a | b |\n|---|---|\n| x |  |\n", fileURL: base.appendingPathComponent("f.md"), appearance: "dark")
        try #require(model.formFieldCount == 1)

        let window = window()
        let closeGuard = CloseGuard(model: model)
        closeGuard.attach(to: window)
        #expect(closeGuard.windowShouldClose(window) == false, "a window with fields closed without asking the page")
    }

    @Test func givesThePageItsOwnUndoManager() {
        let window = window()
        let closeGuard = CloseGuard(model: PageModel())
        closeGuard.attach(to: window)
        #expect(window.undoManager != nil)
        #expect(window.undoManager === closeGuard.windowWillReturnUndoManager(window))
    }

    @Test func comesBackWhenItsPlaceIsTaken() {
        let window = window()
        let closeGuard = CloseGuard(model: PageModel())
        closeGuard.attach(to: window)
        let usurper = Original()
        window.delegate = usurper
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(window.delegate === closeGuard, "the guard did not put itself back")
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        #expect(usurper.resized == 1, "the new delegate is not forwarded to")
    }
}
