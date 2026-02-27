import Foundation

/// Debug-only logging. Compiled out entirely in release builds.
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
