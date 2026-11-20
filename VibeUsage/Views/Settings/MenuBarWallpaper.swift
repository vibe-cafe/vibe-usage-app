import AppKit
import ImageIO
import SwiftUI

/// The user's own desktop picture behind the 通用 page's menu-bar preview
/// (maintainer 2026-11-20: 「就这么改」). Since macOS 26 the menu bar is
/// transparent, so the preview only looks like the real one on the real
/// wallpaper.
///
/// Privacy rules, all enforced here:
/// - Never trigger a permission prompt: a picture in a protected place
///   (Desktop, Documents, Downloads, iCloud Drive and other cloud folders,
///   another app's container, a Photos library, an external volume, the rest
///   of `~/Library`) is not read at all — the preview uses the drawn fallback.
///   No screen recording, no screenshot API.
/// - Read only while the preview is on screen, decoded straight to a small
///   thumbnail of the top strip; nothing is cached to disk, logged, put in
///   diagnostics or uploaded. A failed read is silent and falls back.
enum MenuBarWallpaper {
    struct Strip {
        let image: CGImage
        /// Bright picture under the menu bar → dark menu-bar text, as macOS does.
        let prefersDarkText: Bool
    }

    // MARK: Where reading is safe

    /// Whether reading `url` can never raise a privacy prompt. Checked on the
    /// path as reported and again after resolving symbolic links.
    static func isSafeToRead(_ url: URL, home: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard isSafePath(url.standardizedFileURL.path, home: home.standardizedFileURL.path) else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return isSafePath(resolved, home: home.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    private static func isSafePath(_ rawPath: String, home rawHome: String) -> Bool {
        // The data volume's firmlinked spelling of the same place.
        let firmlink = "/System/Volumes/Data"
        let path = rawPath.hasPrefix(firmlink + "/") ? String(rawPath.dropFirst(firmlink.count)) : rawPath
        let home = rawHome.hasPrefix(firmlink + "/") ? String(rawHome.dropFirst(firmlink.count)) : rawHome
        let components = path.split(separator: "/").map(String.init)
        // A Photos library anywhere is protected by the Photos permission.
        if components.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) { return false }
        // External and network volumes have their own prompts.
        if components.first == "Volumes" { return false }

        guard let relative = relativePath(path, under: home) else {
            // Outside the home folder: system and admin desktop pictures.
            return true
        }
        let parts = relative.split(separator: "/").map(String.init)
        guard let top = parts.first else { return false }
        switch top {
        case "Desktop", "Documents", "Downloads":
            return false
        case "Library":
            // Only the folder macOS downloads its own desktop pictures into;
            // the rest of Library holds iCloud Drive, cloud-provider folders,
            // other apps' containers and Full Disk Access data.
            return parts.count > 3
                && parts[1] == "Application Support"
                && parts[2] == "com.apple.mobileAssetDesktop"
        default:
            return true
        }
    }

    private static func relativePath(_ path: String, under base: String) -> String? {
        let base = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard path == base || path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: Reading

    /// The top strip of the picture at `url`, scaled so its width covers
    /// `pixelWidth` and cropped to `aspect` (width / height) from the top.
    /// `nil` for anything unsafe, unreadable or not an image. Dynamic
    /// pictures use their primary frame only.
    static func loadStrip(
        url: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        pixelWidth: Int,
        aspect: CGFloat,
        menuBarFraction: CGFloat
    ) -> Strip? {
        guard let url, pixelWidth > 0, aspect > 0, isSafeToRead(url, home: home) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelWidth * 2,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        return strip(from: thumbnail, pixelWidth: pixelWidth, aspect: aspect, menuBarFraction: menuBarFraction)
    }

    /// Aspect-fill `image` into a `pixelWidth`-wide strip anchored at the top.
    static func strip(from image: CGImage, pixelWidth: Int, aspect: CGFloat, menuBarFraction: CGFloat) -> Strip? {
        let width = pixelWidth
        let height = max(1, Int((CGFloat(width) / aspect).rounded()))
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let drawnWidth = CGFloat(image.width) * scale
        let drawnHeight = CGFloat(image.height) * scale
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        // Core Graphics' origin is bottom-left: push the image down so its top
        // edge meets the strip's top edge, centered horizontally.
        context.draw(image, in: CGRect(
            x: (CGFloat(width) - drawnWidth) / 2,
            y: CGFloat(height) - drawnHeight,
            width: drawnWidth,
            height: drawnHeight
        ))
        guard let strip = context.makeImage() else { return nil }
        let luminance = averageLuminance(of: strip, topFraction: menuBarFraction)
        return Strip(image: strip, prefersDarkText: prefersDarkText(luminance: luminance))
    }

    /// macOS switches the transparent menu bar to dark text over a bright
    /// picture.
    static func prefersDarkText(luminance: CGFloat) -> Bool {
        luminance > 0.6
    }

    /// Mean relative luminance (0–1) of the top `topFraction` of `image`.
    static func averageLuminance(of image: CGImage, topFraction: CGFloat) -> CGFloat {
        let sampleWidth = 24, sampleHeight = 24
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8,
                bytesPerRow: sampleWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard drawn else { return 0 }
        // Memory rows run top to bottom; keep the rows under the menu bar.
        let rows = max(1, min(sampleHeight, Int((CGFloat(sampleHeight) * topFraction).rounded(.up))))
        var total: CGFloat = 0
        for row in 0..<rows {
            for column in 0..<sampleWidth {
                let i = (row * sampleWidth + column) * 4
                let r = CGFloat(pixels[i]) / 255, g = CGFloat(pixels[i + 1]) / 255, b = CGFloat(pixels[i + 2]) / 255
                total += 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        return total / CGFloat(rows * sampleWidth)
    }
}

/// Shown when the real desktop picture cannot or must not be read: a soft
/// multi-color gradient in the spirit of the macOS defaults, drawn in code —
/// no Apple or third-party wallpaper ships with the app. Dark enough for the
/// light menu-bar text.
struct MenuBarWallpaperFallback: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(settingsHex: 0x1D3B7A), Color(settingsHex: 0x4B3FA6), Color(settingsHex: 0x9A4E9B)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(settingsHex: 0xF29A6B).opacity(0.55), .clear],
                center: UnitPoint(x: 0.82, y: 1.1),
                startRadius: 0,
                endRadius: 260
            )
            RadialGradient(
                colors: [Color(settingsHex: 0x4FB3E8).opacity(0.45), .clear],
                center: UnitPoint(x: 0.12, y: -0.2),
                startRadius: 0,
                endRadius: 240
            )
        }
    }
}

/// Reports the screen of the window this view is in, and again whenever the
/// window moves to another display.
struct WindowScreenReader: NSViewRepresentable {
    let onChange: (NSScreen?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((NSScreen?) -> Void)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Selector observers are dropped automatically when the view goes.
            NotificationCenter.default.addObserver(
                self, selector: #selector(screenDidChange), name: NSWindow.didChangeScreenNotification, object: window
            )
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        @objc private func screenDidChange(_ notification: Notification) {
            report()
        }

        private func report() {
            onChange?(window?.screen)
        }
    }
}
