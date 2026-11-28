import AppKit
import SwiftUI
import Testing
@testable import VibeUsage

/// The status item shows `MenuBarLabel` as the button's own template image
/// (#140), so the system tints and dims it like every other menu-bar item.
/// These run on stand-alone `NSStatusBarButton`s: a real status item would
/// put an item in the machine's menu bar.
@MainActor
struct MenuBarStatusImageTests {
    nonisolated static let cost = "¥230.20"
    nonisolated static let tokens = "364,100,000"

    @Test
    func buttonShowsATemplateImageAndNothingOverIt() throws {
        let button = MenuBarRender.button(height: 22)
        let width = MenuBarStatusImage.apply(lines: [Self.cost, Self.tokens], to: button)
        let image = try #require(button.image)
        #expect(image.isTemplate)
        #expect(button.subviews.isEmpty)
        #expect(button.title.isEmpty)
        #expect(button.imagePosition == .imageOnly)
        #expect(button.imageScaling == .scaleNone)
        #expect(width == image.size.width)
        #expect(button.accessibilityValue() as? String == "\(Self.cost)，\(Self.tokens)")
    }

    /// Icon 18 pt, 7 pt to the figures, 4 pt each side; one line at 13 pt,
    /// two at 10 pt, all monospaced medium. The picture is as tall as the
    /// button, whatever the menu bar's height, a half point included.
    @Test(arguments: [22.0, 24.0, 28.5, 37.0])
    func sizeFollowsTheLayoutAndTheButtonHeight(height: CGFloat) {
        func textWidth(_ text: String, _ size: CGFloat) -> CGFloat {
            (text as NSString).size(withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            ]).width
        }
        #expect(MenuBarStatusImage.size(lines: [], height: height) == NSSize(width: 26, height: height))

        let one = MenuBarStatusImage.size(lines: [Self.cost], height: height)
        #expect(one.height == height)
        #expect(abs(one.width - ceil(4 + 18 + 7 + textWidth(Self.cost, 13) + 4)) <= 1)

        let two = MenuBarStatusImage.size(lines: [Self.cost, Self.tokens], height: height)
        let widest = max(textWidth(Self.cost, 10), textWidth(Self.tokens, 10))
        #expect(two.height == height)
        #expect(abs(two.width - ceil(4 + 18 + 7 + widest + 4)) <= 1)
    }

    /// A 1x and a 2x bitmap, each exactly the picture's size, so it is drawn
    /// pixel for pixel on either kind of screen, and AppKit picks the 2x one
    /// for a Retina screen.
    @Test(arguments: [false, true])
    func holdsSharpBitmapsForOneXAndTwoXScreens(darkMenuBar: Bool) throws {
        let image = MenuBarStatusImage.image(lines: [Self.cost, Self.tokens], height: 22, darkMenuBar: darkMenuBar)
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let width = Int(image.size.width)
        #expect(reps.map(\.pixelsWide).sorted() == [width, width * 2])
        #expect(reps.map(\.pixelsHigh).sorted() == [22, 44])
        #expect(reps.allSatisfy { $0.size == image.size })

        let rect = NSRect(origin: .zero, size: image.size)
        let retina = image.bestRepresentation(for: rect, context: nil, hints: [
            .ctm: NSAffineTransform(transform: AffineTransform(scale: 2)),
        ])
        #expect((retina as? NSBitmapImageRep)?.pixelsWide == width * 2)

        // A half-point menu bar exists on Retina screens only: its 2x bitmap
        // is still exact.
        let half = MenuBarStatusImage.image(lines: [Self.cost], height: 28.5, darkMenuBar: darkMenuBar)
        let halfRetina = half.representations.compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide }
        #expect(half.size.height == 28.5)
        #expect(halfRetina?.pixelsHigh == 57)
    }

    /// The system decides the color; the picture only says where. Fully
    /// opaque ink keeps the item as bright as its neighbors (`.primary`
    /// would have made it 85 %), in both weights, which put ink in the same
    /// place.
    @Test
    func bothWeightsAreOpaqueAndCoverTheSamePlace() throws {
        func masks(_ dark: Bool) throws -> [AlphaMask] {
            let image = MenuBarStatusImage.image(lines: [Self.cost, Self.tokens], height: 22, darkMenuBar: dark)
            return try image.representations.compactMap { $0 as? NSBitmapImageRep }
                .sorted { $0.pixelsWide < $1.pixelsWide }
                .map { try AlphaMask(#require($0.cgImage)) }
        }
        let light = try masks(false), dark = try masks(true)
        for (l, d) in zip(light, dark) {
            #expect(l.alpha.max() == 255 && d.alpha.max() == 255)
            #expect(l.anyInkBox == d.anyInkBox)
            // Heavier where the system's font smoothing is on (the default).
            #expect(d.weight >= l.weight * 0.99)
        }
    }

    /// The button's own appearance picks the weight.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func buttonAppearancePicksTheWeight(appearance: NSAppearance.Name) {
        let button = MenuBarRender.button(height: 22)
        button.appearance = NSAppearance(named: appearance)
        MenuBarStatusImage.apply(lines: [Self.cost], to: button)
        let expected = MenuBarStatusImage.image(lines: [Self.cost], height: 22, darkMenuBar: appearance == .darkAqua)
        #expect(button.image?.tiffRepresentation == expected.tiffRepresentation)
    }

    @Test
    func newFiguresDrawANewPicture() throws {
        let button = MenuBarRender.button(height: 22)
        let firstWidth = MenuBarStatusImage.apply(lines: ["¥1.00"], to: button)
        let first = try #require(button.image)

        // Same width, other digits.
        MenuBarStatusImage.apply(lines: ["¥9.99"], to: button)
        let second = try #require(button.image)
        #expect(second !== first)
        #expect(second.size == first.size)
        #expect(second.tiffRepresentation != first.tiffRepresentation)

        // Wider figures widen the item.
        let wider = MenuBarStatusImage.apply(lines: ["¥1,234.56"], to: button)
        #expect(wider > firstWidth)
        #expect(button.image?.size.width == wider)

        // A second line.
        MenuBarStatusImage.apply(lines: ["¥1,234.56", "1,000"], to: button)
        #expect(button.image !== second)
    }
}

/// Off-screen drawing of the status button, before and after #140, in a
/// window that is never shown.
@MainActor
enum MenuBarRender {
    static func button(width: CGFloat = 40, height: CGFloat) -> NSStatusBarButton {
        NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    /// The status item before #140: an empty button with the SwiftUI label
    /// pinned over it, both as wide as the label's `fittingSize`, read in the
    /// window as the app read it. The button is widened to whole points to
    /// compare with the picture; the label still starts at its left edge.
    /// `scale` is the screen's, which SwiftUI rounds positions to.
    static func overlayButton(lines: [String], height: CGFloat, scale: CGFloat) -> NSStatusBarButton {
        let label = MenuBarLabel(icon: MenuBarLabel.statusIcon, lines: lines)
        let host = NSHostingView(rootView: AnyView(label.environment(\.displayScale, scale)))
        let button = button(width: 200, height: height)
        button.title = ""
        button.image = nil
        let window = window(size: button.frame.size, appearance: .darkAqua)
        window.contentView?.addSubview(button)
        button.addSubview(host)
        let width = host.fittingSize.width
        button.removeFromSuperview()
        button.frame.size.width = ceil(width)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.autoresizingMask = [.height]
        return button
    }

    /// Draws `view` with `appearance` into a bitmap of `scale` pixels per point.
    static func draw(_ view: NSView, scale: CGFloat, appearance: NSAppearance.Name) -> NSBitmapImageRep {
        let size = view.frame.size
        let window = window(size: size, appearance: appearance)
        view.frame.origin = .zero
        window.contentView?.addSubview(view)
        window.contentView?.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()), pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        view.removeFromSuperview()
        return rep
    }

    /// The backing scale of a window that is never shown: the screens'.
    static var windowScale: CGFloat {
        window(size: NSSize(width: 1, height: 1), appearance: .darkAqua).backingScaleFactor
    }

    private static func window(size: NSSize, appearance: NSAppearance.Name) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        return window
    }
}

/// The alpha channel of a bitmap, rows from the top.
struct AlphaMask {
    let width: Int
    let height: Int
    let alpha: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        alpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
    }

    struct Box: Equatable {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
    }

    /// The pixels at least half as opaque as the most opaque one.
    var inkBox: Box? {
        let peak = Int(alpha.max() ?? 0)
        return box { $0 > 0 && Int($0) * 2 >= peak }
    }

    /// Every pixel with any ink.
    var anyInkBox: Box? { box { $0 > 0 } }

    /// Total ink, the mask scaled to its own peak: how heavy the strokes are.
    var weight: Double {
        let peak = Double(alpha.max() ?? 0)
        guard peak > 0 else { return 0 }
        return alpha.reduce(0.0) { $0 + Double($1) / peak }
    }

    private func box(_ isInk: (UInt8) -> Bool) -> Box? {
        var result: Box?
        for y in 0..<height {
            for x in 0..<width where isInk(alpha[y * width + x]) {
                if var box = result {
                    box.minX = min(box.minX, x); box.maxX = max(box.maxX, x)
                    box.minY = min(box.minY, y); box.maxY = max(box.maxY, y)
                    result = box
                } else {
                    result = Box(minX: x, minY: y, maxX: x, maxY: y)
                }
            }
        }
        return result
    }
}
