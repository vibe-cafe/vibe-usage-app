import AppKit
import SwiftUI
import Testing
@testable import VibeUsage

/// Before / after sheets of the status item for #140, at 1x and 2x, drawn
/// off screen (no screen capture, no real status item). Opt-in:
///
///     VIBE_USAGE_RENDER_MENUBAR=<dir> swift test --filter MenuBarStatusImageRenderTests
///
/// Rows: the label laid over the button (before) and the button's own
/// template picture (after), dark and light, and with the button's own
/// dimming (`appearsDisabled`), which tints the picture and never reached
/// the overlay. The menu bar's inactive dimming happens in the real menu bar
/// only; a row tints the picture to the gray #140 measured (#747474 on
/// #343434). The last row overlays both dark masks: red before only, cyan
/// after only, white both. `统计.txt` lists ink boxes and ink weight per case.
///
/// At the scale of the off-screen window (the screens', 2x on a Retina Mac)
/// the run also checks that every case puts its ink where the overlay did,
/// with the same weight, dark and light. At the other scale the overlay is
/// a reduced drawing, so it is only listed.
@MainActor
struct MenuBarStatusImageRenderTests {
    nonisolated static let outputDirectory = ProcessInfo.processInfo.environment["VIBE_USAGE_RENDER_MENUBAR"]

    private static let height: CGFloat = 22
    private static let cases: [(name: String, lines: [String])] = [
        ("仅图标", []),
        ("一行", ["¥230.20"]),
        ("两行", ["¥230.20", "364,100,000"]),
    ]
    private static let dark = CGColor(srgbRed: 0x34 / 255, green: 0x34 / 255, blue: 0x34 / 255, alpha: 1)
    private static let light = CGColor(srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255, alpha: 1)

    private enum Row: CaseIterable {
        case beforeDark, beforeDarkDimmed, afterDark, afterDarkDimmed, afterReportedGray
        case beforeLight, afterLight, overlay

        var title: String {
            switch self {
            case .beforeDark: "改前 · 深色"
            case .beforeDarkDimmed: "改前 · 深色 · 按钮变暗"
            case .afterDark: "改后 · 深色"
            case .afterDarkDimmed: "改后 · 深色 · 按钮变暗"
            case .afterReportedGray: "改后 · 按报告的 #747474 染色"
            case .beforeLight: "改前 · 浅色"
            case .afterLight: "改后 · 浅色"
            case .overlay: "叠加（红=仅改前 青=仅改后 白=重合）"
            }
        }
    }

    @Test(.enabled(if: outputDirectory != nil))
    func renderBeforeAndAfterSheets() throws {
        let directory = URL(fileURLWithPath: Self.outputDirectory!, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let windowScale = MenuBarRender.windowScale
        var report = ["离屏窗口的缩放：\(windowScale)x（只在这个缩放下逐项断言位置和墨量）"]
        for scale: CGFloat in [1, 2] {
            var cells: [[CGImage]] = Row.allCases.map { _ in [] }
            for item in Self.cases {
                let before = { (appearance: NSAppearance.Name, dimmed: Bool) -> NSBitmapImageRep in
                    let button = MenuBarRender.overlayButton(lines: item.lines, height: Self.height, scale: scale)
                    button.appearsDisabled = dimmed
                    return MenuBarRender.draw(button, scale: scale, appearance: appearance)
                }
                let after = { (appearance: NSAppearance.Name, dimmed: Bool) -> NSBitmapImageRep in
                    let button = MenuBarRender.button(height: Self.height)
                    button.appearance = NSAppearance(named: appearance)
                    let width = MenuBarStatusImage.apply(lines: item.lines, to: button)
                    button.frame.size.width = width
                    button.appearsDisabled = dimmed
                    return MenuBarRender.draw(button, scale: scale, appearance: appearance)
                }
                func template(dark: Bool) throws -> CGImage {
                    let image = MenuBarStatusImage.image(lines: item.lines, height: Self.height, darkMenuBar: dark)
                    return try #require(image.representations
                        .compactMap { $0 as? NSBitmapImageRep }
                        .first { CGFloat($0.pixelsWide) == image.size.width * scale }?.cgImage)
                }
                let darkTemplate = try template(dark: true)
                let beforeDark = try #require(before(.darkAqua, false).cgImage)
                let beforeLight = try #require(before(.aqua, false).cgImage)
                let row: [Row: CGImage] = try [
                    .beforeDark: beforeDark,
                    .beforeDarkDimmed: #require(before(.darkAqua, true).cgImage),
                    .afterDark: #require(after(.darkAqua, false).cgImage),
                    .afterDarkDimmed: #require(after(.darkAqua, true).cgImage),
                    .afterReportedGray: Self.tinted(darkTemplate, white: 1, alpha: Double(0x74 - 0x34) / Double(0xFF - 0x34)),
                    .beforeLight: beforeLight,
                    .afterLight: #require(after(.aqua, false).cgImage),
                    .overlay: Self.overlay(before: AlphaMask(beforeDark), after: AlphaMask(darkTemplate)),
                ]
                for (index, kind) in Row.allCases.enumerated() { cells[index].append(row[kind]!) }

                for (name, old, new) in try [("深色", beforeDark, darkTemplate), ("浅色", beforeLight, template(dark: false))] {
                    let b = AlphaMask(old), t = AlphaMask(new)
                    let weight = t.weight / max(b.weight, 1)
                    report.append("\(Int(scale))x \(item.name) \(name) 尺寸 \(t.width)×\(t.height) px（改前 \(b.width)×\(b.height)）")
                    report.append("  墨迹框（≥ 一半不透明）改前 \(Self.describe(b.inkBox)) 改后 \(Self.describe(t.inkBox))")
                    report.append("  墨迹框（任何墨迹）     改前 \(Self.describe(b.anyInkBox)) 改后 \(Self.describe(t.anyInkBox))")
                    report.append(String(format: "  墨量（改后 / 改前）%.3f", weight))
                    if scale == windowScale {
                        let context = "\(item.name) \(name) \(scale)x"
                        #expect(t.width == b.width && t.height == b.height, "\(context)")
                        #expect(t.inkBox == b.inkBox, "\(context)")
                        #expect(t.anyInkBox == b.anyInkBox, "\(context)")
                        #expect(abs(weight - 1) < 0.03, "\(context) \(weight)")
                    }
                }
            }
            let zoom: CGFloat = scale == 1 ? 6 : 3
            let sheet = try Self.sheet(cells: cells, zoom: zoom)
            let data = try #require(NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("对照-\(Int(scale))x.png"))
        }
        try report.joined(separator: "\n").write(
            to: directory.appendingPathComponent("统计.txt"), atomically: true, encoding: .utf8
        )
        print(report.joined(separator: "\n"))
    }

    private static func describe(_ box: AlphaMask.Box?) -> String {
        guard let box else { return "无" }
        return "x \(box.minX)–\(box.maxX) y \(box.minY)–\(box.maxY)"
    }

    /// `image`'s alpha filled with one color.
    private static func tinted(_ image: CGImage, white: CGFloat, alpha: CGFloat) -> CGImage {
        let context = bitmap(width: image.width, height: image.height)
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(CGColor(gray: white, alpha: alpha))
        context.fill(rect)
        return context.makeImage()!
    }

    /// Red before only, cyan after only, white both, on black; each mask
    /// scaled to its own peak (the overlay drew `.primary`, 85 %).
    private static func overlay(before: AlphaMask, after: AlphaMask) -> CGImage {
        let width = min(before.width, after.width), height = min(before.height, after.height)
        let beforePeak = Int(before.alpha.max() ?? 1), afterPeak = Int(after.alpha.max() ?? 1)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let b = UInt8(min(255, Int(before.alpha[y * before.width + x]) * 255 / max(beforePeak, 1)))
                let a = UInt8(min(255, Int(after.alpha[y * after.width + x]) * 255 / max(afterPeak, 1)))
                let i = (y * width + x) * 4
                pixels[i] = b; pixels[i + 1] = a; pixels[i + 2] = a
            }
        }
        let context = pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        }
        return context
    }

    private static func sheet(cells: [[CGImage]], zoom: CGFloat) throws -> CGImage {
        let labelWidth: CGFloat = 330, gap: CGFloat = 16, margin: CGFloat = 20, headerHeight: CGFloat = 34
        let columnWidths = (0..<cases.count).map { column in
            cells.map { CGFloat($0[column].width) }.max()! * zoom
        }
        let cellHeight = cells.map { CGFloat($0[0].height) }.max()! * zoom
        let width = margin * 2 + labelWidth + columnWidths.reduce(0, +) + gap * CGFloat(cases.count - 1)
        let height = margin * 2 + headerHeight + (cellHeight + gap) * CGFloat(cells.count)
        let context = bitmap(width: Int(width), height: Int(height))
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(white: 0.9, alpha: 1),
        ]
        func top(_ y: CGFloat, _ h: CGFloat) -> CGFloat { height - y - h }

        var x = margin + labelWidth
        for (column, item) in cases.enumerated() {
            (item.name as NSString).draw(at: CGPoint(x: x, y: top(margin, 20)), withAttributes: attributes)
            x += columnWidths[column] + gap
        }
        for (index, row) in Row.allCases.enumerated() {
            let y = margin + headerHeight + CGFloat(index) * (cellHeight + gap)
            (row.title as NSString).draw(at: CGPoint(x: margin, y: top(y + cellHeight / 2 + 9, 18)),
                                         withAttributes: attributes)
            var x = margin + labelWidth
            for column in 0..<cases.count {
                let image = cells[index][column]
                let rect = CGRect(x: x, y: top(y, cellHeight),
                                  width: CGFloat(image.width) * zoom, height: CGFloat(image.height) * zoom)
                switch row {
                case .beforeLight, .afterLight: context.setFillColor(light)
                case .overlay: context.setFillColor(CGColor(gray: 0, alpha: 1))
                default: context.setFillColor(dark)
                }
                context.fill(rect)
                context.draw(image, in: rect)
                x += columnWidths[column] + gap
            }
        }
        return context.makeImage()!
    }

    private static func bitmap(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
}
