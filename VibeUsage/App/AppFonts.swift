import CoreText
import Foundation

/// The two typefaces of the new panel (design §4): Schibsted Grotesk for text
/// and JetBrains Mono for numbers, only the weights the design uses. They ship
/// in the resource bundle (`Resources/Fonts`, SIL OFL 1.1, see
/// `ThirdPartyNotices.txt`) and are registered for this process only, so
/// nothing is installed on the user's Mac. Neither has CJK glyphs; Chinese
/// falls back to the system's PingFang SC.
///
/// The app registers them at launch; tests and the off-screen renderer call
/// `register(from:)` with the bundle they found.
enum AppFonts {
    /// File names in the resource bundle, which are also the PostScript names.
    static let fileNames = [
        "SchibstedGrotesk-Regular", "SchibstedGrotesk-Medium", "SchibstedGrotesk-SemiBold",
        "JetBrainsMono-Light", "JetBrainsMono-Regular", "JetBrainsMono-Medium",
    ]

    /// Registers every bundled font found in `bundle`. Returns the names that
    /// are usable afterwards; registering again is harmless.
    @discardableResult
    static func register(from bundle: Bundle) -> [String] {
        fileNames.filter { name in
            guard let url = bundle.url(forResource: name, withExtension: "ttf") else { return false }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
            let code = (error?.takeRetainedValue()).map(CFErrorGetCode)
            return code == CTFontManagerError.alreadyRegistered.rawValue
        }
    }

    /// The app's own launch path: the SwiftPM resource bundle inside the app.
    static func registerAppFonts() {
        let registered = register(from: .appResources)
        if registered.count != fileNames.count {
            debugLog("[fonts] registered \(registered.count) of \(fileNames.count) bundled fonts")
        }
    }
}
