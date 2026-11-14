import Foundation
import GlossCore

/// The whole pipeline: the C parser, the sanitizer, and the edits made to the
/// page afterwards. It must not crash or read out of bounds on any input, and
/// no script element may reach the page.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ start: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let input = String(decoding: UnsafeBufferPointer(start: start, count: count), as: UTF8.self)
    let document = MarkdownRenderer.render(input) { code, _ in
        // Stands in for the highlighter: returns escaped text, as it would.
        HTMLPage.escape(code)
    }
    precondition(!document.html.lowercased().contains("<script"), "a script element reached the page")
    _ = HTMLPage.frontMatterHTML(document)
    return 0
}

@_silgen_name("LLVMFuzzerRunDriver")
private func runFuzzer(
    _ argc: UnsafeMutablePointer<CInt>,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>,
    _ callback: @convention(c) (UnsafePointer<UInt8>, Int) -> CInt
) -> CInt

/// On Linux the package manager makes this symbol the program's entry point,
/// in place of the `main` the fuzzer library would supply, so it has to start
/// the fuzzer itself. Without this the program exits at once, having tested
/// nothing.
@_cdecl("RenderFuzz_main")
public func entryPoint(_ argc: CInt, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> CInt {
    var argc = argc
    var argv = argv
    return runFuzzer(&argc, &argv, fuzz)
}
