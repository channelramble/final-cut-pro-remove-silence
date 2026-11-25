import Foundation

/// The loudness of everything that plays on a project's timeline, sampled every `hop` seconds.
/// Built once per project (reading audio is the slow part); detection with new settings is instant.
public struct TimelineAnalysis {
    public static let hop = 0.01

    struct Track {
        /// Key of the media file the levels came from.
        let fileKey: String
        let mediaName: String
        let firstHop: Int
        /// File level in dBFS for each hop from `firstHop`, before clip volume.
        let levels: [Float]
        let gainDB: Float
        let connected: ObjectIdentifier?
    }

    public let projectName: String
    public let scope: DetectionScope
    public let frameDuration: RationalTime
    public let timelineStart: RationalTime
    public let timelineEnd: RationalTime
    public let hopCount: Int
    /// Media that could not be read; clips using it are left untouched.
    public let unreadableMedia: [String]

    let project: FCPXMLFile.Project
    let items: [PrimaryItem]
    let tracks: [Track]
    /// True where a cut is allowed: inside a splittable primary clip with audio we could read.
    let cuttable: [Bool]
    /// Timeline ranges that must never be touched (transitions, auditions, unknown elements).
    let protectedRanges: [TimeRange]
    /// Connected clips whose audio took part in the analysis.
    let participating: Set<ObjectIdentifier>

    public var duration: RationalTime { timelineEnd - timelineStart }
    public var hasAudio: Bool { !tracks.isEmpty }

    func time(ofHop hop: Int) -> Double { timelineStart.seconds + Double(hop) * TimelineAnalysis.hop }

    /// Loudest level (dBFS, after clip volume) per display bucket, for drawing a waveform.
    public func displayLevels(buckets: Int) -> [Float] {
        guard buckets > 0, hopCount > 0 else { return [] }
        var out = [Float](repeating: AudioEnvelope.floorDB, count: buckets)
        for track in tracks {
            for (i, level) in track.levels.enumerated() {
                let hop = track.firstHop + i
                guard hop >= 0, hop < hopCount else { continue }
                let bucket = min(buckets - 1, hop * buckets / hopCount)
                let value = level + track.gainDB
                if value > out[bucket] { out[bucket] = value }
            }
        }
        return out
    }
}

extension FCPXMLFile {
    /// Reads the audio behind a project and lays it out on the timeline.
    public func analyze(project: Project, scope: DetectionScope, provider: EnvelopeProvider = AVFoundationEnvelopeProvider(),
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> TimelineAnalysis {
        let collector = AudioCollector(file: self, scope: scope)
        let items = collector.collect(project: project)
        let clips = items.filter { !$0.isTransition }
        guard let first = clips.map(\.range.start).min(), let last = clips.map(\.range.end).max(), last > first else {
            throw SilenceCutError.emptyProject
        }
        let hop = TimelineAnalysis.hop
        let t0 = first.seconds, t1 = last.seconds
        let hopCount = max(1, Int(((t1 - t0) / hop).rounded(.up)))

        // Clamp every span to the timeline and work out which part of each file is needed.
        struct Pending { let span: AudioSpan; let lo: Double; let hi: Double; let key: String }
        var pending: [Pending] = []
        var requests: [String: (media: MediaReference, lo: Double, hi: Double)] = [:]
        for span in collector.spans {
            let lo = max(span.window.lo, t0), hi = min(span.window.hi, t1)
            guard hi > lo else { continue }
            let key = span.media.url.standardizedFileURL.path
            // Sample the mapping so retimed (non-linear) spans are covered too.
            var sLo = Double.infinity, sHi = -Double.infinity
            let steps = 16
            for i in 0...steps {
                let s = span.chain.apply(lo + (hi - lo) * Double(i) / Double(steps))
                sLo = min(sLo, s); sHi = max(sHi, s)
            }
            guard sLo.isFinite, sHi.isFinite else { continue }
            pending.append(Pending(span: span, lo: lo, hi: hi, key: key))
            if let existing = requests[key] {
                requests[key] = (existing.media, min(existing.lo, sLo), max(existing.hi, sHi))
            } else {
                requests[key] = (span.media, sLo, sHi)
            }
        }

        var envelopes: [String: AudioEnvelope] = [:]
        var unreadable: [String] = []
        let ordered = requests.sorted { $0.key < $1.key }
        let totalSeconds = max(ordered.reduce(0.0) { $0 + ($1.value.hi - $1.value.lo) }, 0.001)
        var doneSeconds = 0.0
        for (key, request) in ordered {
            try Task.checkCancellation()
            let length = request.hi - request.lo
            let base = doneSeconds
            let media = MediaRequest(url: request.media.url, bookmark: request.media.bookmark,
                                     range: max(0, request.lo - 0.1)...(request.hi + 0.1))
            do {
                envelopes[key] = try await provider.envelope(for: media, hop: hop) { fraction in
                    progress(min(1, (base + fraction * length) / totalSeconds))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unreadable.append(request.media.name)
            }
            doneSeconds += length
            progress(min(1, doneSeconds / totalSeconds))
        }

        var tracks: [TimelineAnalysis.Track] = []
        var covered = [Bool](repeating: false, count: hopCount)
        var participating = Set<ObjectIdentifier>()
        for p in pending {
            guard let envelope = envelopes[p.key] else { continue }
            let h0 = max(0, Int(((p.lo - t0) / hop).rounded(.down)))
            let h1 = min(hopCount, Int(((p.hi - t0) / hop).rounded(.up)))
            guard h1 > h0 else { continue }
            var levels = [Float](repeating: AudioEnvelope.floorDB, count: h1 - h0)
            for h in h0..<h1 {
                // Stay inside the span: audio just past an edit point isn't part of the timeline.
                let from = max(t0 + Double(h) * hop, p.lo), to = min(t0 + Double(h + 1) * hop, p.hi)
                guard to > from else { continue }
                levels[h - h0] = envelope.maxLevel(from: p.span.chain.apply(from), to: p.span.chain.apply(to))
                covered[h] = true
            }
            tracks.append(.init(fileKey: p.key, mediaName: p.span.media.name, firstHop: h0, levels: levels,
                                gainDB: Float(p.span.gainDB), connected: p.span.connected))
            if let connected = p.span.connected { participating.insert(connected) }
        }

        // Cuts are allowed wherever we heard something, except inside clips that can't be split
        // or whose audio we couldn't read. Those are fenced off: exactly, to the frame, through
        // `protected`, and per hop through `cuttable`. A hop that straddles the edit point
        // between two ordinary clips stays cuttable, so a silence that runs from the end of one
        // clip into the start of the next is one silence — not two, with a sliver of each clip
        // left standing at the edit point.
        var cuttable = covered
        var protected: [TimeRange] = []
        for item in items {
            if item.isTransition {
                protected.append(item.range)
                continue
            }
            let h0 = max(0, Int(((item.range.start.seconds - t0) / hop).rounded(.up)))
            let h1 = min(hopCount, Int(((item.range.end.seconds - t0) / hop).rounded(.down)))
            let heard = h1 > h0 && (h0..<h1).contains { covered[$0] }
            if !item.splittable || !heard {
                protected.append(item.range)
                if h1 > h0 { for h in h0..<h1 { cuttable[h] = false } }
            }
        }
        if scope == .allClips {
            protected.append(contentsOf: connectedTransitionRanges(items: items, participating: participating))
        }

        return TimelineAnalysis(projectName: project.name, scope: scope, frameDuration: frameDuration(of: project),
                                timelineStart: first, timelineEnd: last, hopCount: hopCount,
                                unreadableMedia: unreadable.sorted(), project: project, items: items, tracks: tracks,
                                cuttable: cuttable, protectedRanges: TimeRanges.normalized(protected),
                                participating: participating)
    }

    /// Transitions inside connected storylines that will be cut must stay intact as well.
    private func connectedTransitionRanges(items: [PrimaryItem], participating: Set<ObjectIdentifier>) -> [TimeRange] {
        var out: [TimeRange] = []
        for item in items where !item.isTransition {
            for child in item.element.elementChildren where child.tag == "spine" && child.isAnchored
                && participating.contains(ObjectIdentifier(child)) {
                let spineStart = item.timing.offset + ((child.time("offset") ?? .zero) - item.timing.start) / item.timing.factor
                for transition in child.elements(forName: "transition") {
                    guard let duration = transition.time("duration") else { continue }
                    let start = spineStart + (transition.time("offset") ?? .zero)
                    out.append(TimeRange(start: start, end: start + duration))
                }
            }
        }
        return out
    }
}
