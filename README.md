# fmgrep

`grep`, but the pattern is a sentence. `fmgrep` searches files by **meaning**
using Apple's on-device [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
framework — the ~3B model behind Apple Intelligence. No API key, no network,
no tokens billed; everything runs locally on your Mac.

```console
$ fmgrep -r "where do we throttle outgoing webhook requests" src/
src/net/limiter.py:41:    # token bucket for outbound webhooks, refills every 250ms
src/net/limiter.py:42:    webhook_rate_limiter = TokenBucket(capacity=64, refill_ms=250)
```

## Requirements

- macOS 26+ with Apple Intelligence enabled (the tool checks the model with
  `SystemLanguageModel.default.availability` and tells you if it can't run)
- Xcode 26+ to build (the `@Generable`/`@Guide` macro plugins ship with
  Xcode, not with bare Command Line Tools; the Makefile selects Xcode
  automatically when your `xcode-select` path doesn't have them)

## Install

```console
make release            # -> .build/release/fmgrep
sudo make install       # optional
make test               # smoke tests (a few seconds; calls the model)
```

## Usage

```
fmgrep [OPTION]... QUERY [FILE]...
```

Like grep: give it files (`-r` for directories) or pipe stdin, get
`file:line:text` output, exit status `0` = match, `1` = no match, `2` = error.

| Flag | Meaning |
|---|---|
| `-r` | recurse into directories |
| `-l`, `-c`, `-q`, `-m N` | list files / counts / quiet / max matches |
| `-v` | invert — with `-l`/`-c`, show files with **no** match |
| `--include` / `--exclude` GLOB | file filtering (skips `.git`, `node_modules`, … by default) |
| `-E REGEX`, `--prefilter` | **hybrid mode:** runs/blocks whose text misses REGEX are dropped before the model sees them, and `-E` also gates triage (path + declarations miss the regex ⇒ file skipped, no model call). `--no-triage` restores exhaustive `-E` |
| `--expand` | ask the model for candidate keywords and filter with them (opt-in: fast, recall capped by the guesses) |
| `--top N` | buffer every hit, print the best N ranked by model confidence — right mode for big corpora where streaming just prints whatever finished first |
| (default) | engine: 32 consecutive lines per call as a **sieve**, then every line the batch vouches for is judged again alone before it is printed — line-grade answers at roughly 1/10 the calls |
| `--line` | engine: strictly one call per line, nothing batched; the accuracy baseline, ~0.7–1 s/line |
| `--score` | engine: batched arrays with **no** per-line confirmation — cheap, and measurably looser (`--no-confirm` does the same on the default engine) |
| `--blocks` | engine: the coarse original (find relevant lines per ~80-line window); fastest, lowest precision |
| `--min-confidence 0..2` | emit lines the model scores ≥ N. Line engines score each line 0/1/2 (2 = clearly matches — **the default**, 1 = maybe); `--blocks` defaults to 1. Drop to 1 for maximum recall |
| `--no-symbols` | disable declaration-aligned blocks and the location/outline context lines (on by default; the cheap 80% of what an LSP knows — see below) |
| `--verify` | re-check every candidate line with a second model call (cuts noise, but the small model also prunes true hits; off by default) |
| `--no-confirm` | trust batched YES answers instead of re-judging each one alone (faster, prints more noise) |
| `--no-recall-sweep` | do not re-sweep a matched file's windows in smaller pieces (cheaper, loses the lines a long array stops reading) |
| `--dump-prompt` | print the exact instructions + prompt sent for every model call |
| `--matched-chunk N` | batch size for files where `-E` matches a lot of lines (1–16, default 8 — longer arrays are where the 3B model stops reading) |
| `--no-cache` | judge verbatim-duplicate lines separately instead of once per scan (the cache is why a license banner in 300 files costs one call) |
| `--debug` | force one call per line and print WHY: the score and the model's own reason under every hit, plus every score-1 line the threshold suppressed, to stderr |
| `--explain` | print the model's one-line reason under each hit |
| `--json` | JSONL output: file, line, text, quote, reason, query |
| `-j N` | concurrent model requests (default 3) |
| `--block-lines` / `--block-chars` | granularity of what the model reads (default 80 / 3000) |
| `--stats` | show the scan plan (blocks, estimated tokens) without calling the model |
| `-N`, `--no-color`, `--instructions TEXT` | line numbers off, color off, custom system prompt |

## Big corpora (whole kernels, monorepos)

Measured economics of the on-device model: a judging call costs ~0.3–1 s of
wall time *aggregate* — calls pipeline somewhat but the model serializes, so
`-j` buys much less than it looks like it should. Cost therefore = number of
calls, and the architecture fights for every call:

- **Never guess vocabulary for the user:** if you didn't pass `-E`, every
  candidate line still gets judged - a keyword list invented from the query
  is exactly what you were searching *because you didn't have*. (`--expand`
  opts into that shortcut: fast, but recall is capped by the guesses.)
- **Planner tiers (when `-E` is given):** <=48 hits per file: one call per
  line; many hits: matched lines batched in arrays of 8 (longer arrays
  measured to collapse); zero hits in short files: swept anyway; long
  files skipped with a count. Without `-E`: batched sweeps of everything,
  each batched yes confirmed per line, at an honest printed price.
- **Triage (automatic):** multi-run files screened by path + declarations.
- **Free filters before any model call:** lines with control or replacement
  characters, or more than 60% non-ASCII, are skipped as content-free; and
  syntax, never vocabulary, drops `goto` labels, brace-only lines and the
  comma-tails of multi-line signatures — those are lines that cannot be a
  place where something *happens*.
- **Collapse guard:** if a batch answers "hit" on 90%+ of a long window it
  did not read that window, so the window is re-judged in quarters. Reported
  on stderr as `collapse guard: N uniform batches re-judged finer`.
- **Recall guard (the mirror image):** a window's *silence* is equally
  ambiguous, so once a file has answered anywhere, its windows get re-swept in
  pieces small enough to be read. Files nothing in are never swept twice.
  `--dump-prompt` prints the exact instructions + prompt behind every call.
- **Degenerate-answer detector:** if a file answers yes on more than 8% of its
  lines, fmgrep says so on stderr instead of letting you scroll. On code that is
  genuinely about one subject (`_sleep()` for a query about giving up waiting)
  the model will do exactly that - 102 lines of 700, 22 of them real - and the
  honest move is to name it and point at `-E` / `--top N`.

## What the honesty layer is for

Measured on `bsd/kern/kern_synch.c` (the `_sleep()` implementation, so nearly
every line is *about* waiting — a worst case) with the query "places where the
code gives up waiting because the resource it needs is no longer available":

| configuration | lines printed |
|---|---|
| batched arrays only | 69 |
| + per-line confirmation of each batched yes | 41 |
| + tightened judging instructions | 55 |
| + structural filters (labels, signature tails) | 42 |

Window size turns out to be a *recall* dial, not just a cost dial — same 128
lines, same query, one run per sieve size:

| lines per judging call | hits | model calls |
|---|---|---|
| 32 | 3 | 10 |
| 16 | 14 | 24 |
| 8 | 16 | 34 |
| 4 | 19 | 51 |
| one line per call | ~per-line floor | 128 |

The model reads the head of a long array and drifts to "no" down the tail, so a
32-line window quietly loses two thirds of the answers. That is what the recall
guard buys back: files that answer nothing stay at 32 lines per call, files that
answer something get swept again in windows of 8 (17 hits here for ~44 calls).

The true sites are all there (`thread_should_abort()` at 239/294/304,
`case THREAD_TIMED_OUT:`, the `error = EINTR / ERESTART` returns), and so is
noise the model genuinely believes: `if (spinmutex) {`, `int flags;`,
`break;`. That is the honest shape of a 3B judge on topically saturated code —
`--debug` exists so you can see which of those you are looking at, and
`--min-confidence 1` trades this precision for recall. Judging was never the
weak link in these runs: the shipping layer (batching) was, which is why the
default now confirms before it prints.

Workflow that stays sane on a kernel tree:

```console
$ fmgrep -r --stats "memory allocation" ~/audit/xnu          # cost the plan
$ fmgrep "where memory objects are handed back" file.c        # scoped, minutes
$ grep -rlE 'vm_|kmem' src/ | xargs fmgrep "page reclaim paths"   # or pipe candidates
```

- **`--top N`:** relevance-ordered instead of completion-ordered — on a big
  tree streaming mode prints whichever runs finished first, which looks
  random and alphabetically biased.
- **Honest budgets:** if the line-grade engines would cost > ~1500 calls on
  your arguments and you didn't name an engine, fmgrep says so and downgrades
  to the coarse engine + triage automatically (hours instead of days). An
  explicit `--score`/`--line` is respected and just prints the estimate.
- Phrase the query as a question with a noun the code would use: "where is
  kernel memory allocated" beats bare "memory allocation".

## How it works

1. A planning pass walks the files (binaries/oversized skipped), expands the
   query to vocabulary terms if `-E` is absent, counts regex hits per file to
   assign each a judging tier, and hands files to workers. A built-in symbol parser (Swift/C/ObjC/Python/JS declaration
   patterns) extracts each file's declarations: that outline powers the
   per-file triage gate, and for the `--blocks` engine it also aligns window
   boundaries to declarations and stamps `Location:` context into prompts.
   (This is the useful slice of what an LSP `documentSymbol` would tell you;
   it sits behind one function, `Symbols.parseSymbols`, so a real language
   server can back it later.)
2. The default engine judges **runs of 32 consecutive lines** in a fresh
   `LanguageModelSession` at temperature 0 with guided generation - the
   reply is one boolean per line in order, so every printed hit is a
   line-granular decision, never a window-level guess:

   ```swift
   @Generable struct LineAnswers {
       var answers: [Bool]   // exactly one per shown line, in order
       var reason: String    // one short clause supporting the true answers
       var note: String      // scratchpad: a structural fact for later runs
   }
   ```

   (`--blocks` keeps the older window-level verdict instead:

   ```swift
   @Generable struct MatchVerdict {
       var isMatch: Bool          // does anything here answer the query?
       var lineNumbers: [Int]     // which lines, from the numbers shown
       var quote: String          // strongest exact fragment
       var reason: String         // one sentence why
       var confidence: Int        // 0 guessing / 1 likely / 2 certain
       var note: String           // scratchpad: one structural fact, see below
   }
   ```

3. Answers map back to global line numbers by position (the `--blocks` engine
   repairs wrong-or-empty line lists by locating the model's quote); hits
   stream out grep-style as runs finish, files in parallel, throttled by `-j`.

Output lines are always real lines of the file - `fmgrep` never prints text
that isn't in the source.

## Performance notes

- Cost = model calls. Warm single calls run ~0.3 s; the model pipelines
  modestly (measured: 6 concurrent ≈ 0.2 s/call aggregate, so `-j` is worth
  1.5-2x, not Nx). Score mode amortizes one call across 32 line judgments;
  triage removes whole files for one call each; `-E` skips runs at native
  regex speed.
- The instructions prefix is shared across sessions so the runtime's KV cache
  gives repeat scans a head start.

## Structural context: the LSP question, cheaply

fmgrep's remaining errors were structural, and structure is language-server
data. Rather than embed an LSP client (JSON-RPC, per-file didOpen, warmup
waits - wrong shape for a batch grep), the tool derives the parts that pay:

- **`documentSymbol` ≈ regex symbol map**: declaration lines per file, used
  to snap block boundaries and stamp every prompt with location + outline.
- Measured on a real mixed Swift/ObjC/Python repo: symbol context turned up
  **every** ground-truth definition for a "default socket path" query -
  including a `static NSString * const` an earlier config missed - recall
  jumped; precision is still model-bound.
- **`references`/`callHierarchy` are the part a real LSP adds**: model finds
  one `socketPath` definition → `sourcekit-lsp`/`clangd` enumerate all uses,
  including files no block verdict surfaced. Not implemented yet; it's the
  natural next layer and needs only the symbol backend to grow a client.

## Cross-block memory (scratchpad notes)

Blind windows mean the model can't use what it learned at line 40 when judging
line 900. `--scratchpad` gives it that memory: every judging call may carry one
structural `note` about the file; the harness keeps ≤4 deduped notes per file
and pastes them into later runs' prompts (`--show-scratchpad` dumps them).
**Opt-in, off by default: a note sentence doubles measured per-call latency**
(1.1 s answers-only vs 2.1 s noted) and the triage outline already supplies
most of the same facts for free. Worth enabling on long single files where the
one-line outline is too coarse to help.

Why a *field* and not a tool: the first implementation was a single
`remember(note)` tool via the framework's `Tool` protocol, letting the model
*choose* when to write. Measured on-device: the 3B model never called it
unprompted, and merely having the tool schema attached degraded verdicts. A
guided field is the same write channel with zero round-trips and schema
enforcement.

Measured trade-off: notes reliably improve recall across a file, but the
small model anchors on the preamble - with "defines a retry policy" loaded,
it starts calling unrelated boilerplate a match. Hence: OFF by default. Use
it on long single files where structure matters more than precision, and pair
with `--min-confidence 2` if it over-matches.

## Limitations

- The on-device model is small: expect grep-grade exactness only from `-E`.
  Semantic hits lean *name-driven*: near an allocator's family, declarations
  and includes get over-rated while the verb you actually asked about hides
  further down the file. Treat output as a ranked map of where to look, not
  an answer list. Piping to `head` SIGPIPEs the scan mid-stream (results cut
  off); redirect to a file.
- The score engine answers per line, but runs don't share transcripts -
  cross-run coherence comes from the scratchpad notes and triage outline only.
- A bare noun-phrase query ("memory allocation") is the model's weakest input
  shape; prefer "where/which/how" phrasings, and `-E` for keywords.
