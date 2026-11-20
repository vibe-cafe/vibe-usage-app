import SwiftUI

/// Turns SVG path data (the `d` attribute) into a SwiftUI `Path`.
///
/// Only what the bundled provider marks need, which is the whole path grammar
/// of SVG 1.1: M L H V C S Q T A Z in absolute and relative form, implicit
/// command repetition, numbers written without separators (`.5.5`, `-.3`), and
/// arc flags written as single digits (`a1 1 0 110 2`). An unreadable token
/// ends parsing and keeps what was drawn so far, so a bad string can only
/// truncate a mark, never crash the window.
enum SVGPathParser {
    static func path(from data: String) -> Path {
        var scanner = Scanner(Array(data.utf8))
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: UInt8 = 0

        while true {
            scanner.skipSeparators()
            guard !scanner.isAtEnd else { break }
            if let letter = scanner.commandLetter() {
                command = letter
            } else if command == 0 {
                break
            }
            // After a moveto, extra coordinate pairs are implicit linetos.
            let isRelative = command >= UInt8(ascii: "a")
            let base = isRelative ? current : .zero

            switch command | 0x20 {  // lower-case
            case UInt8(ascii: "m"):
                guard let p = scanner.point() else { return path }
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                subpathStart = current
                path.move(to: current)
                command = isRelative ? UInt8(ascii: "l") : UInt8(ascii: "L")
                lastCubicControl = nil; lastQuadControl = nil
            case UInt8(ascii: "l"):
                guard let p = scanner.point() else { return path }
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: (isRelative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: (isRelative ? current.y : 0) + y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil
            case UInt8(ascii: "c"):
                guard let c1 = scanner.point(), let c2 = scanner.point(), let p = scanner.point() else { return path }
                let control1 = CGPoint(x: base.x + c1.x, y: base.y + c1.y)
                let control2 = CGPoint(x: base.x + c2.x, y: base.y + c2.y)
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                path.addCurve(to: current, control1: control1, control2: control2)
                lastCubicControl = control2; lastQuadControl = nil
            case UInt8(ascii: "s"):
                guard let c2 = scanner.point(), let p = scanner.point() else { return path }
                let control1 = reflect(lastCubicControl, around: current)
                let control2 = CGPoint(x: base.x + c2.x, y: base.y + c2.y)
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                path.addCurve(to: current, control1: control1, control2: control2)
                lastCubicControl = control2; lastQuadControl = nil
            case UInt8(ascii: "q"):
                guard let c = scanner.point(), let p = scanner.point() else { return path }
                let control = CGPoint(x: base.x + c.x, y: base.y + c.y)
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                path.addQuadCurve(to: current, control: control)
                lastQuadControl = control; lastCubicControl = nil
            case UInt8(ascii: "t"):
                guard let p = scanner.point() else { return path }
                let control = reflect(lastQuadControl, around: current)
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                path.addQuadCurve(to: current, control: control)
                lastQuadControl = control; lastCubicControl = nil
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(),
                      let largeArc = scanner.flag(), let sweep = scanner.flag(),
                      let p = scanner.point()
                else { return path }
                let end = CGPoint(x: base.x + p.x, y: base.y + p.y)
                addArc(to: &path, from: current, to: end, rx: rx, ry: ry,
                       rotationDegrees: rotation, largeArc: largeArc, sweep: sweep)
                current = end
                lastCubicControl = nil; lastQuadControl = nil
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil; lastQuadControl = nil
                // `z` takes no arguments; a following number would be invalid.
                command = 0
            default:
                return path
            }
        }
        return path
    }

    private static func reflect(_ control: CGPoint?, around point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// SVG 1.1 implementation notes F.6.5–F.6.6: endpoint to center
    /// parameterization, then one cubic per quarter turn at most.
    static func addArc(
        to path: inout Path,
        from start: CGPoint,
        to end: CGPoint,
        rx rxIn: CGFloat,
        ry ryIn: CGFloat,
        rotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        if start == end { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 {
            path.addLine(to: end)
            return
        }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        // Radii too small for the chord grow just enough to reach it.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = lambda.squareRoot()
            rx *= s; ry *= s
        }

        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = denominator == 0 ? 0 : (max(0, numerator) / denominator).squareRoot()
        if largeArc == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)

        func pointOnEllipse(_ t: CGFloat) -> CGPoint {
            CGPoint(
                x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi,
                y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi
            )
        }
        func derivative(_ t: CGFloat) -> CGPoint {
            CGPoint(
                x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi,
                y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi
            )
        }

        var t = theta1
        var from = start
        for index in 0..<segments {
            let next = t + step
            let to = index == segments - 1 ? end : pointOnEllipse(next)
            let d1 = derivative(t), d2 = derivative(next)
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x + k * d1.x, y: from.y + k * d1.y),
                control2: CGPoint(x: to.x - k * d2.x, y: to.y - k * d2.y)
            )
            from = to
            t = next
        }
    }

    // MARK: - Tokens

    struct Scanner {
        private let bytes: [UInt8]
        private var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { index >= bytes.count }

        mutating func skipSeparators() {
            while index < bytes.count {
                let byte = bytes[index]
                guard byte == 0x20 || byte == 0x2C || byte == 0x09 || byte == 0x0A || byte == 0x0D else { return }
                index += 1
            }
        }

        mutating func commandLetter() -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            let isLetter = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            // `e` / `E` only ever appear inside a number's exponent.
            guard isLetter, byte != UInt8(ascii: "e"), byte != UInt8(ascii: "E") else { return nil }
            index += 1
            return byte
        }

        mutating func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }

        /// Arc flags are a single `0` or `1` and need no separator after them.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "0"): index += 1; return false
            case UInt8(ascii: "1"): index += 1; return true
            default: return nil
            }
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            var digits = 0
            while index < bytes.count, isDigit(bytes[index]) { index += 1; digits += 1 }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                while index < bytes.count, isDigit(bytes[index]) { index += 1; digits += 1 }
            }
            guard digits > 0 else { index = start; return nil }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                var lookahead = index + 1
                if lookahead < bytes.count, bytes[lookahead] == UInt8(ascii: "+") || bytes[lookahead] == UInt8(ascii: "-") {
                    lookahead += 1
                }
                if lookahead < bytes.count, isDigit(bytes[lookahead]) {
                    index = lookahead
                    while index < bytes.count, isDigit(bytes[index]) { index += 1 }
                }
            }
            guard let text = String(bytes: bytes[start..<index], encoding: .ascii),
                  let value = Double(text)
            else { index = start; return nil }
            return CGFloat(value)
        }

        private func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    }
}
