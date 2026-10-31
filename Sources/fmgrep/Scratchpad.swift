// Scratchpad — context that survives between blocks of one file.
//
// First attempt was exactly what it looks like: a single `remember()` tool
// (Tool protocol, @Generable args) the model could call to write to a
// per-file scratchpad. Measured result: the 3B model NEVER fired the tool
// unprompted, and merely attaching the tool schema degraded verdicts. The
// equivalent that works is a guided-generation FIELD on the verdict — same
// write path, zero extra round-trips, schema-enforced. So the "tool" is a
// `note: String` on MatchVerdict; the harness stores notes per-file and
// pastes them into later prompts.
//
// Still experimental/OFF by default: notes improve cross-block recall, but
// the small model anchors hard on whatever is in the preamble - with a
// "retry policy" note loaded it started marking unrelated boilerplate as
// matches. Wording + dedup fixed the bad-note class (absence claims, echoed
// notes); the anchoring bias is intrinsic at this model size.

import Foundation

/// Thread-safe per-file list of notes.
final class NotesBox: @unchecked Sendable {
    static let maxNotes = 4
    static let maxNoteChars = 200

    private let lock = NSLock()
    private var notes: [String] = []

    func add(_ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "''", trimmed.lowercased() != "none", trimmed.lowercased() != "n/a" else { return }
        lock.lock()
        // Drop echoes of earlier notes: a note must add something. The model
        // tends to restate the preamble as its "new" observation.
        let tokens = Set(trimmed.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let isDuplicate = notes.contains { existing in
            let overlap = existing.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { tokens.contains($0) }.count
            let existingCount = existing.split(separator: " ").count
            return existingCount > 0 && Double(overlap) / Double(existingCount) > 0.6
        }
        if isDuplicate { lock.unlock(); return }
        notes.append(String(trimmed.prefix(Self.maxNoteChars)))
        if notes.count > Self.maxNotes { notes.removeFirst(notes.count - Self.maxNotes) }
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return notes
    }

    /// Prompt preamble for blocks after the first; empty when no notes yet.
    var preamble: String {
        let notes = snapshot()
        guard !notes.isEmpty else { return "" }
        return "Context about this file (background only - never raise a line's score because a note's topic appears; judge each line on what it itself says):\n"
            + notes.map { "- " + $0 }.joined(separator: "\n")
            + "\n\n"
    }
}

/// Appended to the system instructions when the scratchpad is active.
let scratchpadGuidance = """
The verdict has a note field. Record at most one STRUCTURAL fact that applies \
to the whole file and would help you judge other parts of it: names of \
classes, functions, or config it defines, or what kind of content each region \
holds. NEVER write a note about whether the query's topic was found or absent \
in the block you are judging - this block is a small window, and absence here \
says nothing about the file. Do not restate notes already listed above; use \
the empty string when you have nothing structurally new to record.
"""
