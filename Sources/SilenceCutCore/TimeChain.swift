import Foundation

/// A retiming curve (`<timeMap>`): piecewise-linear map from retimed clip time to media time.
struct TimeMapFunction {
    let times: [Double]
    let values: [Double]

    init?(_ element: XMLElement?) {
        guard let element else { return nil }
        var points: [(Double, Double)] = []
        for pt in element.elements(forName: "timept") {
            guard let t = pt.time("time"), let v = pt.time("value") else { continue }
            points.append((t.seconds, v.seconds))
        }
        guard points.count >= 2 else { return nil }
        points.sort { $0.0 < $1.0 }
        // Drop duplicate times (hold frames keep the first value).
        var times: [Double] = [], values: [Double] = []
        for (t, v) in points where times.last.map({ t - $0 > 1e-9 }) ?? true {
            times.append(t)
            values.append(v)
        }
        guard times.count >= 2 else { return nil }
        self.times = times
        self.values = values
    }

    init(times: [Double], values: [Double]) {
        self.times = times
        self.values = values
    }

    private func segment(for t: Double) -> Int {
        var lo = 0, hi = times.count - 2
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func value(at t: Double) -> Double {
        let i = segment(for: t)
        let slope = (values[i + 1] - values[i]) / (times[i + 1] - times[i])
        return values[i] + (t - times[i]) * slope
    }

    /// Smallest interval of `t` covering every point where `value(t)` lies in `[lo, hi]`.
    func inverseHull(_ lo: Double, _ hi: Double) -> (Double, Double)? {
        var result: (Double, Double)?
        let last = times.count - 2
        for i in 0...last {
            // The end segments extend to infinity so clips reaching past the curve still map.
            let t0 = i == 0 ? -Double.infinity : times[i]
            let t1 = i == last ? Double.infinity : times[i + 1]
            let slope = (values[i + 1] - values[i]) / (times[i + 1] - times[i])
            var a: Double, b: Double
            if abs(slope) < 1e-12 {
                guard values[i] >= lo && values[i] <= hi else { continue }
                a = t0; b = t1
            } else {
                let x0 = times[i] + (lo - values[i]) / slope
                let x1 = times[i] + (hi - values[i]) / slope
                a = max(min(x0, x1), t0)
                b = min(max(x0, x1), t1)
                guard a <= b else { continue }
            }
            result = result.map { (min($0.0, a), max($0.1, b)) } ?? (a, b)
        }
        return result
    }
}

/// Maps timeline time to another time base through a series of offsets, rate changes and retiming curves.
struct TimeChain {
    enum Stage {
        /// y = scale * x + offset
        case affine(scale: Double, offset: Double)
        case map(TimeMapFunction)
    }

    private(set) var stages: [Stage] = []

    static let identity = TimeChain()

    func apply(_ x: Double) -> Double {
        var x = x
        for stage in stages {
            switch stage {
            case .affine(let scale, let offset): x = scale * x + offset
            case .map(let map): x = map.value(at: x)
            }
        }
        return x
    }

    func appendingAffine(scale: Double, offset: Double) -> TimeChain {
        var copy = self
        if case .affine(let s, let o)? = copy.stages.last {
            copy.stages[copy.stages.count - 1] = .affine(scale: s * scale, offset: o * scale + offset)
        } else if !(scale == 1 && offset == 0) {
            copy.stages.append(.affine(scale: scale, offset: offset))
        }
        return copy
    }

    func appendingMap(_ map: TimeMapFunction) -> TimeChain {
        var copy = self
        copy.stages.append(.map(map))
        return copy
    }

    /// The input interval that maps onto the output interval `[lo, hi]` (a covering hull).
    func inverseInterval(_ lo: Double, _ hi: Double) -> (Double, Double)? {
        var lo = lo, hi = hi
        for stage in stages.reversed() {
            switch stage {
            case .affine(let scale, let offset):
                guard scale != 0 else { return nil }
                let a = (lo - offset) / scale, b = (hi - offset) / scale
                lo = min(a, b); hi = max(a, b)
            case .map(let map):
                guard let r = map.inverseHull(lo, hi) else { return nil }
                lo = r.0; hi = r.1
            }
        }
        return (lo, hi)
    }
}
