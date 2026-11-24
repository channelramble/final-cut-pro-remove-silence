import Foundation

/// Rebuilds a project's primary storyline with a set of timeline ranges deleted.
///
/// This is the XML equivalent of blading at the start and end of each silence and
/// ripple-deleting what's in between:
///  - primary clips are split and closed up;
///  - clips connected to the primary storyline stay whole and travel with the frame they
///    were attached to (or the next surviving frame), unless their own audio was part of the
///    analysis, in which case they are cut as well;
///  - markers stay on the piece of the clip they were on;
///  - transitions are never cut into (the detector keeps cuts away from them).
final class TimelineCutter {
    private let file: FCPXMLFile
    private let analysis: TimelineAnalysis
    private let removals: [TimeRange]
    private let removedBefore: [RationalTime]
    private let frameDuration: RationalTime

    /// A surviving piece of the primary storyline that connected clips can attach to.
    private struct Segment {
        let node: XMLElement
        let range: TimeRange
        let localStart: RationalTime
        let factor: RationalTime
    }

    private struct Piece {
        let node: XMLElement
        let range: TimeRange
        let localStart: RationalTime
    }

    private var segments: [Segment] = []
    /// Every `id` in the document, so duplicated clips can be given fresh ones.
    private var usedIDs: Set<String> = []
    private var idCounter = 0

    init(file: FCPXMLFile, analysis: TimelineAnalysis, removals: [TimeRange]) {
        self.file = file
        self.analysis = analysis
        self.removals = TimeRanges.normalized(removals)
        var sums: [RationalTime] = []
        var total = RationalTime.zero
        for r in self.removals {
            sums.append(total)
            total += r.duration
        }
        self.removedBefore = sums
        self.frameDuration = analysis.frameDuration
        for node in (try? file.document.nodes(forXPath: "//@id")) ?? [] {
            if let id = node.stringValue { usedIDs.insert(id) }
        }
    }

    /// A clip that is split in two appears twice in the document, but the IDs inside it
    /// (title text styles, tracking shapes) must stay unique. Final Cut Pro renumbers them
    /// when it blades a clip; do the same for every copy after the first.
    private func renumberIDs(in clone: XMLElement) {
        var renamed: [String: String] = [:]
        for node in (try? clone.nodes(forXPath: ".//text-style-def[@id] | .//tracking-shape[@id]")) ?? [] {
            guard let el = node as? XMLElement, let old = el.attr("id") else { continue }
            let prefix = String(old.prefix { !$0.isNumber })
            var candidate: String
            repeat {
                idCounter += 1
                candidate = "\(prefix.isEmpty ? "id" : prefix)\(idCounter)"
            } while usedIDs.contains(candidate)
            usedIDs.insert(candidate)
            renamed[old] = candidate
            el.setAttr("id", candidate)
        }
        guard !renamed.isEmpty else { return }
        for node in (try? clone.nodes(forXPath: ".//text-style[@ref] | .//*[@tracking]")) ?? [] {
            guard let el = node as? XMLElement else { continue }
            for name in ["ref", "tracking"] {
                if el.tag != "text-style" && name == "ref" { continue }
                if let value = el.attr(name), let replacement = renamed[value] { el.setAttr(name, replacement) }
            }
        }
    }

    var removedDuration: RationalTime { removals.reduce(.zero) { $0 + $1.duration } }

    // MARK: Time mapping

    /// Index of the last removal starting at or before `t`.
    private func removalIndex(atOrBefore t: RationalTime) -> Int? {
        var lo = 0, hi = removals.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if removals[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    /// `t` itself if it survives, otherwise the first surviving instant after it.
    private func nextKept(_ t: RationalTime) -> RationalTime {
        guard let i = removalIndex(atOrBefore: t), t < removals[i].end else { return t }
        return removals[i].end
    }

    /// Where a surviving instant ends up once everything before it has closed up.
    private func shifted(_ t: RationalTime) -> RationalTime {
        guard let i = removalIndex(atOrBefore: t) else { return t }
        let r = removals[i]
        return t - removedBefore[i] - (min(t, r.end) - r.start)
    }

    // MARK: Building

    /// Returns the new children for the project's `<spine>`.
    func buildSpine() throws -> [XMLElement] {
        var output: [XMLElement] = []
        for item in analysis.items {
            if item.isTransition {
                let clone = item.element.copy() as! XMLElement
                clone.setTime("offset", shifted(nextKept(item.timing.offset)))
                output.append(clone)
                continue
            }
            let pieces = split(item.element, timing: item.timing, timelineStart: item.timing.offset,
                               canSplit: item.splittable, stripAnchored: item.tag != "audition")
            for piece in pieces {
                piece.node.setTime("offset", shifted(piece.range.start))
                output.append(piece.node)
                if item.tag == "audition" {
                    // Connected clips of an audition live inside its active pick; leave them be.
                    continue
                }
                segments.append(Segment(node: piece.node, range: piece.range, localStart: piece.localStart,
                                        factor: item.timing.factor))
            }
        }
        guard !segments.isEmpty else { throw SilenceCutError.nothingLeft }

        for item in analysis.items where !item.isTransition && item.tag != "audition" {
            for child in item.element.elementChildren where FCPTag.story.contains(child.tag) && child.isAnchored {
                let start = item.timing.offset + ((child.time("offset") ?? .zero) - item.timing.start) / item.timing.factor
                place(child, timelineStart: start)
            }
        }
        return output
    }

    /// Clones `el` once per surviving stretch of its timeline range.
    private func split(_ el: XMLElement, timing: ElementTiming, timelineStart: RationalTime,
                       canSplit: Bool, stripAnchored: Bool) -> [Piece] {
        let full = TimeRange(start: timelineStart, end: timelineStart + timing.duration)
        let kept = canSplit ? TimeRanges.subtract(removals, from: full) : [full]
        guard !kept.isEmpty else { return [] }

        let markers = el.elementChildren.filter { FCPTag.marker.contains($0.tag) }
        var pieces: [Piece] = []
        for range in kept {
            let clone = el.copy() as! XMLElement
            for child in clone.elementChildren {
                let anchored = FCPTag.story.contains(child.tag) && child.isAnchored
                if (stripAnchored && anchored) || FCPTag.marker.contains(child.tag) {
                    clone.removeChild(at: child.index)
                }
            }
            let localStart = timing.start + (range.start - full.start) * timing.factor
            if range != full {
                if el.attr("start") != nil || !localStart.isZero { clone.setTime("start", localStart) }
                clone.setTime("duration", range.duration)
                adjustSplitEdit(clone, original: el, timing: timing, full: full, piece: range, localStart: localStart)
                removeFades(from: clone, fadeIn: range.start != full.start, fadeOut: range.end != full.end)
            }
            if !pieces.isEmpty { renumberIDs(in: clone) }
            pieces.append(Piece(node: clone, range: range, localStart: localStart))
        }

        // Markers follow the piece that contains them.
        for marker in markers {
            let local = marker.time("start") ?? .zero
            let position = full.start + (local - timing.start) / timing.factor
            let copy = marker.copy() as! XMLElement
            var target: Piece
            if let hit = pieces.first(where: { $0.range.contains(position) }) {
                target = hit
            } else if position < full.start {
                target = pieces[0]
            } else if position >= full.end {
                target = pieces[pieces.count - 1]
            } else if let next = pieces.first(where: { $0.range.start > position }) {
                // The marker sat in a deleted silence: move it to where the cut now is.
                target = next
                copy.setTime("start", next.localStart)
            } else {
                target = pieces[pieces.count - 1]
                let lastFrame = max(target.range.duration - frameDuration, .zero)
                copy.setTime("start", target.localStart + lastFrame * timing.factor)
            }
            insert(copy, into: target.node, rank: 2)
        }
        return pieces
    }

    /// A clip's fade-in belongs to its first piece and its fade-out to its last; the cuts in
    /// between are straight cuts, exactly as when a clip is bladed in Final Cut Pro.
    private func removeFades(from clone: XMLElement, fadeIn: Bool, fadeOut: Bool) {
        func strip(_ el: XMLElement) {
            for child in el.elementChildren {
                // Clips nested inside keep their own fades.
                if FCPTag.story.contains(child.tag) { continue }
                if (fadeIn && child.tag == "fadeIn") || (fadeOut && child.tag == "fadeOut") {
                    el.removeChild(at: child.index)
                } else {
                    strip(child)
                }
            }
        }
        strip(clone)
    }

    /// Keeps J/L cuts (audio that starts before or ends after the picture) on the outer pieces only.
    private func adjustSplitEdit(_ clone: XMLElement, original: XMLElement, timing: ElementTiming, full: TimeRange,
                                 piece: TimeRange, localStart: RationalTime) {
        guard let audioStart = original.time("audioStart"), let audioDuration = original.time("audioDuration") else { return }
        let audioEnd = audioStart + audioDuration * timing.factor
        let localEnd = localStart + piece.duration * timing.factor
        let newStart = piece.start == full.start ? audioStart : localStart
        let newEnd = piece.end == full.end ? audioEnd : localEnd
        if (newStart == localStart && newEnd == localEnd) || newEnd <= newStart {
            clone.setAttr("audioStart", nil)
            clone.setAttr("audioDuration", nil)
        } else {
            clone.setTime("audioStart", newStart)
            clone.setTime("audioDuration", (newEnd - newStart) / timing.factor)
        }
    }

    // MARK: Connected clips

    private func place(_ child: XMLElement, timelineStart: RationalTime) {
        let participates = analysis.participating.contains(ObjectIdentifier(child))
        if child.tag == "spine" {
            if participates {
                placeCutStoryline(child, timelineStart: timelineStart)
            } else {
                anchor(child.copy() as! XMLElement, at: nextKept(timelineStart))
            }
            return
        }
        if participates, FCPTag.splittable.contains(child.tag),
           let timing = file.timing(of: child, sequenceFrameDuration: frameDuration) {
            let pieces = split(child, timing: timing, timelineStart: timelineStart, canSplit: true, stripAnchored: false)
            for piece in pieces { anchor(piece.node, at: piece.range.start) }
            return
        }
        anchor(child.copy() as! XMLElement, at: nextKept(timelineStart))
    }

    /// A connected storyline whose audio was analyzed is cut and closed up like the primary one.
    private func placeCutStoryline(_ spine: XMLElement, timelineStart: RationalTime) {
        var parts: [(node: XMLElement, start: RationalTime)] = []
        for child in spine.elementChildren where FCPTag.story.contains(child.tag) {
            let offset = timelineStart + (child.time("offset") ?? .zero)
            if child.tag == "transition" {
                parts.append((child.copy() as! XMLElement, nextKept(offset)))
                continue
            }
            guard let timing = file.timing(of: child, sequenceFrameDuration: frameDuration) else { continue }
            let pieces = split(child, timing: timing, timelineStart: offset,
                               canSplit: FCPTag.splittable.contains(child.tag), stripAnchored: false)
            for piece in pieces { parts.append((piece.node, piece.range.start)) }
        }
        guard let first = parts.filter({ $0.node.tag != "transition" }).map(\.start).min() else { return }
        let clone = spine.copy() as! XMLElement
        clone.setChildren(nil)
        let origin = shifted(first)
        for part in parts {
            part.node.setTime("offset", max(shifted(part.start) - origin, .zero))
            clone.addChild(part.node)
        }
        anchor(clone, at: first)
    }

    /// Attaches `node` to whichever surviving primary piece plays at timeline time `t`.
    private func anchor(_ node: XMLElement, at t: RationalTime) {
        var lo = 0, hi = segments.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segments[mid].range.start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let segment: Segment
        var time = t
        if let found {
            segment = segments[found]
            if t >= segment.range.end {
                if found + 1 < segments.count {
                    // Fell between pieces: use the start of the next one.
                    let next = segments[found + 1]
                    node.setTime("offset", next.localStart)
                    insert(node, into: next.node, rank: 1)
                    return
                }
                // Past the end of the storyline: hang it off the last frame.
                time = max(segment.range.start, segment.range.end - frameDuration)
            }
        } else {
            segment = segments[0]
            time = segment.range.start
        }
        node.setTime("offset", segment.localStart + (time - segment.range.start) * segment.factor)
        insert(node, into: segment.node, rank: 1)
    }

    // MARK: DTD-ordered insertion

    /// Order the FCPXML DTD imposes on a clip's children: settings, then contained and
    /// connected clips, then markers, then audio sources, filters and metadata.
    private func rank(_ el: XMLElement) -> Int {
        let tag = el.tag
        if FCPTag.marker.contains(tag) { return 2 }
        if FCPTag.tail.contains(tag) { return 3 }
        if FCPTag.story.contains(tag) { return 1 }
        return 0
    }

    private func insert(_ node: XMLElement, into parent: XMLElement, rank r: Int) {
        let children = parent.children ?? []
        var index = 0
        for (i, child) in children.enumerated() {
            if let el = child as? XMLElement, rank(el) <= r { index = i + 1 }
        }
        parent.insertChild(node, at: index)
    }
}

extension FCPXMLFile {
    /// Produces a new FCPXML document containing a copy of the analyzed project with `removals` deleted.
    public func documentRemoving(_ removals: [TimeRange], from analysis: TimelineAnalysis, newProjectName: String) throws -> Data {
        let cutter = TimelineCutter(file: self, analysis: analysis, removals: removals)
        let newChildren = try cutter.buildSpine()

        let output = document.copy() as! XMLDocument
        guard let root = output.rootElement() else { throw SilenceCutError.noProject }
        var node: XMLNode = root
        var ancestors: [XMLElement] = [root]
        for index in analysis.project.path {
            guard let next = node.child(at: index) as? XMLElement else { throw SilenceCutError.noProject }
            node = next
            ancestors.append(next)
        }
        guard let project = node as? XMLElement, project.tag == "project",
              let sequence = project.firstChild("sequence"), let spine = sequence.firstChild("spine") else {
            throw SilenceCutError.noProject
        }

        // Swap in the new storyline. (Elements carry their original indentation with them.)
        spine.setChildren(nil)
        for child in newChildren { spine.addChild(child) }
        if let duration = sequence.time("duration") {
            sequence.setTime("duration", max(duration - cutter.removedDuration, .zero))
        }

        // It's a new project: give it its own name and let Final Cut Pro assign fresh IDs.
        project.setAttr("name", newProjectName)
        project.setAttr("uid", nil)
        project.setAttr("modDate", nil)

        // Send only this project back, not everything else that came along in the drag.
        for (depth, ancestor) in ancestors.enumerated().dropLast() {
            let keep = ancestors[depth + 1]
            guard ["fcpxml", "library", "event"].contains(ancestor.tag) else { continue }
            for child in ancestor.elementChildren where child !== keep {
                if ancestor.tag == "fcpxml" && (child.tag == "resources" || child.tag == "import-options") { continue }
                ancestor.removeChild(at: child.index)
            }
        }

        addImportOptions(to: root)
        return FCPXMLFile.serialize(output)
    }

    /// Tells Final Cut Pro which library to import into, so it doesn't have to ask.
    private func addImportOptions(to root: XMLElement) {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2, parts[0] > 1 || parts[1] >= 10, root.firstChild("import-options") == nil,
              let location = libraryLocation, !location.isEmpty else { return }
        let options = XMLElement(name: "import-options")
        for (key, value) in [("library location", location)] {
            let option = XMLElement(name: "option")
            option.setAttr("key", key)
            option.setAttr("value", value)
            options.addChild(XMLNode.text(withStringValue: "\n        ") as! XMLNode)
            options.addChild(option)
        }
        options.addChild(XMLNode.text(withStringValue: "\n    ") as! XMLNode)
        root.insertChild(options, at: 0)
        root.insertChild(XMLNode.text(withStringValue: "\n    ") as! XMLNode, at: 0)
    }
}
