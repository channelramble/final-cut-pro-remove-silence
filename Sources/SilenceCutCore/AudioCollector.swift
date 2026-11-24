import Foundation

/// Which clips decide whether a moment counts as silent.
public enum DetectionScope: String, Codable, CaseIterable, Sendable {
    /// Only the clips in the primary storyline (connected music, B-roll and effects are ignored and kept whole).
    case primaryStoryline
    /// Every clip with audio, including connected ones. Connected audio clips are cut too.
    case allClips
}

/// A stretch of one media file's audio as it plays on the project timeline.
struct AudioSpan {
    let media: FCPXMLFile.MediaReference
    /// Timeline seconds during which the span is audible.
    let window: (lo: Double, hi: Double)
    /// Timeline seconds -> seconds into the media file.
    let chain: TimeChain
    let gainDB: Double
    /// Set when the audio belongs to a clip connected to the primary storyline.
    let connected: ObjectIdentifier?
}

/// An element of the primary storyline.
struct PrimaryItem {
    let element: XMLElement
    let tag: String
    let timing: ElementTiming
    var range: TimeRange { TimeRange(start: timing.offset, end: timing.offset + timing.duration) }
    var isTransition: Bool { tag == "transition" }
    let splittable: Bool
}

/// Walks a project and works out which media audio plays when.
final class AudioCollector {
    private let file: FCPXMLFile
    private let scope: DetectionScope
    private(set) var spans: [AudioSpan] = []

    private struct Context {
        var flow: TimeChain
        var window: (lo: Double, hi: Double)
        var gain: Double
        var sequenceFrameDuration: RationalTime?
        var connected: ObjectIdentifier?
        var depth: Int
    }

    init(file: FCPXMLFile, scope: DetectionScope) {
        self.file = file
        self.scope = scope
    }

    /// Lists the primary storyline and collects the audio that decides what is silent.
    func collect(project: FCPXMLFile.Project) -> [PrimaryItem] {
        let frameDuration = file.frameDuration(of: project)
        var items: [PrimaryItem] = []
        for el in project.spine.elementChildren {
            let tag = el.tag
            guard FCPTag.story.contains(tag) else { continue }
            var timing = file.timing(of: el, sequenceFrameDuration: frameDuration)
            if timing == nil, tag == "audition", let active = el.elementChildren.first,
               var inner = file.timing(of: active, sequenceFrameDuration: frameDuration) {
                inner.offset = el.time("offset") ?? .zero
                timing = inner
            }
            guard let timing else { continue }
            let splittable = FCPTag.splittable.contains(tag) && el.attr("enabled") != "0"
            items.append(PrimaryItem(element: el, tag: tag, timing: timing, splittable: splittable))
            guard splittable else { continue }
            let context = Context(flow: .identity, window: (-Double.infinity, Double.infinity), gain: 0,
                                  sequenceFrameDuration: frameDuration, connected: nil, depth: 0)
            visit(el, flowStart: timing.offset.seconds, context: context, includeAnchored: scope == .allClips)
        }
        return items
    }

    private func volume(of el: XMLElement) -> Double {
        guard let amount = el.firstChild("adjust-volume")?.attr("amount") else { return 0 }
        let trimmed = amount.replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces)
        return Double(trimmed) ?? 0
    }

    private func intersect(_ a: (lo: Double, hi: Double), _ b: (Double, Double)) -> (lo: Double, hi: Double) {
        (max(a.lo, b.0), min(a.hi, b.1))
    }

    /// - Parameter flowStart: where `el` begins, in the time base `context.flow` maps to.
    private func visit(_ el: XMLElement, flowStart: Double, context: Context, includeAnchored: Bool) {
        guard context.depth < 24, el.attr("enabled") != "0" else { return }
        let tag = el.tag

        if tag == "audition" {
            // Only the first (active) pick plays.
            if let active = el.elementChildren.first {
                visit(active, flowStart: flowStart, context: context, includeAnchored: includeAnchored)
            }
            return
        }
        if tag == "spine" {
            // A connected storyline: its children are laid out from zero.
            var inner = context
            inner.flow = context.flow.appendingAffine(scale: 1, offset: -flowStart)
            inner.depth += 1
            for child in el.elementChildren where FCPTag.story.contains(child.tag) && child.tag != "transition" {
                visit(child, flowStart: (child.time("offset") ?? .zero).seconds, context: inner, includeAnchored: true)
            }
            return
        }
        guard tag != "transition", tag != "caption",
              let timing = file.timing(of: el, sequenceFrameDuration: context.sequenceFrameDuration) else { return }

        let start = timing.start.seconds
        let factor = timing.factor.seconds
        let duration = timing.duration.seconds
        let localChain = context.flow.appendingAffine(scale: factor, offset: start - flowStart * factor)
        let timeMap = TimeMapFunction(el.firstChild("timeMap"))
        let contentChain = timeMap.map { localChain.appendingMap($0) } ?? localChain
        let gain = context.gain + volume(of: el)

        if let hull = context.flow.inverseInterval(flowStart, flowStart + duration) {
            let window = intersect(context.window, hull)
            if window.hi > window.lo, gain > -90 {
                var inner = context
                inner.flow = contentChain
                inner.window = window
                inner.gain = gain
                inner.depth += 1
                switch tag {
                case "asset-clip", "audio":
                    addLeaf(el, timing: timing, flowStart: flowStart, window: window, localChain: localChain,
                            timeMap: timeMap, gain: gain, context: context)
                case "clip", "sync-clip":
                    if let fd = file.frameDuration(ofFormat: el.attr("format")) { inner.sequenceFrameDuration = fd }
                    for child in el.elementChildren where FCPTag.story.contains(child.tag) && !child.isAnchored && child.tag != "transition" {
                        visit(child, flowStart: (child.time("offset") ?? .zero).seconds, context: inner, includeAnchored: true)
                    }
                case "ref-clip":
                    if el.attr("srcEnable") != "video", let sequence = file.resource(el.attr("ref"))?.firstChild("sequence"),
                       let spine = sequence.firstChild("spine") {
                        if let fd = file.frameDuration(ofFormat: sequence.attr("format")) { inner.sequenceFrameDuration = fd }
                        for child in spine.elementChildren where FCPTag.story.contains(child.tag) && child.tag != "transition" {
                            visit(child, flowStart: (child.time("offset") ?? .zero).seconds, context: inner, includeAnchored: true)
                        }
                    }
                case "mc-clip":
                    if el.attr("srcEnable") != "video", let multicam = file.resource(el.attr("ref"))?.firstChild("multicam") {
                        if let fd = file.frameDuration(ofFormat: multicam.attr("format")) { inner.sequenceFrameDuration = fd }
                        let audible = Set(el.elements(forName: "mc-source")
                            .filter { ["audio", "all"].contains($0.attr("srcEnable") ?? "all") }
                            .compactMap { $0.attr("angleID") })
                        for angle in multicam.elements(forName: "mc-angle") where audible.contains(angle.attr("angleID") ?? "") {
                            for child in angle.elementChildren where FCPTag.story.contains(child.tag) && child.tag != "transition" {
                                visit(child, flowStart: (child.time("offset") ?? .zero).seconds, context: inner, includeAnchored: true)
                            }
                        }
                    }
                default:
                    break
                }
            }
        }

        guard includeAnchored else { return }
        for child in el.elementChildren where FCPTag.story.contains(child.tag) && child.isAnchored {
            // Connected clips sit in the parent's local time but keep playing past its edges.
            let childStart = flowStart + ((child.time("offset") ?? .zero).seconds - start) / factor
            var inner = context
            inner.depth += 1
            if context.depth == 0 && context.connected == nil { inner.connected = ObjectIdentifier(child) }
            visit(child, flowStart: childStart, context: inner, includeAnchored: true)
        }
    }

    private func addLeaf(_ el: XMLElement, timing: ElementTiming, flowStart: Double, window: (lo: Double, hi: Double),
                         localChain: TimeChain, timeMap: TimeMapFunction?, gain: Double, context: Context) {
        if el.tag == "asset-clip", el.attr("srcEnable") == "video" { return }
        guard let media = file.audioMedia(forAsset: el.attr("ref")) else { return }
        let channelSources = el.elements(forName: "audio-channel-source")
        if !channelSources.isEmpty, channelSources.allSatisfy({ $0.attr("active") == "0" || $0.attr("enabled") == "0" }) {
            return
        }

        // Split edits (J/L cuts) give the audio its own range.
        var window = window
        if let audioStart = el.time("audioStart"), let audioDuration = el.time("audioDuration") {
            let begin = flowStart + (audioStart.seconds - timing.start.seconds) / timing.factor.seconds
            if let hull = context.flow.inverseInterval(begin, begin + audioDuration.seconds) {
                window = intersect(context.window, hull)
            }
        }
        guard window.hi > window.lo else { return }

        let assetStart = media.start.seconds
        var chain = localChain
        if let timeMap {
            chain = chain.appendingMap(timeMap)
            // Retiming values are media times; some exports count them from the media's
            // timecode start and some from zero, so check which fits.
            let lowest = timeMap.values.min() ?? 0
            if assetStart > 0, lowest >= assetStart - 1e-6 {
                chain = chain.appendingAffine(scale: 1, offset: -assetStart)
            }
        } else {
            chain = chain.appendingAffine(scale: 1, offset: -assetStart)
        }
        spans.append(AudioSpan(media: media, window: window, chain: chain, gainDB: gain, connected: context.connected))
    }
}
