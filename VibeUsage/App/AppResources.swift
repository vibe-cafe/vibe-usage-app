import Foundation

extension Bundle {
    static let appResources: Bundle = {
        let bundleName = "VibeUsage_VibeUsage"

        if let url = Bundle.main.resourceURL?.appendingPathComponent("\(bundleName).bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }

        if let bundle = Bundle(path: Bundle.main.bundleURL.appendingPathComponent("\(bundleName).bundle").path) {
            return bundle
        }

        // `swift test`: the code lives in the test bundle, whose folder also
        // holds the resource bundle (SwiftPM's own `Bundle.module` lookup).
        let codeFolder = Bundle(for: ResourceBundleToken.self).bundleURL.deletingLastPathComponent()
        if let bundle = Bundle(url: codeFolder.appendingPathComponent("\(bundleName).bundle")) {
            return bundle
        }

        fatalError("could not find resource bundle \(bundleName)")
    }()
}

private final class ResourceBundleToken {}
