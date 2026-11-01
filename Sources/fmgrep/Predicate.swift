import Foundation

/// Compiles "bigger than 4 KiB but not a page", which the 3B model cannot
/// evaluate, into a Python expression it *can* write - then evaluates that
/// expression over every line in a sandboxed `python3` process.
///
/// The division of labour is the whole point. Natural language to predicate is
/// a translation task, and translation is what the model is for. Comparing the
/// result against the numbers in a file is arithmetic, and the model is
/// measurably incapable of arithmetic: asked which of five lines had a port
/// above 100000 it returned none, and asked which line contained the word
/// `alpha` it pointed at one that did not and said it did.
///
/// Safety, because this is model-authored code on the user's machine:
///   - the expression is parsed with `ast` and walked before anything runs; a
///     node, name, attribute or string outside the allowlist aborts the whole
///     feature (exit 3), and the failure is reported rather than retried loosely
///   - it is evaluated with `__builtins__` emptied, so no `open`, `exec`,
///     `__import__` or dunder path exists at runtime even if parsing were fooled
///   - `python3 -I -S -E` runs isolated: no user site, no environment, no startup
///     files; it reads only the files it is pointed at and writes only line ids
///   - the expression is ALWAYS printed on stderr, so the search is auditable -
///     nobody has to guess why a line matched
actor PredicateIndex {
    private var hits: [Int: Set<Int>] = [:]
    private(set) var total = 0
    func add(file: Int, line: Int) {
        hits[file, default: []].insert(line)
        total += 1
    }
    func lines(_ file: Int) -> Set<Int> { hits[file] ?? [] }
    func count(_ file: Int) -> Int { (hits[file] ?? []).count }
    var allFiles: Int { hits.count }
}

enum PredicateEngine {
    /// The names the generated expression may see. Numbers are pre-extracted
    /// because the point is that Python does the parsing, not the model.
    static let harness = #"""
import ast, sys, re, io

expr, manifest = sys.argv[1], sys.argv[2]
NUM_OK = {'num', 'nums', 'txt', 'raw', 'line', 'words'}
LISTCOMP = (ast.ListComp,)
FN_OK = {'len', 'abs', 'any', 'all', 'min', 'max', 'round', 'sum', 'bool', 'int', 'float',
         'match', 'wordset'}
ATTR_OK = {'startswith', 'endswith', 'lower', 'upper', 'strip', 'isdigit', 'split', 'replace',
           'count', 'find', 'lstrip', 'rstrip', 'removeprefix', 'removesuffix'}
NODES = (ast.Expression, ast.BoolOp, ast.UnaryOp, ast.BinOp, ast.Compare, ast.Call, ast.Name,
         ast.Load, ast.Constant, ast.And, ast.Or, ast.Not, ast.In, ast.NotIn, ast.Is, ast.IsNot,
         ast.Lt, ast.LtE, ast.Gt, ast.GtE, ast.Eq, ast.NotEq, ast.Add, ast.Sub, ast.Mult, ast.Div,
         ast.Mod, ast.FloorDiv, ast.Pow, ast.List, ast.Tuple, ast.Set, ast.Attribute, ast.IfExp,
         ast.USub, ast.UAdd, ast.comprehension, ast.keyword, ast.Store)
# A generator expression is allowed because `any(v > X for v in nums)` is the
# natural way to test several numbers on one line. Comprehension is the only
# looping construct permitted, and it can only range over the names above - the
# point of the walk is that no NAME, attribute or call outside the allowlist can
# appear anywhere, including inside it.
NODES = NODES + (ast.GeneratorExp, ast.ListComp)

try:
    tree = ast.parse(expr, mode='eval')
except SyntaxError as e:
    sys.stderr.write('syntax: %s\n' % e)
    raise SystemExit(3)

# Two passes: a comprehension's variable is bound in Store context but read in
# Load context inside its own body, so the binders must be collected before the
# reads can be judged. They are safe to allow because a comprehension can only
# iterate over expressions the checks below have already accepted.
BOUND = set()
for n in ast.walk(tree):
    if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store):
        BOUND.add(n.id)

for n in ast.walk(tree):
    if not isinstance(n, NODES):
        sys.stderr.write('node %s\n' % type(n).__name__)
        raise SystemExit(3)
    if isinstance(n, ast.Name) and n.id not in NUM_OK | FN_OK | BOUND:
        sys.stderr.write('name %s\n' % n.id)
        raise SystemExit(3)
    if isinstance(n, ast.Attribute) and n.attr not in ATTR_OK:
        sys.stderr.write('attr %s\n' % n.attr)
        raise SystemExit(3)
    if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr not in ATTR_OK:
        sys.stderr.write('method %s\n' % n.func.attr)
        raise SystemExit(3)
    if isinstance(n, ast.Constant) and isinstance(n.value, str) and len(n.value) > 200:
        sys.stderr.write('string too long\n')
        raise SystemExit(3)
    if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)) and abs(n.value) > 1e18:
        sys.stderr.write('constant out of range\n')
        raise SystemExit(3)

code = compile(tree, '<predicate>', 'eval')
ENV = {'__builtins__': {}}
import re as _re
_compiled = {}
def match(pattern, txt):
    rx = _compiled.get(pattern)
    if rx is None:
        if len(pattern) > 400:
            raise ValueError('pattern too long')
        rx = _compiled[pattern] = _re.compile(pattern)
    return rx.search(txt) is not None


def wordset(txt):
    return [w.strip(" \t,;:()[]{}'\"").lower() for w in txt.split()]

SAFE = {'len': len, 'abs': abs, 'any': any, 'all': all, 'min': min, 'max': max, 'round': round,
        'sum': sum, 'bool': bool, 'int': int, 'float': float, 'match': match,
        'wordset': wordset}
NUM = re.compile(r'(?<![A-Za-z0-9_.])\d[\d,]*(?:\.\d+)?(?![A-Za-z0-9_])')



out = sys.stdout
for entry in io.open(manifest, encoding='utf-8', errors='replace'):
    entry = entry.rstrip('\n')
    if '\t' not in entry:
        continue
    fid, path = entry.split('\t', 1)
    try:
        with io.open(path, encoding='utf-8', errors='replace') as fh:
            text = fh.read()
    except Exception:
        continue
    for i, txt in enumerate(text.split('\n'), 1):
        if len(txt) > 4000:
            txt = txt[:4000]
        nums = []
        for m in NUM.finditer(txt):
            try:
                nums.append(float(m.group().replace(',', '')))
            except ValueError:
                pass
        loc = dict(SAFE)
        loc.update({'num': nums[0] if nums else None, 'nums': nums, 'txt': txt, 'raw': txt,
                    'line': i, 'words': txt.split(), 'wordset': wordset(txt)})
        try:
            if eval(code, ENV, loc):
                out.write('%s\t%d\n' % (fid, i))
        except Exception:
            pass
out.flush()
"""#

    /// Lines in the query that make a predicate worth compiling at all: digits or
    /// a comparison word. Otherwise the answer is pure meaning and the model is
    /// the right tool, so this costs zero calls.
    static func worthCompiling(_ query: String) -> Bool {
        let q = query.lowercased()
        if q.contains(where: \.isNumber) { return true }
        for word in ["above", "below", "over", "under", "than", "between", "least", "most",
                     "longer", "shorter", "bigger", "larger", "smaller", "greater", "fewer",
                     "more", "less", "older", "newer", "faster", "slower", "exceed"]
        where q.contains(word) { return true }
        return false
    }

    static func python3() -> String? {
        for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        return nil
    }

    /// Turns the model's structured checks into the expression python runs.
    /// The model never writes code - only field/op/value slots - so what gets
    /// executed is assembled here, from a table, and cannot contain a name or
    /// call that this file did not put there. The ast walk stays as a second
    /// belt: it is what proves the renderer behaved, not the only defence.
    /// Turns the model's structured checks into the expression python runs.
    /// The model never writes code - only field/op/value slots - so everything
    /// that gets executed is assembled here, from a table, and cannot contain a
    /// name or call that this file did not put there. The ast walk stays as the
    /// second belt: it is what proves the renderer behaved.
    /// Every value in the condition must be a piece of the user's own query, or
    /// this returns nil. Without that rule the feature would be a vocabulary
    /// filter with a compiler attached: asked "where are objects handed back",
    /// the model happily writes `'dealloc' in txt`, and a guess becomes a hard
    /// gate that hides every line expressing the idea in other words. Numbers are
    /// checked digit-wise for the same reason.
    static func render(_ tests: [PredicateTest], combine: String, derivedFrom query: String) -> String? {
        let q = query.lowercased()
        func derived(_ v: String) -> Bool {
            let t = v.trimmingCharacters(in: .whitespaces).lowercased()
            guard !t.isEmpty else { return false }
            if t.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) {
                return q.contains(t.replacingOccurrences(of: ",", with: ""))
            }
            return q.contains(t)
        }
        func lit(_ v: String) -> String {
            "'" + v.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n") + "'"
        }
        func number(_ v: String) -> Double? { Double(v.replacingOccurrences(of: ",", with: "")) }
        func quant(_ every: Bool) -> String { every ? "all" : "any" }

        var parts: [String] = []
        for t in tests {
            let op = t.op.lowercased()
            guard derived(t.value), op != "none" || t.value.isEmpty else { return nil }
            if op == "between", !derived(t.value2) { return nil }
            switch (t.field.lowercased(), op) {
            case (_, "none"):
                parts.append("nums == []")
            case ("line", "between"):
                guard let a = number(t.value), let b = number(t.value2) else { return nil }
                parts.append("\(min(a, b)) <= line <= \(max(a, b))")
            case ("line", _):
                guard let a = number(t.value) else { return nil }
                parts.append("line \(PredicateEngine.cmp(op, default: "eq")) \(a)")
            case ("num", "between"):
                guard let a = number(t.value), let b = number(t.value2) else { return nil }
                parts.append("(num is not None and \(min(a, b)) <= num <= \(max(a, b)))")
            case ("num", _):
                guard let a = number(t.value) else { return nil }
                parts.append("(num is not None and num \(PredicateEngine.cmp(op, default: "gt")) \(a))")
            case ("nums", "between"):
                guard let a = number(t.value), let b = number(t.value2) else { return nil }
                parts.append("\(quant(t.every))(\(min(a, b)) <= v <= \(max(a, b)) for v in nums)")
            case ("nums", _):
                guard let a = number(t.value) else { return nil }
                parts.append("\(quant(t.every))(v \(PredicateEngine.cmp(op, default: "gt")) \(a) for v in nums)")
            case ("txt", "contains"):
                parts.append("(\(lit(t.value.lowercased())) in txt.lower())")
            case ("txt", "startswith"):
                parts.append("txt.strip().lower().startswith(\(lit(t.value.lowercased())))")
            case ("txt", "match"):
                parts.append("match(\(lit(t.value)), txt)")
            case ("words", _), ("txt", "word"):
                parts.append("(\(lit(t.value.lowercased())) in wordset(txt))")
            default:
                return nil
            }
        }
        guard !parts.isEmpty else { return nil }
        let expr = parts.joined(separator: combine.lowercased() == "or" ? " or " : " and ")
        return expr.count > 2000 ? nil : expr
    }

    static func cmp(_ op: String, default fallback: String) -> String {
        switch op {
        case "gt", "greater", "above", "over", "more": return ">"
        case "ge", "atleast": return ">="
        case "lt", "less", "below", "under", "fewer": return "<"
        case "le", "atmost": return "<="
        case "eq", "is", "equal": return "=="
        case "ne", "not": return "!="
        default: return fallback == "lt" ? "<" : ">"
        }
    }

    struct Failure: Error { let why: String }

    /// Runs `expr` over every line of `files`, filling `index`.
    /// Returns the rejection reason when the expression was not acceptable.
    static func evaluate(expr: String, files: [(id: Int, path: String)],
                         into index: PredicateIndex, timeout: TimeInterval) async -> String? {
        guard let python = python3() else { return "python3 not found" }
        let readable = files.filter { !$0.path.isEmpty }
        guard !readable.isEmpty else { return nil }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmgrep-predicate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestURL = dir.appendingPathComponent("manifest.tsv")
        var manifest = ""
        for f in readable { manifest += "\(f.id)\t" + f.path.replacingOccurrences(of: "\t", with: " ") + "\n" }
        do { try manifest.write(to: manifestURL, atomically: true, encoding: .utf8) }
        catch { return "could not write the file list" }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        // -c takes the program; what follows becomes sys.argv[1:]
        proc.arguments = ["-I", "-S", "-E", "-c", harness, expr, manifestURL.path]
        // -I/-S/-E already ignore the environment; an empty one removes the rest.
        proc.environment = ["PATH": "/usr/bin:/bin"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        var killed = false
        proc.standardInput = FileHandle.nullDevice

        do { try proc.run() } catch { return "could not start python3: \(error)" }

        let started = Date()
        let reader = Task.detached { () -> String in
            let handle = outPipe.fileHandleForReading
            let data = handle.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        }
        while proc.isRunning {
            if Date().timeIntervalSince(started) > timeout {
                killed = true
                proc.terminate()
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let output = await reader.value
        let err = ((proc.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile())
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        try? FileManager.default.removeItem(at: dir)

        if killed { return "timed out after \(Int(timeout)) s" }
        if proc.terminationStatus != 0 {
            let reason = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? "python3 exited \(proc.terminationStatus)" : "rejected: \(reason)"
        }
        for line in output.split(separator: "\n") {
            guard let tab = line.lastIndex(of: "\t"),
                  let id = Int(line[line.startIndex ..< tab]),
                  let n = Int(line[line.index(after: tab)...]) else { continue }
            await index.add(file: id, line: n)
        }
        return nil
    }
}
