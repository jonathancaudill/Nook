//
//  DebugPrint.swift
//  Nook
//
//  Silences all print() calls in Release builds.
//  In Debug builds, print() works normally via the standard library.
//

#if !DEBUG
@inline(__always)
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    // No-op in release builds
}
#endif
