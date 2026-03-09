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

        fatalError("could not find resource bundle \(bundleName)")
    }()
}
