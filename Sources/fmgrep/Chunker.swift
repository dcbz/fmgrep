// Chunker — split file text into numbered blocks that fit the model's context.

import Foundation

struct LoadedFile {
    let spec: FileSpec
    let lines: [String]        // 0-based; line n is at lines[n-1]
    var symbols: [Symbol] = []
}

enum LoadError: Error, CustomStringConvertible {
    case tooLarge(String)
    case unreadable(String)

    var description: String {
        switch self {
        case .tooLarge: return "file is larger than --max-file-bytes"
        case .unreadable(let name): return "cannot read \(name)"
        }
    }
}

func loadFile(_ spec: FileSpec, maxBytes: Int) throws -> LoadedFile {
    var text: String
    if let url = spec.url {
        let data: Data
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > maxBytes {
            throw LoadError.tooLarge(spec.display)
        }
        do { data = try Data(contentsOf: url) } catch { throw LoadError.unreadable(spec.display) }
        // Cheap binary sniff, same trick ripgrep/grep use.
        if data.prefix(8_192).contains(0) { return LoadedFile(spec: spec, lines: []) }
        if let utf8 = String(data: data, encoding: .utf8) { text = utf8 }
        else if let latin = String(data: data, encoding: .isoLatin1) { text = latin }
        else { return LoadedFile(spec: spec, lines: []) }
    } else {
        text = stdinText
    }
    var lines = text.components(separatedBy: "\n")
    if lines.last?.isEmpty == true && lines.count > 1 { lines.removeLast() } // trailing newline
    lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    let symbols = Symbols.parseSymbols(lines, ext: spec.url?.pathExtension ?? "")
    return LoadedFile(spec: spec, lines: lines, symbols: symbols)
}

/// A block of consecutive lines: `start` is the 1-based global line number.
struct Block {
    let fileID: Int
    let start: Int
    let lines: ArraySlice<String>
    var location: String = ""   // structural context, from the symbol map
    var end: Int { start + lines.count - 1 }
}

/// Symbol-aware when a map exists: boundaries snap to declarations whenever
/// the current block is already a third full, so functions rarely straddle.
func makeBlocks(_ file: LoadedFile, blockLines: Int, blockChars: Int, snapToSymbols: Bool = true) -> [Block] {
    var blocks: [Block] = []
    let all = ArraySlice(file.lines)
    let starts = snapToSymbols ? Set(symbolSplitPoints(symbols: file.symbols, lineCount: file.lines.count)) : []
    var i = 0
    while i < file.lines.count {
        var count = 0
        var chars = 0
        while i + count < file.lines.count,
              count < blockLines,
              chars + file.lines[i + count].count + 1 <= blockChars || count == 0 {
            if count > 0, starts.contains(i + count + 1), count >= blockLines / 3 { break }
            chars += file.lines[i + count].count + 1
            count += 1
        }
        let slice = all[i ..< i + count]
        if slice.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            blocks.append(Block(
                fileID: file.spec.id, start: i + 1, lines: slice,
                location: snapToSymbols && !file.symbols.isEmpty
                    ? Symbols.location(i + 1, file.symbols) : ""
            ))
        }
        i += count
    }
    return blocks
}

/// Raw text of a block, for the prefilter regex.
func blockRawText(_ block: Block) -> String {
    block.lines.joined(separator: "\n")
}

/// The numbered rendering of a block that the model sees.
func blockPromptText(_ block: Block) -> String {
    var out = ""
    for (offset, line) in block.lines.enumerated() {
        out += "\(offset + 1): \(line)\n"
    }
    return out
}
