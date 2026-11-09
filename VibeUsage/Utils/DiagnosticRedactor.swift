import Foundation

/// Last-line filter over a finished diagnostic summary (diagnostics plan,
/// section 6 rule 9). The summary is already built only from typed fields and
/// fixed copy; this pass exists so a mistake in that whitelist still cannot
/// leak a home path, a key, a token, an email, or a proxy address.
enum DiagnosticRedactor {
    static let mask = "***"

    static func redact(_ text: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var out = text
        // A path runs to the end of its field: folder names may contain
        // spaces, so the mask covers everything up to the report's own field
        // separators (` · `, a line break, full-width brackets).
        let field = #"[^·\n（）]*"#
        if homeDirectory.count > 1 {
            let home = NSRegularExpression.escapedPattern(for: homeDirectory)
            out = out.replacingOccurrences(of: home + #"(?=[/\\])"# + field, with: "~/\(mask)",
                                           options: .regularExpression)
            out = out.replacingOccurrences(of: homeDirectory, with: "~")
        }
        let rules: [(pattern: String, replacement: String)] = [
            // Another user's home or a Claude-encoded project directory
            // (`-Users-<name>-Coding-<project>`).
            (#"/Users/"# + field, mask),
            (#"-Users-"# + field, mask),
            // Any URL: proxy addresses (with or without user:password), API
            // hosts with query strings. The summary itself contains none.
            (#"[A-Za-z][A-Za-z0-9+.\-]*://\S+"#, mask),
            (#"\bvbu_\S*"#, mask),
            (#"\bsk-[A-Za-z0-9_\-]+"#, mask),
            (#"(?i)\bBearer\s+\S+"#, "Bearer \(mask)"),
            (#"\beyJ[A-Za-z0-9_\-.=+/]*"#, mask),
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, mask),
        ]
        for rule in rules {
            out = out.replacingOccurrences(of: rule.pattern, with: rule.replacement,
                                           options: .regularExpression)
        }
        // Long opaque strings, except conventional variable names (all
        // upper-case letters, digits and `_`, e.g. the 40-character
        // `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`), which the report
        // lists on purpose.
        return replacingMatches(of: #"[A-Za-z0-9_\-.=+/]{40,}"#, in: out) { match in
            match.range(of: #"^[A-Z0-9_]+$"#, options: .regularExpression) != nil ? match : mask
        }
    }

    private static func replacingMatches(
        of pattern: String,
        in text: String,
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: transform(String(out[range])))
        }
        return out
    }
}
