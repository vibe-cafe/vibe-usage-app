import Foundation

// Xcode 27.2's SDK makes Date's <= and >= call Foundation's own copies on
// macOS 27.2+ (@backDeployed(before: macOS 27.2), swift-foundation#2230).
// Early macOS 27.2 betas (26B5086k, 26B5091g) report 27.2 without exporting
// them, so the weakly linked call jumps to address 0 — 0.7.9 crashed there
// when the panel opened. Declaring them in this module shadows Foundation's;
// they use only < and >, which every supported macOS has, exactly like
// Comparable's default implementation. See AGENTS.md, Known Constraints.
extension Date {
    static func <= (lhs: Date, rhs: Date) -> Bool { !(lhs > rhs) }
    static func >= (lhs: Date, rhs: Date) -> Bool { !(lhs < rhs) }
}
