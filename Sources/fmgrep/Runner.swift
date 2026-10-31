// Runner — fan the scan out over files, format results grep-style.

import Foundation

// stdin is drained once at startup (Chunker reads this, read-only afterwards).
nonisolated(unsafe) var stdinText = ""

// MARK: - Concurrency helpers

actor Semaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ permits: Int) { self.permits = permits }
    func wait() async {
        if permits > 0 { permits -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        if waiters.isEmpty { permits += 1 } else { waiters.removeFirst().resume() }
    }
}

final class TaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    func register(_ task: Task<Void, Never>) {
        lock.lock(); tasks.append(task); lock.unlock()
    }
    func cancelAll() {
        lock.lock(); let all = tasks; tasks.removeAll(); lock.unlock()
        for t in all { t.cancel() }
    }
}

// MARK: - Output formatting

private let ESC = "\u{1B}["

struct Printer {
    let useColor: Bool
    func paint(_ code: String, _ s: String) -> String { useColor ? ESC + code + "m" + s + ESC + "0m" : s }

    func plain(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }

    func matchLine(file: String, number: Int?, text: String, quote: String?, explain: String?) {
        var s = paint("35;1", file)
        if let number { s += ":" + paint("32", String(number)) }
        s += ":"
        if let quote, quote.count >= 3, let range = text.range(of: quote, options: .caseInsensitive) {
            s += String(text[..<range.lowerBound])
            s += paint("1;4", String(text[range]))   // bold+underline the quoted fragment
            s += String(text[range.upperBound...])
        } else {
            s += text
        }
        if let explain, !explain.isEmpty { s += "\n" + paint("33", "  # " + explain) }
        plain(s)
    }
}

// MARK: - Sink

struct ScoredMatch: Sendable {
    let display: String
    let line: Int
    let text: String
    let quote: String
    let reason: String
    let score: Int
}

actor Sink {
    private let options: Options
    private let registry: TaskRegistry
    private let printer: Printer
    private var announced: Set<Int> = []      // files already listed in -l mode
    private var hadMatch: Set<Int> = []
    private var counts: [Int: Int] = [:]
    private var printedKeys: Set<String> = []   // fileID:line, for two-pass sweeps
    private var emittedLines = 0
    private var stopAll = false
    private var ranked: [ScoredMatch] = []    // buffered hits when --top is set

    init(options: Options, registry: TaskRegistry) {
        self.options = options
        self.registry = registry
        self.printer = Printer(useColor: options.color && isatty(1) == 1 && !options.json)
    }

    func isDoneForFile(_ id: Int) -> Bool { stopAll || announced.contains(id) }

    func warn(_ message: String) {
        FileHandle.standardError.write(("fmgrep: " + message + "\n").data(using: .utf8)!)
    }

    private var warnedKeys: Set<String> = []
    func warnOnce(_ message: String, key: String) {
        if warnedKeys.insert(key).inserted {
            FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        }
    }

    /// Report one block verdict. Returns false when the file should stop
    /// evaluating its remaining blocks.
    func report(_ verdict: MatchVerdict, block: Block, display: String, scores: [Int: Int] = [:]) -> Bool {
        var verdict = verdict
        if verdict.isMatch, verdict.confidence < (options.minConfidence ?? 1) {
            verdict.isMatch = false
            verdict.lineNumbers = []
        }
        let lines = verdict.isMatch
            ? verdict.lineNumbers.filter { (1 ... block.lines.count).contains($0) }
            : []
        // A coarse sieve plus a fine re-sweep can present one line twice; grep
        // would print it once, so print it once.
        let fresh = lines.filter { printedKeys.insert("\(block.fileID):\(block.start + $0 - 1)").inserted }
        if verdict.isMatch { hadMatch.insert(block.fileID) }

        if options.count {
            counts[block.fileID, default: 0] += fresh.count
            return !stopAll
        }

        if options.quiet {
            guard verdict.isMatch else { return true }
            stopAll = true
            registry.cancelAll()
            return false
        }

        if options.listFiles {
            guard verdict.isMatch else { return true }
            if options.invert { return false } // a match excludes this file from -Lv
            guard announced.insert(block.fileID).inserted else { return false }
            printer.plain(display)
            if options.maxCount > 0, announced.count >= options.maxCount {
                stopAll = true
                registry.cancelAll()
            }
            return false
        }

        guard verdict.isMatch else { return true }
        for local in fresh {
            let n = block.start + local - 1
            let text = String(block.lines[block.lines.startIndex + (local - 1)])
            counts[block.fileID, default: 0] += 1
            let inQuote = verdict.quote.count >= 3 && text.localizedCaseInsensitiveContains(verdict.quote)
            if options.top > 0 {
                ranked.append(ScoredMatch(
                    display: display, line: n, text: text, quote: verdict.quote,
                    reason: verdict.reason, score: verdict.confidence * 100 + (inQuote ? 10 : 0)
                ))
            } else if options.json {
                emitJSON(file: display, line: n, text: text, quote: verdict.quote, reason: verdict.reason)
            } else {
                var why: String?
                if options.debug {
                    let sc = scores[local] ?? verdict.confidence
                    why = verdict.reason.isEmpty ? "score \(sc)" : "score \(sc) - \(verdict.reason)"
                } else if options.explain {
                    why = verdict.reason
                }
                printer.matchLine(
                    file: display,
                    number: options.lineNumbers ? n : nil,
                    text: text,
                    quote: verdict.quote,
                    explain: why
                )
            }
            emittedLines += 1
            if options.maxCount > 0, options.top == 0, emittedLines >= options.maxCount {
                stopAll = true
                registry.cancelAll()
                return false
            }
        }
        return true
    }

    private func emitJSON(file: String, line: Int, text: String, quote: String, reason: String) {
        let obj: [String: String] = [
            "file": file, "line": String(line), "text": text,
            "quote": quote, "reason": reason, "query": options.query,
        ]
        if let data = try? JSONEncoder().encode(obj), let s = String(data: data, encoding: .utf8) {
            printer.plain(s)
        }
    }

    /// Final pass: ranked --top output, -c lines, -v listings. Returns whether anything was printed.
    func finish(files: [FileSpec]) -> Bool {
        var printed = false
        if !ranked.isEmpty {
            for m in ranked.sorted(by: { $0.score != $1.score ? $0.score > $1.score : ($0.display != $1.display ? $0.display < $1.display : $0.line < $1.line) }).prefix(options.top) {
                printer.matchLine(
                    file: m.display,
                    number: options.lineNumbers ? m.line : nil,
                    text: m.text,
                    quote: m.quote,
                    explain: options.explain ? m.reason : nil
                )
            }
            printed = true
        }
        if options.count {
            for f in files {
                let n = counts[f.id, default: 0]
                if n == 0 { printed = true; printer.plain(f.display + ":0") }
                else if !options.invert { printed = true; printer.plain(f.display + ":" + String(n)) }
            }
        } else if options.listFiles, options.invert {
            for f in files where !hadMatch.contains(f.id) {
                printed = true
                printer.plain(f.display)
            }
        }
        return printed
    }

    func anyFileMatched() -> Bool { !hadMatch.isEmpty }
}

// MARK: - Per-file pipeline

actor VerdictCache {
    private var map: [String: (score: Int, reason: String)] = [:]
    private var reuse = 0
    func lookup(_ key: String) -> (score: Int, reason: String)? {
        guard let v = map[key] else { return nil }
        reuse += 1
        return v
    }
    func store(_ key: String, score: Int, reason: String) { map[key] = (score, reason) }
    func report() -> (entries: Int, reuse: Int) { (map.count, reuse) }
}

/// Normalized cache key for one candidate line; nil = deterministic junk
/// (control/replacement chars, or a line mostly of non-ASCII characters -
/// skipped for the same reason binaries are: nothing here can be about an
/// English-language query).
func lineCacheKey(_ text: String) -> String? {
    let t = text.trimmingCharacters(in: .whitespaces)
    guard t.count >= 3 else { return nil }
    var nonASCII = 0
    for u in t.unicodeScalars {
        if u.value == 0xFFFD || (u.value < 0x20 && u != "\t".unicodeScalars.first!) { return nil }
        if u.value > 126 { nonASCII += 1 }
    }
    guard nonASCII * 5 <= t.count * 3 else { return nil } // >60% non-ASCII
    return t.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
}

/// Bookkeeping for the collapse guard so re-judged windows are visible in the
/// cost report instead of silently tripling a run.
actor CollapseGuard {
    private(set) var windows = 0
    private(set) var extraCalls = 0
    func escalate(window: Int, children: Int) {
        windows += 1
        extraCalls += max(0, children - 1)
    }
    private(set) var confirmed = 0
    func confirm() { confirmed += 1 }
    private(set) var reswept = 0
    private(set) var resweepCalls = 0
    func resweep(windows: Int, calls: Int) { reswept += windows; resweepCalls += calls }
    func report() -> (windows: Int, extraCalls: Int, confirmed: Int, reswept: Int, resweepCalls: Int) { (windows, extraCalls, confirmed, reswept, resweepCalls) }
}

/// Lines that are structurally incapable of being a place where something
/// happens: a bare `label:`, or one comma-separated tail of a multi-line
/// declaration/argument list. Not vocabulary - pure syntax, so it cannot
/// bias the search toward words the query happens to contain.
func isStructuralTail(_ text: String, depthBefore: Int) -> Bool {
    let t = text.trimmingCharacters(in: .whitespaces)
    // braces / `else` with no statement in them
    let bracesOnly = t.replacingOccurrences(of: "[{}()\\[\\];]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\belse\\b", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    if t.contains("{") || t.contains("}"), bracesOnly.isEmpty { return true }
    // a lone storage/type keyword: the header of a declaration that continues
    // on the next line, never itself a place where something happens
    let keyword = (t.hasSuffix(";") ? String(t.dropLast()) : t).trimmingCharacters(in: .whitespaces)
    if ["void", "int", "char", "unsigned", "signed", "long", "short", "float", "double",
        "static", "extern", "inline", "struct", "union", "enum", "bool", "_Bool",
        "public", "private", "protected", "internal", "func", "def", "sub"].contains(keyword) {
        return true
    }
    if t.last == ":", t.count > 2, t.filter({ $0 == ":" }).count == 1,
       let colon = t.firstIndex(of: ":") {
        let head = t[..<colon].trimmingCharacters(in: .whitespaces)
        if !head.isEmpty, head.first!.isLetter, head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return true // goto label: `block:` / `out:`
        }
    }
    if depthBefore > 0, t.hasSuffix(","), t.rangeOfCharacter(from: .alphanumerics) != nil {
        // one item of a multi-line signature/argument list: the call or the
        // declaration is the interesting line, and it sits where the paren opened
        let core = String(t.dropLast())
        if !core.contains("{"), !core.contains(";"), !core.contains("return"),
           !core.contains("=") || core.hasSuffix("=") {
            return true
        }
    }
    return false
}

/// Paren depth just before a line, over a bounded lookback window.
func parenDepth(_ lines: [String], before i: Int) -> Int {
    var d = 0
    var j = max(0, i - 24)
    while j < i {
        for c in lines[j] { if c == "(" { d += 1 } else if c == ")" { d -= 1 } }
        j += 1
    }
    return max(0, d)
}

func regexHit(_ text: String, _ re: NSRegularExpression) -> Bool {
    let ns = text as NSString
    return re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
}

enum FilePlan: Sendable, Equatable { case skip, lines, runs, blocks }

func processFile(
    _ spec: FileSpec,
    options: Options,
    matchTest: String,
    plan: FilePlan?,
    pattern: String?,
    cache: VerdictCache,
    guard_: CollapseGuard,
    semaphore: Semaphore,
    sink: Sink
) async {
    guard !Task.isCancelled else { return }
    if plan == .skip { return }

    let file: LoadedFile
    do {
        file = try loadFile(spec, maxBytes: options.maxFileBytes)
    } catch LoadError.tooLarge {
        return // skipped silently, like grep's binary handling
    } catch {
        await sink.warn("\(spec.display): \(error)")
        return
    }
    if file.lines.isEmpty { return }

    let regex: NSRegularExpression? = (pattern ?? options.prefilter).flatMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    let blocks = makeBlocks(file, blockLines: options.blockLines, blockChars: options.blockChars, snapToSymbols: options.symbols)
    let outline = options.symbols ? Symbols.outline(file.symbols) : ""
    // Cost measured: prose fields double per-call latency on-device (1.1 s
    // answers-only vs 2.1 s with a note sentence), so notes are opt-in even
    // in the line engines.
    // Scratchpad: explicit on/off wins; otherwise the triage call decides
    // per file (needsNotes), gated to files long enough for it to matter.
    var notes: NotesBox? = options.scratchpad == true ? NotesBox() : nil

    // Triage gate for the planner-less paths (explicit --blocks or downgrade).
    if plan == nil || options.engine == .blocks, options.triage, blocks.count > 1, !options.invert, !file.symbols.isEmpty {
        // In hybrid mode, -E first filters the whole file for free: a file
        // whose path and declarations miss the regex is unlikely to hold the
        // answer; set --no-triage for exhaustive -E semantics.
        if let regex, regex.firstMatch(in: spec.display + "\n" + Symbols.outline(file.symbols, maxChars: 2000),
                                        range: NSRange(location: 0, length: (spec.display + "\n" + Symbols.outline(file.symbols, maxChars: 2000)).utf16.count)) == nil {
            return
        }
        await semaphore.wait()
        do {
            let rel = try await triage(
                fileDisplay: spec.display,
                outline: Symbols.outline(file.symbols, maxChars: 600),
                query: options.query
            )
            await semaphore.signal()
            if !rel.relevant && rel.confidence >= 1 { return }
            if options.scratchpad == nil, rel.needsNotes, file.lines.count > 150 {
                notes = NotesBox()   // auto: the model asked for memory, on this file only
            }
        } catch {
            await semaphore.signal()
            // fail open: an unjudgeable file still gets the normal scan
        }
    }

    func dumpNotes() async {
        if options.showScratchpad, let notes {
            let collected = notes.snapshot()
            if !collected.isEmpty {
                await sink.warn("scratchpad for \(spec.display):\n" + collected.map { "  - " + $0 }.joined(separator: "\n"))
            }
        }
    }

    // Line-granular engines: score runs of lines (default, 32/call) or strict
    // one-line-per-call. Each answer is a binary per-line decision - the
    // per-line prompt shape, at 1/32 the calls.
    if options.engine != .blocks || plan != nil {
        var lineInstructions = options.instructionsOverride ?? defaultRunInstructions
        if !matchTest.isEmpty {
            lineInstructions += "\nQuery annotation (example vocabulary and exclusions ONLY - a line answering the query without these words still passes):\n" + matchTest
        }
        let chunks: [[(number: Int, text: String)]]
        if plan == .lines, let regex {
            chunks = file.lines.enumerated()
                .filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty && regexHit($0.element, regex) }
                .map { [($0.offset + 1, $0.element)] }
        } else if plan == .runs, let regex {
            // filtered-dense: judge matched lines in small arrays of 8.
            // Short arrays stay honest (32-item arrays collapse); grouping
            // amortizes prefill 8x vs one-line calls.
            let hits = file.lines.enumerated().filter {
                !$0.element.trimmingCharacters(in: .whitespaces).isEmpty && regexHit($0.element, regex)
            }
            var cs: [[(number: Int, text: String)]] = []
            var i = 0
            while i < hits.count {
                let step = options.debug ? 1 : options.matchedChunk
                cs.append(hits[i ..< min(i + step, hits.count)].map { ($0.offset + 1, $0.element) })
                i += step
            }
            chunks = cs
        } else {
            // An explicit --line always means one call per line. Otherwise a
            // batched window is used as a cheap sieve and every line it vouches
            // for is re-judged alone (see `confirm`), which is what keeps the
            // fast path honest.
            let runSize = options.debug ? 1
                : (options.engine == .line && options.engineExplicit ? 1
                   : (plan == .runs ? options.scoreLines : (options.engine == .line ? 1 : options.scoreLines)))
            var cs: [[(number: Int, text: String)]] = []
            var s = 0
            while s < file.lines.count {
                let e = min(s + runSize, file.lines.count)
                cs.append(Array(s ..< e).map { (number: $0 + 1, text: file.lines[$0]) })
                s = e
            }
            chunks = cs
        }
        let threshold = max(1, options.minConfidence ?? 2)

        /// One judging call: semaphore-gated, refusal-reported. nil = no verdict.
        /// The scope line tells the model which function it is looking at, which is
        /// what lets it tell a behavioural line from one parameter of a signature.
        func scopeAt(_ line: Int) -> String {
            options.symbols && !file.symbols.isEmpty ? Symbols.location(line, file.symbols) : ""
        }
        /// The lines around a candidate, for a call that judges one line.
        func neighborhood(_ line: Int, radius: Int = 2) -> [(number: Int, text: String)] {
            var out: [(number: Int, text: String)] = []
            for n in max(1, line - radius) ... min(file.lines.count, line + radius) where n != line {
                let t = file.lines[n - 1]
                if !t.trimmingCharacters(in: .whitespaces).isEmpty, lineCacheKey(t) != nil {
                    out.append((n, t))
                }
            }
            return out
        }
        func callModel(_ entries: [(number: Int, text: String)], forced: RunMode? = nil,
                       context: [(number: Int, text: String)] = []) async -> RunResult? {
            await semaphore.wait()
            let scope = scopeAt(entries.first?.number ?? 1)
            do {
                let r = try await scoreEntries(
                    entries, fileDisplay: spec.display, totalLines: file.lines.count,
                    query: options.query,
                    instructions: lineInstructions,
                    mode: forced ?? ((options.explain || options.debug) ? .full : (notes != nil ? .noted : .lean)),
                    notes: notes, scope: scope, context: context
                )
                await semaphore.signal()
                return r
            } catch {
                await semaphore.signal()
                if !Task.isCancelled, !(error is CancellationError) {
                    let kind = isContentRefusal(error) ? "refused by the model's content filter" : "\(error)"
                    await sink.warnOnce("fmgrep: \(spec.display):\(entries.first?.number ?? 0): \(kind) (further \(kind) warnings for this file suppressed)", key: "\(spec.id)|\(kind)")
                }
                return nil
            }
        }

        /// Per-line verdicts for a candidate window, positions relative to `entries`.
        ///
        /// Collapse guard: a 3B model asked for a 32-item `[Int]` on dense code
        /// reproduces one value instead of reading (measured: whole windows of
        /// uniform 2s that print a third of a file). A window that answers
        /// "match" on >=90% of its lines while being longer than one honest batch
        /// is therefore not a verdict - re-judge it in quarter-sized pieces until
        /// each piece is short enough to stay honest. Mass "no" is left alone:
        /// that is what most code genuinely is, and paying 4x for it buys nothing.
        func resolve(_ entries: [(number: Int, text: String)], at offset: Int, checked: Bool = false) async
            -> [(pos: Int, score: Int, reason: String)]
        {
            if Task.isCancelled { return [] }
            if entries.count == 1 {
                // short-circuit ladder: structural filter -> junk filter -> cache -> model.
                let ln = entries[0].number
                if isStructuralTail(entries[0].text, depthBefore: parenDepth(file.lines, before: ln - 1)) {
                    if options.debug {
                        await sink.warn("[debug] \(spec.display):\(ln): structural tail (label or signature continuation) - not judged")
                    }
                    return []
                }
                guard var key = lineCacheKey(entries[0].text) else {
                    if options.debug {
                        await sink.warn("[debug] \(spec.display):\(entries[0].number): deterministic junk filter (control/mostly-non-ASCII chars)")
                    }
                    return []
                }
                key += " @" + scopeAt(ln)
                if options.cache, let c = await cache.lookup(key) {
                    return [(offset, c.score, c.reason + " [cached]")]
                }
                guard let r = await callModel(entries, forced: checked ? .full : nil,
                                              context: neighborhood(ln)), let sc = r.answers.first else { return [] }
                if options.cache { await cache.store(key, score: sc, reason: r.reason) }
                return [(offset, sc, r.reason)]
            }
            guard let r = await callModel(entries) else { return [] }
            let ans = r.answers
            if ans.count == entries.count, entries.count > options.matchedChunk {
                let yes = ans.filter { $0 >= threshold }.count
                if yes * 10 >= ans.count * 9 {   // the whole window says "hit"
                    await guard_.escalate(window: entries.count, children: 4)
                    if options.debug {
                        await sink.warn("[debug] \(spec.display):\(entries.first?.number ?? 1): collapse guard - \(yes)/\(entries.count) lines scored >= \(threshold) in one batch, re-judging in windows of \(max(options.matchedChunk, entries.count / 4))")
                    }
                    let step = max(options.matchedChunk, entries.count / 4)
                    var out: [(pos: Int, score: Int, reason: String)] = []
                    var i = 0
                    while i < entries.count {
                        let j = min(i + step, entries.count)
                        out += await resolve(Array(entries[i ..< j]), at: offset + i, checked: checked)
                        i = j
                    }
                    return out
                }
            }
            // Batched sieve -> per-line confirmation. Long arrays say "yes"
            // loosely; a line they vouch for gets judged again on its own, and
            // only that answer is reported. Cost: +1 call per reported line.
            var out: [(pos: Int, score: Int, reason: String)] = []
            for i in entries.indices {
                let sc = ans.count == entries.count ? ans[i] : (i < ans.count ? ans[i] : 0)
                if sc >= threshold, entries.count > 1, options.confirm {
                    await guard_.confirm()
                    let solo = await resolve([entries[i]], at: offset + i, checked: true)
                    out += solo
                    continue
                }
                out.append((offset + i, sc, r.reason))
            }
            return out
        }

        var silent: [[(number: Int, text: String)]] = []
        var fileLive = false

        /// Print the lines of one judged window, and remember whether the window
        /// said anything at all.
        func reportWindow(_ judged: [(pos: Int, score: Int, reason: String)],
                          _ entries: [(number: Int, text: String)]) async -> Bool {
            if judged.contains(where: { $0.score > 0 }) { fileLive = true }
            var scores: [Int: Int] = [:]
            var reason = ""
            var quiet: [(line: Int, score: Int)] = []
            let hits = judged.compactMap { v -> Int? in
                let text = entries[v.pos].text
                guard text.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
                reason = v.reason
                if v.score >= threshold {
                    scores[v.pos + 1] = v.score
                    return v.pos + 1
                }
                if options.debug, v.score >= 1 { quiet.append((entries[v.pos].number, v.score)) }
                return nil
            }
            for (line, sc) in quiet {
                let why = judged.first { entries[$0.pos].number == line }?.reason ?? ""
                await sink.warn("[debug] \(spec.display):\(line): score \(sc), below threshold \(threshold) - \(why)")
            }
            let block = Block(
                fileID: spec.id,
                start: entries.first?.number ?? 1,
                lines: ArraySlice(entries.map(\.text))
            )
            let verdict = MatchVerdict(
                isMatch: !hits.isEmpty, lineNumbers: hits, quote: "",
                reason: reason, confidence: hits.isEmpty ? 0 : 2, note: ""
            )
            return await sink.report(verdict, block: block, display: spec.display, scores: scores)
        }

        for entries in chunks {
            if Task.isCancelled { break }
            if await sink.isDoneForFile(spec.id) { break }
            if entries.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            if let regex, plan != .lines, !entries.contains(where: { regexHit($0.text, regex) }) { continue }

            let judged = await resolve(entries, at: 0)
            if options.recallSweep, entries.count > options.matchedChunk {
                silent.append(entries)
            }
            if !(await reportWindow(judged, entries)) { break }
        }

        // Recall guard. Measured on the same 128 lines: arrays of 32 report 3
        // hits, of 16 -> 14, of 8 -> 16, of 4 -> 19. The model reads the head of
        // a long array and drifts to "no" down the tail, so the missed lines are
        // inside windows that already answered, not only in silent ones. Hence:
        // sweep the whole file again in pieces small enough to be read - but only
        // once the file has proved it is about something (any line scored > 0).
        // Unrelated files cost nothing extra, and lines already confirmed alone
        // come back from the verdict cache instead of the model.
        if options.recallSweep, fileLive, !silent.isEmpty, !Task.isCancelled {
            let step = options.debug ? 1 : options.matchedChunk
            let planned = silent.reduce(0) { $0 + ($1.count + step - 1) / step }
            FileHandle.standardError.write("fmgrep: recall guard: re-sweeping \(spec.display) in windows of \(step) (\(+planned) more calls)\n".data(using: .utf8)!)
            var extra = 0
            for window in silent {
                if await sink.isDoneForFile(spec.id) || Task.isCancelled { break }
                var i = 0
                while i < window.count {
                    let j = min(i + step, window.count)
                    let piece = Array(window[i ..< j])
                    extra += (piece.count + step - 1) / step
                    if !(await reportWindow(await resolve(piece, at: 0), piece)) { break }
                    i = j
                }
            }
            await guard_.resweep(windows: silent.count, calls: extra)
        }

        await dumpNotes()
        return
    }

    for (index, block) in blocks.enumerated() {
        if Task.isCancelled { return }
        if await sink.isDoneForFile(spec.id) { return }

        if let regex {
            let raw = blockRawText(block) as NSString
            if regex.firstMatch(in: raw as String, range: NSRange(location: 0, length: raw.length)) == nil {
                continue
            }
        }

        let rawVerdict: MatchVerdict
        await semaphore.wait()
        do {
            var instr = options.instructionsOverride ?? defaultInstructions
            if !matchTest.isEmpty {
                instr += "\nMatch rule compiled from the user's query - a line counts only if it clearly satisfies this rule, never merely because it touches an adjacent topic:\n" + matchTest
            }
            rawVerdict = try await evaluate(
                block: block,
                blockIndex: index + 1,
                blockCount: blocks.count,
                fileDisplay: spec.display,
                outline: outline,
                query: options.query,
                instructions: notes == nil ? instr : instr + "\n" + scratchpadGuidance,
                notes: notes
            )
        } catch {
            await semaphore.signal()
            if !Task.isCancelled, !(error is CancellationError) {
                await sink.warn("\(spec.display): block \(index + 1)/\(blocks.count): \(error)")
            }
            continue
        }

        // Verification pass: blank lines never qualify; each candidate line
        // gets a strict single-line relevance check (cheap prompt, much
        // more reliable for a 3B model than the block judgment was).
        var verdict = rawVerdict
        if verdict.isMatch {
            var kept: [Int] = []
            for local in verdict.lineNumbers where (1 ... block.lines.count).contains(local) {
                let text = String(block.lines[block.lines.startIndex + (local - 1)])
                if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                if options.verify {
                    let relevant = try? await verify(line: text, fileDisplay: spec.display, query: options.query)
                    if relevant == false { continue } // keep on model error
                }
                kept.append(local)
            }
            verdict.lineNumbers = kept
            if kept.isEmpty { verdict.isMatch = false }
        }
        await semaphore.signal()

        let keepGoing = await sink.report(verdict, block: block, display: spec.display)
        if !keepGoing { break }
    }
    await dumpNotes()
}

func runScan(options: Options, files: [FileSpec]) async -> Int32 {
    var options = options
    options.minConfidence = options.minConfidence ?? (options.engine == .blocks ? 1 : 2)

    // Planning pass. The user brings intent; the model supplies the vocabulary;
    // the exact matcher does the corpus reduction. Real cost = lines that
    // survive the filter, so estimates and downgrades reflect actual work.
    var pattern = options.prefilter
    var expanded: [String] = []
    // Model-guessed vocabulary is only ever a USER-CHOSEN shortcut (--expand):
    // where its tokens are right, plain grep already worked; where they are
    // wrong it silently amputates the recall this tool exists to provide.
    if options.engine != .blocks, options.prefilter == nil, options.expand == true {
        expanded = await expandQuery(options.query)
        if expanded.count >= 3 {
            pattern = expanded.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        } else {
            expanded = []
        }
    }
    var plan: [Int: FilePlan] = [:]
    var lineCalls = 0, runCalls = 0, zeroSkipFiles = 0
    if options.engine != .blocks {
        let planRe = pattern.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        for spec in files {
            guard let f = try? loadFile(spec, maxBytes: options.maxFileBytes), !f.lines.isEmpty else {
                plan[spec.id] = .skip
                continue
            }
            let runs = (f.lines.count + options.scoreLines - 1) / options.scoreLines
            if let planRe {
                let m = f.lines.reduce(into: 0) { acc, line in
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty, regexHit(line, planRe) { acc += 1 }
                }
                if m == 0 {
                    if f.lines.count <= options.sweepMaxLines {
                        plan[spec.id] = .runs
                        runCalls += runs
                    } else {
                        plan[spec.id] = .skip
                        zeroSkipFiles += 1
                    }
                } else if m <= options.maxLineCallsPerFile {
                    plan[spec.id] = .lines
                    lineCalls += m
                } else {
                    plan[spec.id] = .runs
                    runCalls += (m + options.matchedChunk - 1) / options.matchedChunk
                }
            } else {
                plan[spec.id] = .runs
                runCalls += runs
            }
        }
        let calls = lineCalls + runCalls
        if !expanded.isEmpty {
            FileHandle.standardError.write("fmgrep: prefilter keywords from the model: \(expanded.prefix(10).joined(separator: " | ")) ... (--no-expand for an exhaustive scan, -E to override)\n".data(using: .utf8)!)
        }
        if zeroSkipFiles > 0 {
            FileHandle.standardError.write("fmgrep: \(zeroSkipFiles) long files contained no prefilter keyword and were skipped (this is where semantic-only answers could hide)\n".data(using: .utf8)!)
        }
        if calls > 40_000, !options.engineExplicit {
            FileHandle.standardError.write("fmgrep: even after filtering ≈\(calls) calls (≈\(calls / 200)–\(calls / 100) min) - falling back to coarse windows + triage. Pass --line to insist.\n".data(using: .utf8)!)
            options.engine = .blocks
            plan = [:]
            options.scratchpad = options.scratchpad ?? false
        } else if calls > 300 {
            FileHandle.standardError.write("fmgrep: plan ≈\(lineCalls) single-line + \(runCalls) batched calls ≈\(max(1, calls / 200))–\(max(2, calls / 100)) min on-device\n".data(using: .utf8)!)
        }
    }
    if options.debug, options.engine != .blocks {
        options.engine = .line
    }
    let settled = options // freeze after downgrade/resolution so task closures capture an immutable copy
    let planDict = plan
    let patternStr = pattern
    dumpPrompts = settled.dumpPrompt
    let matchTest = await interpretQuery(settled.query)   // one call per scan
    if settled.debug {
        FileHandle.standardError.write("fmgrep: debug: engine=line threshold=\(settled.minConfidence ?? 2) prefilter=\(patternStr ?? "(none)")\n       rule: \(matchTest.isEmpty ? "(none)" : matchTest)\n       hits annotated with scores; score-1 suppressions go to stderr\n".data(using: .utf8)!)
    }
    let cache = VerdictCache()
    let guard_ = CollapseGuard()
    let semaphore = Semaphore(settled.jobs)
    let registry = TaskRegistry()
    let sink = Sink(options: settled, registry: registry)

    var tasks: [Task<Void, Never>] = []
    for spec in files {
        let task = Task(priority: .userInitiated) {
            await processFile(spec, options: settled, matchTest: matchTest, plan: planDict[spec.id], pattern: patternStr, cache: cache, guard_: guard_, semaphore: semaphore, sink: sink)
        }
        registry.register(task)
        tasks.append(task)
    }
    for t in tasks { _ = await t.value }

    if settled.engine != .blocks {
        let g = await guard_.report()
        if g.reswept > 0 {
            FileHandle.standardError.write("fmgrep: recall guard: \(g.reswept) windows in matched files re-swept smaller (+\(g.resweepCalls) calls); --no-recall-sweep to skip\n".data(using: .utf8)!)
        }
        if g.confirmed > 0 {
            FileHandle.standardError.write("fmgrep: \(g.confirmed) batched yes-answers re-judged alone (+\(g.confirmed) calls); --no-confirm to skip that check\n".data(using: .utf8)!)
        }
        if g.windows > 0 {
            FileHandle.standardError.write("fmgrep: collapse guard: \(g.windows) uniform batches re-judged finer (+\(g.extraCalls) calls) - batched answers the model could not read\n".data(using: .utf8)!)
        }
        let stats = await cache.report()
        if stats.reuse > 0 || settled.debug {
            FileHandle.standardError.write("fmgrep: verdict cache: \(stats.reuse) reused, \(stats.entries) unique lines judged\n".data(using: .utf8)!)
        }
    }
    let printedSomething = await sink.finish(files: files)
    let matched = await sink.anyFileMatched()
    let exit: Bool = options.invert ? (printedSomething || !matched) : matched
    return exit ? 0 : 1
}

// MARK: - Stats (dry run)

func reportStats(options: Options, files: [FileSpec]) {
    var totalLines = 0, totalBlocks = 0, skipped = 0
    for spec in files {
        guard let file = try? loadFile(spec, maxBytes: options.maxFileBytes) else { skipped += 1; continue }
        let blocks = makeBlocks(file, blockLines: options.blockLines, blockChars: options.blockChars, snapToSymbols: options.symbols)
        totalLines += file.lines.count
        totalBlocks += blocks.count
        print("\(spec.display): \(file.lines.count) lines, \(blocks.count) blocks"
            + (file.symbols.isEmpty ? "" : ", \(file.symbols.count) symbols"))
    }
    let estTokens = totalBlocks * (options.blockChars / 3)
    print("plan: \(files.count) files, \(totalLines) lines, \(totalBlocks) blocks"
        + (skipped > 0 ? ", \(skipped) skipped (unreadable or too large)" : ""))
    if options.engine == .blocks {
        print("engine: per-block — ≈\(totalBlocks) model calls, est. prompt tokens ≈\(estTokens)")
    } else {
        let runs = options.engine == .line ? totalLines : totalLines / options.scoreLines + 1
        print("engine: \(options.engine == .line ? "per-line" : "line-score ×\(options.scoreLines)") — ≈\(runs) model calls for \(totalLines) lines")
    }
    if options.prefilter != nil {
        print("note: blocks that miss the -E prefilter are skipped before the model sees them")
    }
}
