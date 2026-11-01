import Foundation

/// A comparison the USER wrote into the query ("above 100000", "under 60s",
/// "between 100 and 200"), evaluated against numbers in the line by Swift.
///
/// This exists because the on-device model cannot do it. Measured, same corpus,
/// same session: asked "which service runs on a port above 100000" it returned
/// zero lines out of five, two of which qualify. Asked to match a word it
/// invented matches ("The line directly states 'alpha'" about a line containing
/// no `alpha`). Numbers and containment are not things it does - it recognises
/// the shape of a question that involves them and answers confidently. So the
/// part of a query that is a comparison is taken out of its hands, exactly like
/// the literal gate, and the semantic part is still its job.
struct NumericRule: Sendable {
    enum Op: Sendable { case gt, ge, lt, le, between }

    let op: Op
    let a: Double
    let b: Double          // upper bound, for .between
    let text: String       // how it will be reported back to the user

    /// Does this line contain a number satisfying the rule?
    ///
    /// Only standalone numeric literals count. The word-boundary requirement is
    /// the point: `kmem_100068` is an identifier that happens to end in digits,
    /// `10ms` is a duration, `(16ULL << 10)` is an expression whose value is not
    /// 10 - treating any of them as a quantity would be the model's confabulation
    /// with a regex bolted on. `cmsd\t\t100068` and `if (size > 4096)` are values.
    func matches(_ line: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"\b\d[\d,]*(?:\.\d+)?\b"#) else { return false }
        let ns = line as NSString
        for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let cleaned = ns.substring(with: m.range).replacingOccurrences(of: ",", with: "")
            guard let v = Double(cleaned) else { continue }
            switch op {
            case .gt: if v > a { return true }
            case .ge: if v >= a { return true }
            case .lt: if v < a { return true }
            case .le: if v <= a { return true }
            case .between: if v >= a, v <= b { return true }
            }
        }
        return false
    }

    /// Words that make a number a comparison rather than a key. Deliberately
    /// narrow: "above 100000" is arithmetic, "port 100068" is a lookup, and the
    /// two must not fight over the same digits.
    static func detect(_ query: String) -> NumericRule? {
        let q = query.lowercased()
        let num = #"([0-9][0-9,.]*)"#
        func value(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "")) }

        var re: NSRegularExpression?
        re = try? NSRegularExpression(pattern: #"(?:above|over|greater than|more than|bigger than|larger than|exceeding|>)\s*"# + num)
        if let re, let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
           let r = Range(m.range(at: 1), in: q), let v = value(String(q[r])) {
            return NumericRule(op: .gt, a: v, b: v, text: "> \(v.formatted(.number.grouping(.never)))")
        }
        re = try? NSRegularExpression(pattern: #"(?:at least|>=|=>)\s*"# + num)
        if let re, let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
           let r = Range(m.range(at: 1), in: q), let v = value(String(q[r])) {
            return NumericRule(op: .ge, a: v, b: v, text: ">= \(v.formatted(.number.grouping(.never)))")
        }
        re = try? NSRegularExpression(pattern: #"(?:below|under|less than|fewer than|smaller than|lower than|<)\s*"# + num)
        if let re, let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
           let r = Range(m.range(at: 1), in: q), let v = value(String(q[r])) {
            return NumericRule(op: .lt, a: v, b: v, text: "< \(v.formatted(.number.grouping(.never)))")
        }
        re = try? NSRegularExpression(pattern: #"(?:at most|<=|=<)\s*"# + num)
        if let re, let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
           let r = Range(m.range(at: 1), in: q), let v = value(String(q[r])) {
            return NumericRule(op: .le, a: v, b: v, text: "<= \(v.formatted(.number.grouping(.never)))")
        }
        re = try? NSRegularExpression(pattern: #"between\s*"# + num + #"\s*(?:and|-|–)\s*"# + num)
        if let re, let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
           let r1 = Range(m.range(at: 1), in: q), let r2 = Range(m.range(at: 2), in: q),
           let lo = value(String(q[r1])), let hi = value(String(q[r2])) {
            return NumericRule(op: .between, a: lo, b: hi,
                               text: "\(lo.formatted(.number.grouping(.never)))…\(hi.formatted(.number.grouping(.never)))")
        }
        return nil
    }
}
