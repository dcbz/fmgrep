// Symbols — cheap structural context (the useful slice of what an LSP knows).
//
// Our scratchpad experiment showed the 3B model cannot be trusted to *write*
// reliable notes about file structure. The fix is to not ask it: derive a
// symbol map per file, align block boundaries to declarations, and stamp
// every block's prompt with factual context ("inside func X") plus a compact
// file outline. A real language server (sourcekit-lsp, clangd) would give the
// same data plus cross-file references; this file keeps the shape so such a
// backend can slot in behind `parseSymbols` later.

import Foundation

struct Symbol: Sendable {
    let line: Int      // 1-based declaration line
    let kind: String   // func, class, def, @implementation, ...
    let name: String
}

enum Symbols {
    /// Kinds that define a *region* worth starting a block at. var/let stay
    /// in the outline (useful) but never fragment blocks.
    static let regionKinds: Set<String> = [
        "func", "class", "struct", "enum", "actor", "protocol", "extension",
        "init", "subscript", "def", "@implementation", "@interface",
        "method", "fn", "nested def", "nested class", "nested func",
    ]

    /// Declaration regexes per language family; intentionally conservative -
    /// a wrong symbol only decorates a block, it never filters results.
    private struct Decl {
        let re: NSRegularExpression
        let kindGroup: Int?      // group holding the kind word, if any
        let nameGroups: [Int]    // first present group is the name
        let fixedKind: String    // kind when kindGroup is nil
    }

    private static func patterns(for ext: String) -> [Decl] {
        func re(_ p: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: p)
        }
        switch ext.lowercased() {
        case "swift":
            return [Decl(re: re(#"^\s*(?:(?:public|private|internal|fileprivate|open|static|final|override|convenience|required|class|actor)\s+)*(?:@\w+\s+)*(func|var|let|struct|enum|protocol|extension|init|subscript)\s+([A-Za-z_$][\w$]*)"#)!, kindGroup: 1, nameGroups: [2], fixedKind: "")]
        case "m", "mm", "h":
            return [
                Decl(re: re(#"@(implementation|interface)\s+([A-Za-z_]\w*)"#)!, kindGroup: 1, nameGroups: [2], fixedKind: ""),
                Decl(re: re(#"^\s*[-+]\s*\([^)]*\)\s*([A-Za-z_]\w*)"#)!, kindGroup: nil, nameGroups: [1], fixedKind: "method"),
                Decl(re: re(#"^[A-Za-z_][\w \*\^]*\b([a-z_]\w*)\s*\([^;]*\)\s*\{"#)!, kindGroup: nil, nameGroups: [1], fixedKind: "fn"),
            ]
        case "py":
            return [Decl(re: re(#"^(\s*)(class|def)\s+([A-Za-z_]\w*)"#)!, kindGroup: 2, nameGroups: [3], fixedKind: "")]
        case "js", "ts", "jsx", "tsx":
            return [Decl(re: re(#"^\s*(?:export\s+)?(?:async\s+)?(?:function|class)\s+([A-Za-z_$][\w$]*)|(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:function|\()"#)!, kindGroup: nil, nameGroups: [1, 2], fixedKind: "fn")]
        default:
            return []
        }
    }

    static func parseSymbols(_ lines: [String], ext: String) -> [Symbol] {
        let decls = patterns(for: ext)
        guard !decls.isEmpty else { return [] }
        var symbols: [Symbol] = []
        for (i, line) in lines.enumerated() {
            guard line.count < 400, symbols.count < 200 else { continue }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            guard indent <= 12 else { continue } // skip statements inside bodies
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            for decl in decls {
                guard let m = decl.re.firstMatch(in: line, range: range) else { continue }
                func group(_ g: Int) -> String? {
                    guard g > 0, g <= m.numberOfRanges else { return nil }
                    let r = m.range(at: g)
                    return r.location == NSNotFound ? nil : ns.substring(with: r)
                }
                var kind = group(decl.kindGroup ?? 0) ?? decl.fixedKind
                guard let name = decl.nameGroups.compactMap(group).first else { continue }
                if indent > 0, kind == "class" || kind == "def" || kind == "func" { kind = "nested " + kind }
                symbols.append(Symbol(line: i + 1, kind: kind, name: name))
                break
            }
        }
        return symbols
    }

    /// Compact one-line outline for the prompt, e.g. "class LiveOptions(12) func parseLiveOptions(53) ...".
    static func outline(_ symbols: [Symbol], maxChars: Int = 320) -> String {
        var s = ""
        for sym in symbols {
            let piece = "\(sym.kind) \(sym.name)(\(sym.line)) "
            if s.count + piece.count > maxChars { s += "…"; break }
            s += piece
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Human description of where a block sits, e.g. "inside func parseLiveOptions, declared at line 53".
    static func location(_ blockStart: Int, _ symbols: [Symbol]) -> String {
        guard let containing = symbols.last(where: { $0.line <= blockStart && regionKinds.contains($0.kind) }) else {
            return "module level, before the first declaration"
        }
        return "inside \(containing.kind) \(containing.name), declared at line \(containing.line)"
    }
}

// MARK: - Symbol-aligned chunking

/// Split points: line 1 plus the start of every *region* declaration (var/let
/// excluded so blocks don't shatter); blocks still respect the size caps.
func symbolSplitPoints(symbols: [Symbol], lineCount: Int) -> [Int] {
    Set(symbols.filter { Symbols.regionKinds.contains($0.kind) }.map(\.line).filter { $0 <= lineCount }).union([1]).sorted()
}
