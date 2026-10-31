// Model — the Apple Foundation Models half of fmgrep.
//
// Each block of file text is judged with guided generation: the on-device
// model must return a structured verdict (does it match, which lines, why),
// which we then translate back into grep-style output.

import Foundation
import FoundationModels

@Generable
struct MatchVerdict {
    @Guide(description: "true if one or more lines in the block match the query")
    var isMatch: Bool
    @Guide(description: "the line numbers of the matching lines, taken from the numbers shown at the start of each line; empty if none")
    var lineNumbers: [Int]
    @Guide(description: "a short exact quote from the block that best answers the query; empty if none")
    var quote: String
    @Guide(description: "one short sentence explaining the verdict")
    var reason: String
    @Guide(description: "confidence that the block really matches the query: 0 = guessing, 1 = likely, 2 = certain")
    var confidence: Int
    @Guide(description: "one structural fact about the whole file (what names or regions it contains); never about the query topic, and the empty string if it would repeat an existing note")
    var note: String
}

@Generable
struct YesNo {
    @Guide(description: "true if showing the line would help answer the query")
    var yes: Bool
}

enum ModelError: Error, CustomStringConvertible {
    case unavailable(String)
    case generation(String)
    case contentFiltered(String)

    var description: String {
        switch self {
        case .unavailable(let why): return "Apple Foundation Model unavailable: \(why)"
        case .generation(let why): return "model request failed: \(why)"
        case .contentFiltered: return "refused by the model's content filter (try -E prefilter or --include filters)"
        }
    }
}

func requireAvailableModel() throws {
    switch SystemLanguageModel.default.availability {
    case .available:
        break
    case .unavailable(let reason):
        throw ModelError.unavailable("\(reason)")
    @unknown default:
        throw ModelError.unavailable("unknown reason")
    }
}

let defaultInstructions = """
You are the matching engine of fmgrep, a command-line tool that searches text \
and source files by meaning instead of pattern. You receive a natural-language \
query and ONE block of numbered lines from a file; you cannot see the rest of \
the file. Decide which lines match the query semantically: they express, \
implement, mention, or answer what the query asks for. Prefer precision over \
recall - do not mark lines that merely share words with the query but say \
something else, and never invent topical links that are not in the text. If no \
line clearly matches, return isMatch false with empty lineNumbers. Report your \
confidence honestly: use 0 unless the text really is about what was asked. \
The prompt may include structural context - where the block sits in the file, \
and the declarations the file contains - use it to understand what you are \
looking at. \
Return matching line numbers using the numbers printed at the start of each \
line, quote the strongest fragment, and explain briefly.
"""

/// Ask the model to judge one block. Creates a fresh session per call so the
/// conversation never grows; the KV cache in the runtime still dedupes the
/// shared instructions prefix.
func evaluate(
    block: Block,
    blockIndex: Int,
    blockCount: Int,
    fileDisplay: String,
    outline: String,
    query: String,
    instructions: String,
    notes: NotesBox?
) async throws -> MatchVerdict {
    let session = LanguageModelSession(instructions: Instructions(instructions))
    let preamble = notes?.preamble ?? ""
    let prompt = """
    \(preamble)Query: \(query)

    Block \(blockIndex) of \(blockCount) of file "\(fileDisplay)":
    \(block.location.isEmpty ? "" : "Location: \(block.location)\n")\(outline.isEmpty ? "" : "File outline: \(outline)\n")
    \(blockPromptText(block))\
    Which lines, if any, match the query?
    """

    // Retry once: on-device generation occasionally refuses and a re-roll of
    // the same prompt usually succeeds.
    var lastError: Error?
    for _ in 0 ..< 2 {
        do {
            let response = try await session.respond(
                to: prompt,
                generating: MatchVerdict.self,
                options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 600)
            )
            let verdict = response.content
            notes?.add(verdict.note)
            // If the model says "match" but points at no usable line, fall
            // back to locating its quote inside the block.
            if verdict.isMatch && !verdict.lineNumbers.contains(where: { (1 ... block.lines.count).contains($0) }) {
                var fixed = verdict
                fixed.lineNumbers = locate(quote: verdict.quote, in: block)
                if fixed.lineNumbers.isEmpty { fixed.lineNumbers = [1] }
                return fixed
            }
            return verdict
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Long-line files (dense ObjC...) can still outgrow the 8k-token
            // context after chunking; split and judge both halves instead.
            let message = "\((error as? LocalizedError)?.errorDescription ?? "") \(String(describing: error)) \(String(reflecting: error))"
            if message.localizedCaseInsensitiveContains("context size") || message.localizedCaseInsensitiveContains("8192"), block.lines.count > 4 {
                let mid = block.lines.count / 2
                let left = Block(fileID: block.fileID, start: block.start, lines: block.lines.prefix(mid), location: block.location)
                let right = Block(fileID: block.fileID, start: block.start + mid, lines: block.lines.suffix(block.lines.count - mid), location: block.location)
                let a = try await evaluate(block: left, blockIndex: blockIndex, blockCount: blockCount, fileDisplay: fileDisplay, outline: outline, query: query, instructions: instructions, notes: notes)
                let b = try await evaluate(block: right, blockIndex: blockIndex, blockCount: blockCount, fileDisplay: fileDisplay, outline: outline, query: query, instructions: instructions, notes: notes)
                return merge(a, b, leftSize: mid)
            }
            if isContentRefusal(error) {
                throw ModelError.contentFiltered(message)
            }
            lastError = error
        }
    }
    throw ModelError.generation("\(lastError.map { String(describing: $0) } ?? "unknown")")
}

private func merge(_ a: MatchVerdict, _ b: MatchVerdict, leftSize: Int) -> MatchVerdict {
    var out = a.isMatch ? a : b
    let bLines = b.lineNumbers.map { $0 + leftSize }
    out.lineNumbers = a.lineNumbers + bLines
    if !a.isMatch && b.isMatch { out = b; out.lineNumbers = bLines }
    if a.isMatch && b.isMatch { out.confidence = max(a.confidence, b.confidence) }
    if !a.isMatch && !b.isMatch { out.isMatch = false; out.lineNumbers = [] }
    return out
}

/// Cheap strict re-check: does this ONE line, alone, answer the query?
/// Short prompts are far more reliable for a 3B model than block judging,
/// so we verify every candidate line before printing it.
func verify(line: String, fileDisplay: String, query: String) async throws -> Bool {
    let session = LanguageModelSession(
        instructions: Instructions("A search tool judged some file relevant to a query. You check individual candidate lines from that file. Answer yes when showing the user this line would help answer their query - a line defining, setting, or using the thing asked about qualifies, even if the line does not spell out every detail. Answer no for boilerplate, unrelated lines, or lines whose only link to the query is a shared common word.")
    )
    let trimmed = String(line.prefix(400))
    let response = try await session.respond(
        to: "User's query: \(query)\nLine from \(fileDisplay): \(trimmed)\nWould this line help answer the query? Yes or no.",
        generating: YesNo.self,
        options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 128)
    )
    return response.content.yes
}

@Generable
struct Relevance {
    @Guide(description: "true if the file could plausibly contain something answering the query")
    var relevant: Bool
    @Guide(description: "confidence in this judgment: 0 = guessing, 1 = likely, 2 = certain")
    var confidence: Int
    @Guide(description: "true when answering this query IN THIS FILE requires holding facts across its parts (its answer spans distant definitions and uses); false when each passage can be judged on its own")
    var needsNotes: Bool
}

@Generable
struct QueryTerms {
    @Guide(description: "8-24 tokens that lines matching the query would literally contain in real C/OS-kernel source: API and type names, macro stems, subsystem prefixes, common misspellings. Concrete grep-able words only, no English filler.")
    var terms: [String]
}

/// One call per scan: compile the user's intent into grep's language, so the
/// exact matcher does the corpus reduction and the model only ever judges
/// lines that could plausibly answer. This is the answer to "if I have to
/// give the keywords, why do I need you": the user shouldn't.
func expandQuery(_ query: String) async -> [String] {
    let session = LanguageModelSession(
        instructions: Instructions("A semantic search tool expands one natural-language query into the concrete tokens source files would contain where the query's topic lives. For a memory-allocation query in kernel C you might list: malloc, calloc, kalloc, vm_allocate, kmem, zalloc, mmap, alloc, free, dealloc, zone. Prefer identifier stems (substring match). 8 to 24 terms, no duplicates, nothing generic like code/value/thing.")
    )
    do {
        let r = try await session.respond(
            to: "Query: \(query)\nWhich tokens would a matching source line contain?",
            generating: QueryTerms.self,
            options: GenerationOptions(temperature: 0.4, maximumResponseTokens: 128)
        )
        let cleaned = r.content.terms
            .map { $0.trimmingCharacters(in: .alphanumerics.inverted) }
            .filter { $0.count >= 3 }
        return Array(Set(cleaned)).sorted().prefix(24).map { $0 }
    } catch {
        return []
    }
}

/// First gate for big corpora: judge the file itself from its path and
/// declarations, not its contents. One cheap call replaces N block calls when
/// the answer is a confident no; bias toward true when unsure. Also returns
/// the scratchpad decision so enabling notes never costs an extra call.
func triage(fileDisplay: String, outline: String, query: String) async throws -> Relevance {
    let session = LanguageModelSession(
        instructions: Instructions("A search tool decides whether to look INSIDE a file for content matching a natural-language query, and whether judging that file part by part would lose information it should remember across parts. You see only the file's path and its declarations, not its contents. Say relevant=true whenever any part of the file could plausibly answer the query; relevant=false confidently only when path and declarations clearly point elsewhere. When unsure, prefer relevant=true. For needsNotes answer true only when the query's answer in this file would need facts from one part of the file to judge another (e.g. names defined early, used late); questions answerable locally take false.")
    )
    let response = try await session.respond(
        to: "Query: \(query)\nFile: \(fileDisplay)\nDeclarations: \(outline.isEmpty ? "(none parsed)" : outline)\nMight the answer be in this file, and does judging it need cross-part notes?",
        generating: Relevance.self,
        options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 128)
    )
    return response.content
}

// One struct for all modes; the wire schema is built per call so the answers
// array is constrained to EXACTLY N elements (GenerationGuide.count). Without
// that bound the 3B model sometimes never closes the array - it decodes zeros
// until the context window fills, which looked like a hang. A response-token
// cap is the belt to that suspenders.
@Generable
struct LineAnswers {
    @Guide(description: "one answer per line shown, in order: 2 = that line clearly matches the query, 1 = possibly relevant, 0 = not")
    var answers: [Int]
    @Guide(description: "one short clause supporting the matches")
    var reason: String
    @Guide(description: "a structural fact about the file worth passing to later runs, or the empty string")
    var note: String
}

enum RunMode { case lean, noted, full }

struct RunResult {
    var answers: [Int]
    var reason: String
    var note: String
}

/// One call per scan: compile the vague user query into a strict per-line
/// test. Attacks the observed failure mode head-on - the 3B model drifting
/// "memory allocation" into "anything memory-ish", then collapsing into
/// answer-echo across the flat [Int] array.
func interpretQuery(_ query: String) async -> String {
    let session = LanguageModelSession(
        instructions: Instructions("You annotate one natural-language search query for a per-line judge. Output ONE sentence that: (a) names example vocabulary where the topic typically lives (real identifier shapes, API stems like kalloc, vm_allocate, malloc, free); (b) lists adjacent topics that should NOT count. NEVER phrase it as a requirement a line must satisfy, never invent compound conditions, never demand multiple tokens appear together - lines that answer the query without any listed word still pass.")
    )
    do {
        let r = try await session.respond(
            to: "Query: \(query)\nWrite the strict test:",
            options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 128)
        )
        return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return ""
    }
}

func isContentRefusal(_ error: Error) -> Bool {
    let message = "\((error as? LocalizedError)?.errorDescription ?? "") \(String(describing: error))"
    return message.localizedCaseInsensitiveContains("sensitive") || message.localizedCaseInsensitiveContains("unsafe")
}

/// Hide the model load cost behind walking/reading: fire at startup.
func prewarmModel() {
    Task.detached(priority: .utility) {
        try? await LanguageModelSession().prewarm()
    }
}

/// scoreRun with refusal tolerance: when the guardrail refuses a whole run
/// (it does this at boilerplate text, not just bad content), judge halves
/// instead. Returns answers aligned to `entries`.
func scoreEntries(
    _ entries: [(number: Int, text: String)],
    fileDisplay: String,
    totalLines: Int,
    query: String,
    instructions: String,
    mode: RunMode,
    notes: NotesBox?,
    scope: String = "",
    context: [(number: Int, text: String)] = []
) async throws -> RunResult {
    do {
        return try await scoreRun(
            lines: entries, fileDisplay: fileDisplay, totalLines: totalLines,
            query: query, instructions: instructions, mode: mode, notes: notes, scope: scope,
            context: context
        )
    } catch {
        // Any failure on a long run (guardrail refusal, context, truncated
        // decode) is worth a halved retry; short runs give up cleanly.
        if entries.count > 8, !(error is CancellationError), !Task.isCancelled {
            let mid = entries.count / 2
            let a = try await scoreEntries(Array(entries[..<mid]), fileDisplay: fileDisplay, totalLines: totalLines, query: query, instructions: instructions, mode: mode, notes: notes, scope: scope)
            let b = try await scoreEntries(Array(entries[mid...]), fileDisplay: fileDisplay, totalLines: totalLines, query: query, instructions: instructions, mode: mode, notes: notes, scope: scope)
            let mergeHitsFirst = a.answers.contains { $0 > 0 } ? a : b
            return RunResult(
                answers: a.answers + b.answers,
                reason: mergeHitsFirst.reason,
                note: a.note.isEmpty ? b.note : a.note
            )
        }
        throw error
    }
}

/// Descriptive system prompt shared by every judging call (KV prefix).
let defaultRunInstructions = """
You are the judging engine of fmgrep, a command-line search tool that finds \
lines in code and text by MEANING. The user gave a query. The tool shows you \
a consecutive run of numbered lines from a file, always in file order; you \
never see the whole file, but you are given the query and your position in \
the file. For EVERY line shown answer with one integer: 2 when the line IS \
the place the query is about - it performs, decides, or states the thing \
asked for; 1 when it merely belongs to the same mechanism without being \
where it happens; 0 otherwise - exactly one answer per line, in the order \
shown. Judge the line in your hand, never on what a neighbor probably says, \
and never on incidental word overlap. Never award 2 just because the line \
mentions a type, flag or variable connected to the topic, or because the \
file as a whole is about it: declarations, #include lines, one parameter of \
a multi-line signature, labels, and housekeeping that merely parks a value \
for later (clearing a pointer, setting a flag) score 1 at best unless the \
query is about that housekeeping itself. But an assignment that \
DECIDES the outcome the query asks about - the error, status or result a \
wait or allocation ends with - is the place it happens, and scores 2 even \
though it looks like a plain statement. Legal boilerplate, copyright notices and \
license banners are never matches unless they state the query's technical \
concept.
"""

/// Set from `--dump-prompt`: writes the exact text handed to the model, for
/// the lines that reach it, so judging behaviour can be argued about from the
/// real input instead of from what the source appears to build.
nonisolated(unsafe) var dumpPrompts = false

/// Extra instruction tails per run mode.
let notedRunGuidance = """
You must also append one note: a structural fact about the file (what it is, \
which regions hold what, naming conventions) that later runs will find \
genuinely useful - never an opinion about what matched, and the empty string \
if nothing new.
"""
let annotatedRunGuidance = notedRunGuidance + " Keep reason to one short clause supporting the matches."

@Generable
struct Selection {
    @Guide(description: "the numbers of the listed lines that really answer the query, taken from the numbers shown at the start of each line; leave empty if none of them do")
    var keep: [Int]
    @Guide(description: "one short clause naming what was dropped and why")
    var reason: String
}

/// A cheap first pass flags generously - independent 0/1/2 judging has no way
/// to notice that thirty lines in one function all got a 2. This puts the
/// candidates in front of the model together and asks which ones ARE the
/// answer, which is a comparison the per-line call structurally cannot make.
let selectionInstructions = """
You are the final gate of fmgrep, a semantic search tool. A cheap first pass \
flagged the lines below as candidates for a query; it flags generously, so some \
of them are only next to the topic instead of answers to it. Keep every line \
that is itself a place the query is about, and drop the rest, under two rules.
(1) A search returns ALL the places, so ten lines that each satisfy the query \
are ten answers - never drop one because another candidate says the same thing \
in the same function, that is the result rather than a duplicate. (2) Judge \
each line against the query on its own; comparing candidates with each other is \
not your job. Drop a line only when it is not itself a place where the query's \
thing happens: a declaration, a comment, housekeeping that parks a value for \
later, or a check whose subject is a different topic. (3) An assignment that
DECIDES the outcome the query asks about - the error, status or result a wait
or allocation ends with - is an answer even though it looks like a plain
statement; keeping one such line does not license dropping the others.
"""

func selectBest(
    _ entries: [(number: Int, text: String)],
    fileDisplay: String,
    query: String,
    scope: String
) async throws -> Selection {
    var body = ""
    for e in entries { body += "\(e.number): \(String(e.text.prefix(600)))\n" }
    let prompt = """
    Query: \(query)
    Candidates from \(fileDisplay)\(scope.isEmpty ? "" : " (\(scope))"), in file order:

    \(body)
    Which of these lines ARE the answer to the query? List their numbers; drop the ones that are only adjacent to the topic.
    """
    let session = LanguageModelSession(instructions: Instructions(selectionInstructions))
    let response = try await session.respond(
        to: prompt,
        generating: Selection.self,
        options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 160 + entries.count * 3)
    )
    return response.content
}

/// Judge a run of lines in one call. answers[i] corresponds to lines[i];
/// a short answer array is padded with 0 (conservative).
func scoreRun(
    lines: [(number: Int, text: String)],
    fileDisplay: String,
    totalLines: Int,
    query: String,
    instructions: String,
    mode: RunMode,
    notes: NotesBox?,
    scope: String = "",
    context: [(number: Int, text: String)] = []
) async throws -> RunResult {
    let tail = (mode == .lean || notes == nil) ? "" : mode == .noted ? "\n" + notedRunGuidance : "\n" + annotatedRunGuidance
    let session = LanguageModelSession(instructions: Instructions(instructions + tail))
    let preamble = notes?.preamble ?? ""
    // IMPORTANT: lines are numbered 1..N *within the run* so the k-th answer
    // always corresponds to the line labeled k. Showing file-absolute numbers
    // here caused positional drift (answers landing on the wrong lines).
    var body = ""
    if lines.count == 1, !context.isEmpty {
        // A lone line cannot show what it does: `error = EWOULDBLOCK;` is an
        // answer only because the line above it says `case THREAD_TIMED_OUT:`.
        // Surroundings are offered as read-only context, kept out of the
        // numbered answer list so the decoding contract stays one integer.
        body += "Line to judge:\n1: \(String(lines[0].text.prefix(1000)))\n\n"
        body += "Its surroundings - context only, never answer for these:\n"
        for c in context {
            body += "\(c.number): \(String(c.text.prefix(400)))\n"
        }
    } else {
        for (i, entry) in lines.enumerated() {
            body += "\(i + 1): \(String(entry.text.prefix(1000)))\n"
        }
    }
    let where_ = scope.isEmpty ? "" : " (\(scope))"
    let prompt = """
    \(preamble)Query: \(query)
    File: \(fileDisplay) — \(lines.count) consecutive lines starting at line \(lines.first?.number ?? 1) of \(totalLines)\(where_)

    \(body)
    Answer \(lines.count) time\(lines.count == 1 ? "" : "s"), in order: entry k judges the line numbered k. 2 = that line IS where the query's thing happens or is decided, 1 = same mechanism but not where it happens, 0 = not about it.\(lines.count == 1 && !context.isEmpty ? " Use the surroundings to understand line 1; report on line 1 alone." : "")
    """
    if dumpPrompts {
        let dump = """
        --- fmgrep: model call (mode=\(mode), lines=\(lines.count), temperature=0.0) ---
        [INSTRUCTIONS]
        \(instructions + tail)

        [USER]
        \(prompt)

        """
        FileHandle.standardError.write(dump.data(using: .utf8)!)
    }
    let n = lines.count
    var properties: [GenerationSchema.Property] = [
        .init(name: "answers",
              description: "entry k is the verdict for the line numbered k: 2 = that line clearly matches the query, 1 = possibly relevant, 0 = not",
              type: [Int].self, guides: [.count(n)]),
    ]
    switch mode {
    case .lean: break
    case .noted:
        properties.append(.init(name: "note",
                                description: "a structural fact about the file worth passing to later runs, or the empty string",
                                type: String.self))
    case .full:
        properties.append(.init(name: "reason", description: "one short clause supporting the matches", type: String.self))
        if notes != nil {
            properties.append(.init(name: "note",
                                    description: "a structural fact about the file worth passing to later runs, or the empty string",
                                    type: String.self))
        }
    }
    let schema = GenerationSchema(type: LineAnswers.self, properties: properties)
    let budget = n * 2 + (mode == .lean ? 48 : mode == .noted ? 144 : 224) + context.count * 4
    let response = try await session.respond(to: prompt, schema: schema,
                                            options: GenerationOptions(temperature: 0.0, maximumResponseTokens: budget))
    let content = response.content
    var r = RunResult(
        answers: (try? content.value([Int].self, forProperty: "answers")) ?? [],
        reason: (try? content.value(String.self, forProperty: "reason")) ?? "",
        note: (try? content.value(String.self, forProperty: "note")) ?? ""
    )
    pad(&r, to: n)
    notes?.add(r.note)
    return r
}

private func pad(_ r: inout RunResult, to count: Int) {
    if r.answers.count < count { r.answers += Array(repeating: 0, count: count - r.answers.count) }
    else if r.answers.count > count { r.answers = Array(r.answers.prefix(count)) }
}

/// Map a quoted fragment to the block-relative line numbers that contain it.
func locate(quote: String, in block: Block) -> [Int] {
    let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
    guard needle.count >= 3 else { return [] }
    var hits: [Int] = []
    for (i, line) in block.lines.enumerated() where line.localizedCaseInsensitiveContains(needle) {
        hits.append(i + 1)
    }
    if hits.isEmpty {
        // Try progressively shorter prefixes of the quote.
        var prefix = String(needle.prefix(max(8, needle.count / 2)))
        while prefix.count >= 6 && hits.isEmpty {
            for (i, line) in block.lines.enumerated() where line.localizedCaseInsensitiveContains(prefix) {
                hits.append(i + 1)
            }
            prefix = String(prefix.dropLast(prefix.count / 3))
        }
    }
    return hits
}
