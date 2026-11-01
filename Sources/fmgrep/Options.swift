// Options — command-line parsing for fmgrep.

import Foundation

let fmgrepVersion = "0.1.0"

struct Options {
    var query: String = ""
    var paths: [String] = []

    // grep-ish flags
    var recursive = false
    var listFiles = false          // -l
    var count = false              // -c
    var invert = false             // -v (only with -l/-c)
    var quiet = false              // -q
    var lineNumbers = true         // -n (default on)
    var maxCount = 0               // 0 = unlimited
    var includeGlobs: [String] = []
    var excludeGlobs: [String] = [".git", "node_modules", ".build", ".svn", ".hg", "__pycache__", ".idea", "dist", "build", "*.noindex"]

    // model / engine knobs
    var jobs = 3                   // concurrent model requests
    var prefilter: String?         // regex a block must hit before the model sees it
    var blockLines = 80
    var blockChars = 3_000
    var maxFileBytes = 1_048_576
    var explain = false
    var json = false
    var stats = false              // plan only, never call the model
    var color = true
    var minConfidence: Int? = nil  // nil = auto: 2 for line engines, 1 for --blocks
    enum Engine { case score, line, blocks }
    // nil = auto: notes on for line-granular engines, off for --blocks
    var scratchpad: Bool?
    var engine: Engine = .line     // strict one-line-per-call default; --score batches 32/call, --blocks windows
    var engineExplicit = false     // set when --score/--line/--blocks given
    var scoreLines = 32
    var symbols = true             // structural context from the built-in symbol parser
    var triage = true              // per-file relevance gate on multi-block files
    var expand: Bool?              // model-generated prefilter keywords (auto for >3 files)
    var maxLineCallsPerFile = 48   // files with more regex hits get batched runs instead
    var sweepMaxLines = 400        // zero-hit files up to this size still get a batched sweep
    var matchedChunk = 8           // regex-matched lines judged per call (short arrays stay honest)
    var cache = true               // identical line text judged once per scan
    var confirm = true             // batched YES answers get re-judged alone
    var recallSweep = true         // silent windows in a live file get re-swept smaller
    var literalGate = true         // an exact value in the query gates candidate lines
    var numericGate = true         // a comparison in the query is evaluated in Swift
    var predicate = true           // the model writes the condition, python3 runs it
    var rerank = false             // opt-in comparative gate; measured to cost more recall
                                   // than precision on real code, so it is not the default
    var dumpPrompt = false         // print the exact prompt for each model call
    var top = 0                    // >0: buffer all hits, print best N by score
    var group = false              // print hits gathered under the declaration each lives in
    var verify = false             // opt-in per-line re-check; prunes noise but also true hits (3B model)
    var debug = false              // per-line WHY: forces 1 line/call, prints score+reason per hit,
                                   // and reports score-1 lines the threshold suppressed (stderr)
    var showScratchpad = false     // dump collected notes to stderr at the end
    var instructionsOverride: String?

    static func parse(_ argv: [String]) throws -> Options {
        var o = Options()
        var args = argv[...]
        var querySet = false

        func takeValue(for flag: String) throws -> String {
            guard let v = args.popFirst(), !v.hasPrefix("--") else { throw OptError("missing value for \(flag)") }
            return v
        }
        func takeInt(for flag: String) throws -> Int {
            let s = try takeValue(for: flag)
            guard let v = Int(s) else { throw OptError("\(flag): expected a number, got '\(s)'") }
            return v
        }
        func num(_ s: String, _ flag: String) throws -> Int {
            guard let v = Int(s) else { throw OptError("\(flag): expected a number, got '\(s)'") }
            return v
        }

        // Long options that take a value, with or without '='.
        func setLong(_ name: String, _ inline: String?) throws -> Bool {
            func value(_ flag: String) throws -> String {
                if let inline { return inline }
                return try takeValue(for: flag)
            }
            let v: String
            switch name {
            case "include": v = try value("--include"); o.includeGlobs.append(v)
            case "exclude", "exclude-dir": v = try value("--\(name)"); o.excludeGlobs.append(v)
            case "prefilter", "grep": v = try value("--prefilter"); o.prefilter = v
            case "block-lines": v = try value("--block-lines"); o.blockLines = try max(1, num(v, "--block-lines"))
            case "block-chars": v = try value("--block-chars"); o.blockChars = try max(200, num(v, "--block-chars"))
            case "max-file-bytes": v = try value("--max-file-bytes"); o.maxFileBytes = try max(1, num(v, "--max-file-bytes"))
            case "jobs": v = try value("--jobs"); o.jobs = try max(1, num(v, "--jobs"))
            case "run-lines": v = try value("--run-lines"); o.scoreLines = try max(1, num(v, "--run-lines"))
            case "matched-chunk": v = try value("--matched-chunk"); o.matchedChunk = try max(1, min(16, num(v, "--matched-chunk")))
            case "min-confidence": v = try value("--min-confidence"); o.minConfidence = try max(0, min(2, num(v, "--min-confidence")))
            case "max-count": v = try value("--max-count"); o.maxCount = try max(0, num(v, "--max-count"))
            case "top": v = try value("--top"); o.top = try max(0, num(v, "--top"))
            case "group": o.group = true
            case "instructions": v = try value("--instructions"); o.instructionsOverride = v
            default: return false
            }
            return true
        }

        while let a = args.popFirst() {
            if a == "--" { while let v = args.popFirst() { o.paths.append(v) }; break }

            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                let (name, value) = body.contains("=")
                    ? (String(body.prefix(while: { $0 != "=" })), String(body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[1]))
                    : (body, nil)

                if try setLong(name, value) { continue }
                switch name {
                case "recursive": o.recursive = true
                case "files-with-matches": o.listFiles = true
                case "count": o.count = true
                case "invert-match": o.invert = true
                case "quiet", "silent": o.quiet = true
                case "line-numbers": o.lineNumbers = true
                case "no-line-numbers": o.lineNumbers = false
                case "explain": o.explain = true
                case "verify": o.verify = true
                case "debug": o.debug = true
                case "no-cache": o.cache = false
                case "no-confirm": o.confirm = false
                case "dump-prompt": o.dumpPrompt = true
                case "no-recall-sweep": o.recallSweep = false
                case "rerank": o.rerank = true
                case "no-rerank": o.rerank = false
                case "no-literal": o.literalGate = false
                case "no-numeric": o.numericGate = false
                case "predicate": o.predicate = true
                case "no-predicate": o.predicate = false
                case "no-verify": o.verify = false
                case "scratchpad": o.scratchpad = true
                case "no-scratchpad": o.scratchpad = false
                case "blocks": o.engine = .blocks; o.engineExplicit = true
                case "line": o.engine = .line; o.engineExplicit = true
                case "score": o.engine = .score; o.engineExplicit = true
                case "symbols": o.symbols = true
                case "no-symbols": o.symbols = false
                case "triage": o.triage = true
                case "no-triage": o.triage = false
                case "expand": o.expand = true
                case "no-expand": o.expand = false
                case "show-scratchpad": o.showScratchpad = true
                case "json": o.json = true
                case "stats", "dry-run": o.stats = true
                case "color": o.color = true
                case "no-color": o.color = false
                case "help": printUsage(); throw OptError.exit(0)
                case "version": print("fmgrep \(fmgrepVersion) — semantic grep backed by Apple Foundation Models"); throw OptError.exit(0)
                default: throw OptError("unknown option \(a)")
                }
                continue
            }

            if a == "-" { o.paths.append("-"); continue }

            if a.hasPrefix("-") {
                // Bundled short options, e.g. -rn or -rlE 'foo'.
                for ch in a.dropFirst() {
                    switch ch {
                    case "r", "R": o.recursive = true
                    case "l": o.listFiles = true
                    case "c": o.count = true
                    case "v": o.invert = true
                    case "q": o.quiet = true
                    case "n": o.lineNumbers = true
                    case "N": o.lineNumbers = false
                    case "i", "s", "h": break // meaningless (or free) for semantic search
                    case "E": o.prefilter = try takeValue(for: "-E")
                    case "m": o.maxCount = max(0, try takeInt(for: "-m"))
                    case "j": o.jobs = max(1, try takeInt(for: "-j"))
                    case "I": o.instructionsOverride = try takeValue(for: "-I")
                    case "e": break // the QUERY simply follows as a positional
                    default: throw OptError("unknown option -\(ch)")
                    }
                }
                continue
            }

            if !querySet { o.query = a; querySet = true } else { o.paths.append(a) }
        }

        guard querySet, !o.query.isEmpty else { throw OptError("no QUERY given (see --help)") }
        if o.invert && !(o.listFiles || o.count) { throw OptError("-v is only meaningful with -l or -c") }
        if o.listFiles && o.count { o.count = false }
        return o
    }
}

enum OptError: Error {
    case message(String)
    case exit(Int32)

    init(_ message: String) { self = .message(message) }
}

func printUsage() {
    print("""
    Usage: fmgrep [OPTION]... QUERY [FILE]...

    Like grep, but QUERY is a natural-language description of what you are
    looking for, matched with Apple's on-device Foundation Model instead of a
    pattern. Reads standard input when no FILE is given (or FILE is '-').

    Search:
      -r, --recursive           descend into directories
          --include GLOB        only scan files whose name matches GLOB
          --exclude GLOB        skip paths matching GLOB (also --exclude-dir)
      -m, --max-count N         stop after N matching lines (0 = no limit)
      -E, --prefilter REGEX     only lines/blocks whose text matches REGEX are
                                sent to the model (saves time and tokens).
                                Guessing the keywords from the query is the
                                tool's whole job, so it never does that
                                silently; --expand asks the model for
                                candidate keywords and filters with them
                                (fast, but recall is capped by its guesses)
          --no-triage           disable the per-file gate that screens files
                                from path + declarations before reading blocks
                                (auto for multi-block files; on by default)

    Output:
      -l, --files-with-matches  print only file names
      -c, --count               print only match counts per file
      -v, --invert-match        list files with NO match (with -l or -c)
      -q, --quiet               exit 0 on the first match, print nothing
      -n / -N                   show/hide line numbers (default: shown)
          --explain             also print the model's one-line reason
          --debug               print WHY for every line: forces one judging call per line,
                                annotates each hit with its score and the model's reason,
                                and writes the score-1 lines the threshold dropped to stderr
                                (recall debugging). Slow by construction
          --group               print hits under the declaration they live in, with how
                                many of that region's lines were flagged. A semantic
                                search over a busy file returns dozens of lines that are
                                each defensible and collectively unreadable; this turns
                                "24 lines" into "4 of 9 exit paths in _sleep_continue"
                                followed by the lines themselves. Buffered, so output
                                arrives at the end rather than streaming.
          --top N               buffer every hit and print the best N ranked by
                                model confidence (use on big corpora; default
                                mode streams grep-style in completion order)
          --line (default)      one call per line - the only shape measured to
                                stay accurate on real C code; ~0.3 s/line, so
                                narrow big trees with -E/--include or triage
          --score               preview engine: 32 lines/call, answers as one
                                integer array. ~10x faster, but per-line arrays
                                collapse into correlated answers on dense code
                                (measured: flags every #include in a file as a
                                memory-allocation match). Trustworthy for prose,
                                not for kernels.
          --blocks              coarse windows, ~80 lines each (legacy)
          --predicate / --no-predicate
                                Ask the model to COMPILE the query into one Python
                                condition, then evaluate that condition over every
                                line in a sandboxed python3. The model can neither do
                                arithmetic nor verify that a string is present in a
                                line - it recognises the shape of such a question and
                                answers confidently - so it writes the test and never
                                judges it. The expression and a plain English reading
                                are printed on every run; anything it refuses to run
                                (imports, attribute access, a name outside
                                num/nums/txt/line/words) is reported, and the search
                                falls back to ordinary judging. Its `role` decides
                                how it is used: 'sole' means the condition IS the
                                question (a value or range lookup) and no line is
                                judged at all; 'part' means it only narrows what the
                                model reads. Cost: one call plus seconds of python.
          --no-numeric          ask the model to evaluate a comparison in the query
                                ("above 100000", "under 60", "between 100 and 200")
                                instead of computing it - the fallback for when
                                --predicate is off. Measured: on five lines with
                                three qualifying rows it returned none. A line whose
                                number satisfies the stated comparison is never
                                suppressed by the model's opinion of arithmetic.
          --no-literal          ignore an exact value in the query (see below)
                                By default, when your query names something exact -
                                100068, "ENXIO", 0xdeadbeef - the lines containing it
                                are judged one by one, because a 3B model cannot do
                                integer equality and will happily tell you that every
                                line of /etc/rpc runs on port 100068. Everything else
                                is still judged the normal way, so this only sharpens
                                where it applies; it never skips a file.
          --rerank              one extra call per window: show the model its own
                                candidates together and ask which ones ARE answers.
                                OFF by default because it was measured negative - on
                                kern_synch it traded 91% recall for 33%->50% precision
                                (F1 0.487 -> 0.476): the 3B model reads a list of true
                                parallel sites and keeps only one of them. --no-rerank
                                is the default behaviour; use --rerank when a file is
                                so saturated you would rather skim 7 lines than 37
          --no-recall-sweep     do not re-sweep windows that reported nothing
                                (default: a 32-line array that says "no" everywhere is
                                ambiguous - unread array or genuinely empty stretch -
                                so in a file that matched elsewhere it gets swept again
                                in windows of --matched-chunk; unrelated files cost zero)
          --dump-prompt         print the exact instructions + prompt behind every
                                model call to stderr (pair with -E to scope the dump)
          --no-confirm          trust batched YES answers without a per-line re-check
                                (default: every line a batch vouches for is judged again
                                alone, because long [Int] arrays are known to say yes
                                loosely - this is what turns a cheap sieve into a true answer)
          --no-cache            judge every line separately, even verbatim duplicates
      --json                emit one JSON object per match (JSONL)
          --no-color            disable ANSI colors

    Engine:
      -j, --jobs N              concurrent model requests (default 3)
          --matched-chunk N     batch size for filtered-dense files (1-16, default 8; 1 = never batch)
          --run-lines N         lines judged per call in the default engine
                                (default 32; lower = more calls, more focused)
          --min-confidence N    emit lines scored >= N (0-2; default: 2 in the
                                line engines - "clearly matches" only; 1 in
                                --blocks. Use 1 for maximum recall per line)
          --verify              re-check every candidate line with a second
                                model call before printing (cuts noise, but
                                the small model also prunes true hits, so it
                                is off by default)
          --no-verify           (default) print block verdicts directly
          --no-scratchpad       never carry notes across runs
          --scratchpad          always carry per-file structural notes (costs
                                ~2x per-call latency on the noted files)
          (default)             auto: the per-file triage call also answers
                                whether this file needs cross-part notes, so
                                memory turns on only where the task needs it,
                                at no extra call cost
          --show-scratchpad     print the notes collected per file to stderr
          --block-lines N       lines per block sent to the model (default 80)
          --block-chars N       character cap per block (default 3000)
          --max-file-bytes N    skip (silently) larger files (default 1048576)
          --stats               show the scan plan without calling the model
          --no-symbols          disable declaration-aligned blocks and the
                                location/outline context lines (on by default)
          --instructions TEXT   override the built-in system instructions

    Exit status: 0 match(es) found, 1 none, 2 trouble.
    """)
}
