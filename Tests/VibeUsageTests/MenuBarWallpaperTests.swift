import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VibeUsage

/// The 通用 preview reads the user's desktop picture only where that can never
/// raise a privacy prompt, and falls back silently on anything unreadable.
struct MenuBarWallpaperTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test
    func protectedPlacesAreNeverRead() {
        let protected = [
            "/Users/someone/Desktop/beach.jpg",
            "/Users/someone/Documents/wallpapers/a.heic",
            "/Users/someone/Downloads/b.png",
            "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/c.jpg",
            "/Users/someone/Library/CloudStorage/Dropbox/d.jpg",
            "/Users/someone/Library/Containers/com.apple.wallpaper.extension.image/Data/e.heic",
            "/Users/someone/Library/Group Containers/group.x/f.jpg",
            "/Users/someone/Library/Mail/V10/g.jpg",
            "/Users/someone/Pictures/Photos Library.photoslibrary/originals/h.heic",
            "/Volumes/USB/i.jpg",
            "/System/Volumes/Data/Users/someone/Desktop/j.jpg",
            "/Users/someone/Dropbox/Wallpapers/l.jpg",
            "/Users/someone/Dropbox (Personal)/m.png",
        ]
        for path in protected {
            #expect(!MenuBarWallpaper.isSafeToRead(url(path), home: home), "\(path)")
        }
        #expect(!MenuBarWallpaper.isSafeToRead(URL(string: "https://example.com/k.jpg")!, home: home))
    }

    @Test
    func systemAndOrdinaryPlacesAreRead() {
        let allowed = [
            "/System/Library/Desktop Pictures/Sequoia.heic",
            "/Library/Desktop Pictures/Company.jpg",
            "/System/Library/CoreServices/DefaultDesktop.heic",
            "/Users/someone/Library/Application Support/com.apple.mobileAssetDesktop/Catalina Evening.heic",
            "/Users/someone/Pictures/Wallpapers/mine.jpg",
        ]
        for path in allowed {
            #expect(MenuBarWallpaper.isSafeToRead(url(path), home: home), "\(path)")
        }
    }

    @Test
    func aLinkIntoAProtectedPlaceIsNotFollowed() throws {
        let fakeHome = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let desktop = fakeHome.appendingPathComponent("Desktop", isDirectory: true)
        let pictures = fakeHome.appendingPathComponent("Pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let target = desktop.appendingPathComponent("photo.png")
        try writePNG(gray: 1, to: target)
        let link = pictures.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(!MenuBarWallpaper.isSafeToRead(link, home: fakeHome))
        #expect(MenuBarWallpaper.loadStrip(url: link, home: fakeHome, pixelWidth: 100, aspect: 4, menuBarFraction: 0.3) == nil)
    }

    @Test
    func aReadableImageInAProtectedPlaceStillFallsBack() throws {
        let fakeHome = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let desktop = fakeHome.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let file = desktop.appendingPathComponent("photo.png")
        try writePNG(gray: 1, to: file)

        #expect(MenuBarWallpaper.loadStrip(url: file, home: fakeHome, pixelWidth: 100, aspect: 4, menuBarFraction: 0.3) == nil)
    }

    /// Dropbox's synced folder may sit straight in the home folder.
    @Test
    func aPictureInAHomeDropboxFolderFallsBack() throws {
        let fakeHome = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let dropbox = fakeHome.appendingPathComponent("Dropbox (Personal)", isDirectory: true)
        try FileManager.default.createDirectory(at: dropbox, withIntermediateDirectories: true)
        let file = dropbox.appendingPathComponent("wallpaper.png")
        try writePNG(gray: 0.5, to: file)

        #expect(!MenuBarWallpaper.isSafeToRead(file, home: fakeHome))
        #expect(MenuBarWallpaper.loadStrip(url: file, home: fakeHome, pixelWidth: 100, aspect: 4, menuBarFraction: 0.3) == nil)
    }

    @Test
    func unreadableOrMissingPicturesFallBackSilently() throws {
        let fakeHome = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let pictures = fakeHome.appendingPathComponent("Pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let notAnImage = pictures.appendingPathComponent("notes.heic")
        try Data("not an image".utf8).write(to: notAnImage)

        func load(_ url: URL?) -> MenuBarWallpaper.Strip? {
            MenuBarWallpaper.loadStrip(url: url, home: fakeHome, pixelWidth: 100, aspect: 4, menuBarFraction: 0.3)
        }
        #expect(load(nil) == nil)
        #expect(load(notAnImage) == nil)
        #expect(load(pictures.appendingPathComponent("missing.jpg")) == nil)
    }

    @Test
    func aReadablePictureBecomesASmallTopStripWithMatchingTextColor() throws {
        let fakeHome = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let pictures = fakeHome.appendingPathComponent("Pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let bright = pictures.appendingPathComponent("bright.png")
        let dark = pictures.appendingPathComponent("dark.png")
        try writePNG(gray: 0.95, to: bright, size: 1600)
        try writePNG(gray: 0.1, to: dark, size: 1600)

        let brightStrip = try #require(MenuBarWallpaper.loadStrip(
            url: bright, home: fakeHome, pixelWidth: 400, aspect: 5, menuBarFraction: 0.35
        ))
        #expect(brightStrip.image.width == 400)
        #expect(brightStrip.image.height == 80)
        #expect(brightStrip.prefersDarkText)

        let darkStrip = try #require(MenuBarWallpaper.loadStrip(
            url: dark, home: fakeHome, pixelWidth: 400, aspect: 5, menuBarFraction: 0.35
        ))
        #expect(!darkStrip.prefersDarkText)
    }

    @Test
    func darkTextOnlyOverABrightPicture() {
        #expect(MenuBarWallpaper.prefersDarkText(luminance: 0.9))
        #expect(!MenuBarWallpaper.prefersDarkText(luminance: 0.5))
        #expect(!MenuBarWallpaper.prefersDarkText(luminance: 0.1))
    }

    // MARK: - Helpers

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBarWallpaperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePNG(gray: CGFloat, to url: URL, size: Int = 64) throws {
        let context = try #require(CGContext(
            data: nil, width: size, height: size / 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
