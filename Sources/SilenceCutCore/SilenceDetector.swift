import Foundation

public struct SilenceSettings: Codable, Equatable, Sendable {
    /// Work out the silence level from each recording's own background noise (recommended).
    public var autoThreshold: Bool = true
    /// Level in dBFS below which audio counts as silence when `autoThreshold` is off.
    public var thresholdDB: Double = -35
    /// Quiet stretches shorter than this are left alone. 0.85 s keeps the natural pauses a speaker
    /// makes mid-thought and removes the dead air around a lost train of thought or a retake.
    public var minimumSilence: Double = 0.85
    /// Quiet kept on each side of a cut, measured from where the audio crosses the silence level.
    /// 0.03 s is two frames at 60 fps: the cut lands while the word is still fading, which is
    /// how a tight manual edit looks.
    public var padding: Double = 0.03
    /// Shortest clip worth keeping. A stretch of sound shorter than this with dead air on both
    /// sides (a tap, a click or two, a sigh, a false start) is removed along with the silence
    /// instead of being left behind as a tiny clip.
    public var minimumSound: Double = 0.4
    public var scope: DetectionScope = .primaryStoryline

    public init() {}
    public static let `default` = SilenceSettings()

    public static let thresholdRange: ClosedRange<Double> = -70 ... -10
    public static let minimumSilenceRange: ClosedRange<Double> = 0.2 ... 3
    public static let paddingRange: ClosedRange<Double> = 0 ... 0.5
    public static let minimumSoundRange: ClosedRange<Double> = 0 ... 1
}

public struct DetectionResult {
    /// Timeline ranges to delete, on frame boundaries, sorted and non-overlapping.
    public let removals: [TimeRange]
    /// The silence level used for each media file (dBFS).
    public let thresholds: [(media: String, thresholdDB: Double)]
    /// A representative threshold for display (after clip volume).
    public let displayThresholdDB: Double
    public let originalDuration: RationalTime
    public let removedDuration: RationalTime

    public var cutCount: Int { removals.count }
    public var newDuration: RationalTime { originalDuration - removedDuration }
}

public enum SilenceDetector {
    /// Noise floor and voice level of one recording (dBFS), from its loudness distribution.
    static func levelStatistics(_ levels: [Float]) -> (floor: Float, peak: Float)? {
        let lowest: Float = -90, binWidth: Float = 0.5
        var histogram = [Int](repeating: 0, count: Int(-lowest / binWidth) + 1)
        var total = 0
        // Digital silence (gaps, muted stretches) says nothing about the room, so it is left out.
        for level in levels where level > lowest {
            let bin = min(histogram.count - 1, max(0, Int((min(level, 0) - lowest) / binWidth)))
            histogram[bin] += 1
            total += 1
        }
        guard total >= 20 else { return nil }
        func percentile(_ p: Double) -> Float {
            let target = Int((Double(total) * p).rounded(.up))
            var seen = 0
            for (bin, count) in histogram.enumerated() {
                seen += count
                if seen >= max(1, target) { return lowest + (Float(bin) + 0.5) * binWidth }
            }
            return 0
        }
        return (percentile(0.02), percentile(0.99))
    }

    /// Picks a silence level for one recording from its own loudness distribution.
    ///
    /// Speech recordings have two clusters of levels: room tone and voice. The threshold sits
    /// between them — midway, but never closer than 24 dB to the loud parts (so quiet words and
    /// trailing syllables stay) and at least 8 dB above the noise floor (so hiss that wobbles a
    /// little still counts as silence). If there is no clear gap between quiet and loud — music,
    /// constant ambience — only near-total silence qualifies.
    public static func automaticThreshold(levels: [Float]) -> Float {
        guard let (floor, peak) = levelStatistics(levels) else { return -90 }
        let range = peak - floor
        if range < 12 { return floor - 3 }
        return min(max(min(floor + range / 2, peak - 24), floor + 8), peak - 14)
    }

    /// A stretch has "voice" in it when some of it comes within this many dB of the voice level.
    static let voiceMargin: Float = 12
    /// Stretches up to this long are dropped when they have no voice in them.
    static let quietClipLength = 1.0
    /// Clicks shorter than this never interrupt a silence, however short the silence.
    static let clickLength = 0.08

    public static func detect(_ analysis: TimelineAnalysis, settings: SilenceSettings) -> DetectionResult {
        let hop = TimelineAnalysis.hop
        let count = analysis.hopCount

        // 1. Silence level per media file, and how loud the voice in it is.
        var thresholdByFile: [String: Float] = [:]
        var voiceLevelByFile: [String: Float] = [:]
        var levelsByFile: [String: [Float]] = [:]
        for track in analysis.tracks {
            levelsByFile[track.fileKey, default: []].append(contentsOf: track.levels)
        }
        for (key, levels) in levelsByFile {
            if let statistics = levelStatistics(levels) { voiceLevelByFile[key] = statistics.peak }
        }
        if settings.autoThreshold {
            var undecided: [String] = []
            for (key, levels) in levelsByFile {
                if voiceLevelByFile[key] == nil {
                    undecided.append(key)
                } else {
                    thresholdByFile[key] = automaticThreshold(levels: levels)
                }
            }
            // A recording too short to judge on its own (an accidental fraction-of-a-second
            // clip) is held to the same level as the rest of the project.
            let known = thresholdByFile.map { (level: $0.value, weight: levelsByFile[$0.key]?.count ?? 0) }
                .sorted { $0.level < $1.level }
            var fallback: Float = -90
            var seen = 0
            let half = known.reduce(0) { $0 + $1.weight } / 2
            for entry in known {
                seen += entry.weight
                if seen >= half { fallback = entry.level; break }
            }
            for key in undecided { thresholdByFile[key] = fallback }
        }
        var nameByFile: [String: String] = [:]
        var weightByFile: [String: Int] = [:]
        var displayThreshold = settings.thresholdDB
        var displayWeight = -1

        // 2. A hop has sound when something playing there reaches its silence level. Anything
        //    that stays below it — the last of a word's fade, a breath before the next one,
        //    rustling — is silence, so cuts land right against the audible part of the speech.
        var sound = [Bool](repeating: false, count: count)
        // Hops where the audio comes within `voiceMargin` of the recording's voice level.
        var nearVoice = [Bool](repeating: false, count: count)
        for track in analysis.tracks {
            nameByFile[track.fileKey] = track.mediaName
            weightByFile[track.fileKey, default: 0] += track.levels.count
            let threshold: Float
            if settings.autoThreshold {
                threshold = thresholdByFile[track.fileKey] ?? Float(settings.thresholdDB)
                if weightByFile[track.fileKey]! > displayWeight {
                    displayWeight = weightByFile[track.fileKey]!
                    displayThreshold = Double(threshold + track.gainDB)
                }
            } else {
                threshold = Float(settings.thresholdDB) - track.gainDB
            }
            let voice = voiceLevelByFile[track.fileKey].map { $0 - voiceMargin } ?? threshold + 20
            for (i, level) in track.levels.enumerated() where level >= threshold {
                let h = track.firstHop + i
                guard h >= 0 && h < count else { continue }
                sound[h] = true
                if level >= voice { nearVoice[h] = true }
            }
        }
        var silent = [Bool](repeating: false, count: count)
        for h in 0..<count { silent[h] = analysis.cuttable[h] && !sound[h] }

        // 3. Sounds that are not worth keeping.
        //    a) A click or lip smack doesn't interrupt a silence — unless it sits right next to
        //       speech, where it is more likely the "t" or "k" that ends a word.
        let minSilenceHops = max(1, Int((settings.minimumSilence / hop).rounded()))
        func runs() -> [(start: Int, end: Int, silent: Bool)] {
            var out: [(start: Int, end: Int, silent: Bool)] = []
            var h = 0
            while h < count {
                var end = h
                while end < count && silent[end] == silent[h] { end += 1 }
                out.append((h, end, silent[h]))
                h = end
            }
            return out
        }
        let clickHops = Int((min(clickLength, settings.minimumSound) / hop).rounded())
        if clickHops > 0 {
            let all = runs()
            if all.count >= 3 {
                for r in 1..<(all.count - 1) where !all[r].silent {
                    let island = all[r], before = all[r - 1], after = all[r + 1]
                    guard island.end - island.start < clickHops,
                          before.end - before.start >= 15, after.end - after.start >= 15,
                          (island.start..<island.end).allSatisfy({ analysis.cuttable[$0] }) else { continue }
                    for k in island.start..<island.end { silent[k] = true }
                }
            }
        }

        //    b) Whatever lies between two silences that are long enough to cut would become a
        //       clip of its own. It has to earn that: a stretch that is too short, that is mostly
        //       gaps (a couple of clicks), or that is brief and never gets near the level of the
        //       voice (a rustle, a sigh, a mutter between takes) goes with the silence instead.
        let minimumClipHops = Int((settings.minimumSound / hop).rounded())
        if minimumClipHops > 0 {
            let all = runs()
            let long = all.indices.filter { all[$0].silent && all[$0].end - all[$0].start >= minSilenceHops }
            for (left, right) in zip(long, long.dropFirst()) {
                let start = all[left].end, end = all[right].start
                guard end > start, (start..<end).allSatisfy({ silent[$0] || analysis.cuttable[$0] }) else { continue }
                var heard = 0, voiced = false
                for h in start..<end where !silent[h] {
                    heard += 1
                    if nearVoice[h] { voiced = true }
                }
                let tooShort = end - start < minimumClipHops
                let mostlyGaps = heard < max(1, minimumClipHops / 2)
                let briefAndQuiet = !voiced && end - start < Int((quietClipLength / hop).rounded())
                if tooShort || mostlyGaps || briefAndQuiet {
                    for h in start..<end { silent[h] = true }
                }
            }
        }

        // 4. Turn long enough silent runs into frame-aligned cuts. Next to speech a little quiet
        //    is kept (the padding). Next to a fenced-off clip there is no speech to protect: the
        //    cut runs right up to it, and step 5 trims it to that clip's exact edge.
        let fd = analysis.frameDuration
        let fdSeconds = fd.seconds
        var removals: [TimeRange] = []
        var h = 0
        while h < count {
            guard silent[h] else { h += 1; continue }
            var end = h
            while end < count && silent[end] { end += 1 }
            if end - h >= minSilenceHops {
                let start: RationalTime
                if h == 0 {
                    start = analysis.timelineStart
                } else if !analysis.cuttable[h - 1] {
                    start = fd * RationalTime(Int64((analysis.time(ofHop: h) / fdSeconds + 1e-6).rounded(.down)))
                } else {
                    let t = analysis.time(ofHop: h) + settings.padding
                    start = fd * RationalTime(Int64((t / fdSeconds - 1e-6).rounded(.up)))
                }
                let finish: RationalTime
                if end == count {
                    finish = analysis.timelineEnd
                } else if !analysis.cuttable[end] {
                    finish = fd * RationalTime(Int64((analysis.time(ofHop: end) / fdSeconds - 1e-6).rounded(.up)))
                } else {
                    let t = analysis.time(ofHop: end) - settings.padding
                    finish = fd * RationalTime(Int64((t / fdSeconds + 1e-6).rounded(.down)))
                }
                if finish > start { removals.append(TimeRange(start: start, end: finish)) }
            }
            h = end
        }

        // 5. Never cut into transitions or anything else we can't split.
        let timeline = TimeRange(start: analysis.timelineStart, end: analysis.timelineEnd)
        removals = TimeRanges.normalized(removals).compactMap { $0.intersection(timeline) }
        removals = TimeRanges.subtract(analysis.protectedRanges, from: removals)
        let removed = removals.reduce(RationalTime.zero) { $0 + $1.duration }

        let thresholds: [(String, Double)]
        if settings.autoThreshold {
            thresholds = thresholdByFile.map { (nameByFile[$0.key] ?? $0.key, Double($0.value)) }.sorted { $0.0 < $1.0 }
        } else {
            thresholds = []
        }
        return DetectionResult(removals: removals, thresholds: thresholds, displayThresholdDB: displayThreshold,
                               originalDuration: analysis.duration, removedDuration: removed)
    }
}
