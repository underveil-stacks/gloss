import Foundation
import GlossCore

/// Whatever goes in, the sanitizer must not crash, must give the same answer
/// when run on its own output, and must never let these elements through.
private let forbidden = [
    "<script", "<style", "<iframe", "<object", "<embed", "<link", "<meta", "<base", "<form", "<svg", "<math",
]

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ start: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let input = String(decoding: UnsafeBufferPointer(start: start, count: count), as: UTF8.self)
    let once = HTMLSanitizer.sanitize(input)
    let twice = HTMLSanitizer.sanitize(once)
    precondition(once == twice, "sanitize is not idempotent")
    let lowered = once.lowercased()
    for tag in forbidden {
        precondition(!lowered.contains(tag), "\(tag) survived sanitizing")
    }
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
@_cdecl("SanitizerFuzz_main")
public func entryPoint(_ argc: CInt, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> CInt {
    var argc = argc
    var argv = argv
    return runFuzzer(&argc, &argv, fuzz)
}
