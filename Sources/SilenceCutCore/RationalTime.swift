import Foundation

/// An exact rational time value in seconds, as used by FCPXML ("1001/30000s", "5s").
///
/// All timeline edits are computed with exact arithmetic so that every value we
/// write back stays on the frame grid Final Cut Pro expects.
public struct RationalTime: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let num: Int64
    public let den: Int64

    public static let zero = RationalTime(0, 1)

    public init(_ num: Int64, _ den: Int64 = 1) {
        self.init(wide: Int128(num), Int128(den))
    }

    init(wide num: Int128, _ den: Int128) {
        precondition(den != 0, "RationalTime denominator must not be zero")
        var n = num, d = den
        if d < 0 { n = -n; d = -d }
        let g = RationalTime.gcd(n < 0 ? -n : n, d)
        if g > 1 { n /= g; d /= g }
        // Values this large never occur in real projects; clamp rather than trap.
        if n > Int128(Int64.max) || n < Int128(Int64.min) || d > Int128(Int64.max) {
            let approx = Double(n) / Double(d)
            let scale: Int64 = 1_000_000
            self.num = Int64((approx * Double(scale)).rounded())
            self.den = scale
        } else {
            self.num = Int64(n)
            self.den = Int64(d)
        }
    }

    private static func gcd(_ a: Int128, _ b: Int128) -> Int128 {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }

    /// Parses an FCPXML time string: "N/Ds", "Ns" or a decimal such as "1.5s".
    public init?(fcpxml string: String?) {
        guard var s = string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasSuffix("s") { s.removeLast() }
        if let slash = s.firstIndex(of: "/") {
            guard let n = Int64(s[..<slash]), let d = Int64(s[s.index(after: slash)...]), d != 0 else { return nil }
            self.init(n, d)
        } else if let n = Int64(s) {
            self.init(n, 1)
        } else if let dot = s.firstIndex(of: "."), Double(s) != nil {
            let fraction = s[s.index(after: dot)...]
            let digits = min(fraction.count, 9)
            var den: Int64 = 1
            for _ in 0..<digits { den *= 10 }
            let value = (Double(s)! * Double(den)).rounded()
            self.init(Int64(value), den)
        } else {
            return nil
        }
    }

    public var seconds: Double { Double(num) / Double(den) }

    /// The string form written into FCPXML.
    public var fcpxmlString: String { den == 1 ? "\(num)s" : "\(num)/\(den)s" }
    public var description: String { fcpxmlString }

    public var isZero: Bool { num == 0 }

    public static func + (a: RationalTime, b: RationalTime) -> RationalTime {
        RationalTime(wide: Int128(a.num) * Int128(b.den) + Int128(b.num) * Int128(a.den), Int128(a.den) * Int128(b.den))
    }

    public static func - (a: RationalTime, b: RationalTime) -> RationalTime {
        RationalTime(wide: Int128(a.num) * Int128(b.den) - Int128(b.num) * Int128(a.den), Int128(a.den) * Int128(b.den))
    }

    public static func * (a: RationalTime, b: RationalTime) -> RationalTime {
        RationalTime(wide: Int128(a.num) * Int128(b.num), Int128(a.den) * Int128(b.den))
    }

    public static func / (a: RationalTime, b: RationalTime) -> RationalTime {
        precondition(b.num != 0, "division by zero RationalTime")
        return RationalTime(wide: Int128(a.num) * Int128(b.den), Int128(a.den) * Int128(b.num))
    }

    public static func < (a: RationalTime, b: RationalTime) -> Bool {
        Int128(a.num) * Int128(b.den) < Int128(b.num) * Int128(a.den)
    }

    public static func += (a: inout RationalTime, b: RationalTime) { a = a + b }
    public static func -= (a: inout RationalTime, b: RationalTime) { a = a - b }

    /// Largest multiple of `unit` that is <= self.
    public func roundedDown(toMultipleOf unit: RationalTime) -> RationalTime {
        unit * RationalTime(floorDivide(by: unit))
    }

    /// Smallest multiple of `unit` that is >= self.
    public func roundedUp(toMultipleOf unit: RationalTime) -> RationalTime {
        unit * RationalTime(ceilDivide(by: unit))
    }

    /// floor(self / unit)
    public func floorDivide(by unit: RationalTime) -> Int64 {
        let q = self / unit
        var f = q.num / q.den
        if q.num % q.den != 0 && q.num < 0 { f -= 1 }
        return f
    }

    /// ceil(self / unit)
    public func ceilDivide(by unit: RationalTime) -> Int64 {
        let q = self / unit
        var c = q.num / q.den
        if q.num % q.den != 0 && q.num > 0 { c += 1 }
        return c
    }
}

/// A half-open range of timeline time `[start, end)`.
public struct TimeRange: Hashable, Sendable, CustomStringConvertible {
    public var start: RationalTime
    public var end: RationalTime

    public init(start: RationalTime, end: RationalTime) {
        self.start = start
        self.end = end
    }

    public var duration: RationalTime { end - start }
    public var isEmpty: Bool { end <= start }
    public var description: String { "[\(start.seconds), \(end.seconds))" }

    public func contains(_ t: RationalTime) -> Bool { t >= start && t < end }

    public func intersection(_ other: TimeRange) -> TimeRange? {
        let s = max(start, other.start), e = min(end, other.end)
        return s < e ? TimeRange(start: s, end: e) : nil
    }
}

public enum TimeRanges {
    /// Sorts, drops empty ranges and merges overlapping or touching ones.
    public static func normalized(_ ranges: [TimeRange]) -> [TimeRange] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var out: [TimeRange] = []
        for r in sorted {
            if let last = out.last, r.start <= last.end {
                out[out.count - 1].end = max(last.end, r.end)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// `ranges` minus `holes`. Both inputs must be normalized.
    public static func subtract(_ holes: [TimeRange], from ranges: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        var h = 0
        for r in ranges {
            var cursor = r.start
            while h < holes.count && holes[h].end <= cursor { h += 1 }
            var k = h
            while k < holes.count && holes[k].start < r.end {
                if holes[k].start > cursor {
                    out.append(TimeRange(start: cursor, end: holes[k].start))
                }
                cursor = max(cursor, holes[k].end)
                k += 1
            }
            if cursor < r.end { out.append(TimeRange(start: cursor, end: r.end)) }
        }
        return out
    }

    /// The parts of `range` not covered by `holes` (normalized).
    public static func subtract(_ holes: [TimeRange], from range: TimeRange) -> [TimeRange] {
        subtract(holes, from: [range])
    }
}
