import Foundation

public enum SilenceCutError: LocalizedError {
    case notFCPXML(String)
    case noProject
    case emptyProject
    case noAudio
    case nothingLeft
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notFCPXML(let why): return "This isn't a Final Cut Pro XML document (\(why))."
        case .noProject: return "No project was found. Drag a project (not a clip or event) from the Final Cut Pro browser."
        case .emptyProject: return "This project's timeline is empty."
        case .noAudio: return "No readable audio was found in the project's primary storyline."
        case .nothingLeft: return "With these settings the whole project counts as silence, so nothing would be left. Lower the threshold."
        case .io(let why): return why
        }
    }
}

// MARK: - XML helpers

extension XMLElement {
    func attr(_ name: String) -> String? { attribute(forName: name)?.stringValue }

    func setAttr(_ name: String, _ value: String?) {
        if let value {
            if let existing = attribute(forName: name) {
                existing.stringValue = value
            } else {
                addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
            }
        } else {
            removeAttribute(forName: name)
        }
    }

    func time(_ name: String) -> RationalTime? { RationalTime(fcpxml: attr(name)) }

    func setTime(_ name: String, _ value: RationalTime) { setAttr(name, value.fcpxmlString) }

    var elementChildren: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }

    var tag: String { name ?? "" }

    func firstChild(_ name: String) -> XMLElement? { elements(forName: name).first }

    /// True when the element is anchored to its parent (a connected clip or storyline).
    var isAnchored: Bool {
        guard let lane = attr("lane") else { return false }
        return lane != "0" && !lane.isEmpty
    }
}

enum FCPTag {
    /// Elements that occupy time on a storyline or can be connected to a clip.
    static let story: Set<String> = [
        "audio", "video", "clip", "title", "caption", "mc-clip", "ref-clip", "sync-clip",
        "asset-clip", "audition", "spine", "live-drawing", "gap", "transition",
    ]
    static let marker: Set<String> = [
        "marker", "chapter-marker", "rating", "keyword", "analysis-marker", "hidden-clip-marker",
    ]
    /// Elements the DTD requires after anchored items and markers.
    static let tail: Set<String> = [
        "audio-channel-source", "audio-role-source", "sync-source", "filter-video",
        "filter-video-mask", "filter-audio", "metadata", "reserved",
    ]
    /// Primary-storyline elements we know how to split in two.
    static let splittable: Set<String> = [
        "asset-clip", "clip", "sync-clip", "mc-clip", "ref-clip", "audio", "video", "gap", "title",
    ]
    /// Containers whose un-laned children are their contents rather than connected clips.
    static let inlineContainers: Set<String> = ["clip", "sync-clip"]
}

/// Timing of a story element.
struct ElementTiming {
    /// Position in the parent's time base.
    var offset: RationalTime
    /// Start of the element's local timeline.
    var start: RationalTime
    /// Length on the timeline that contains the element.
    var duration: RationalTime
    /// Local seconds that elapse per timeline second (differs from 1 for rate-conformed media).
    var factor: RationalTime
}

// MARK: - Document

/// A parsed FCPXML document plus the lookups the rest of the engine needs.
public final class FCPXMLFile {
    public struct Project {
        public let name: String
        public let eventName: String?
        public let duration: RationalTime
        let element: XMLElement
        let sequence: XMLElement
        let spine: XMLElement
        /// Child-index path from the root element, used to find the same node in a copy.
        let path: [Int]
    }

    public let document: XMLDocument
    public let version: String
    public let baseURL: URL?
    public private(set) var projects: [Project] = []
    private(set) var resources: [String: XMLElement] = [:]

    public convenience init(contentsOf url: URL) throws {
        var fileURL = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // .fcpxmld bundle
            fileURL = url.appendingPathComponent("Info.fcpxml")
        }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch {
            throw SilenceCutError.io("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        try self.init(data: data, baseURL: fileURL.deletingLastPathComponent())
    }

    public init(data: Data, baseURL: URL? = nil) throws {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            throw SilenceCutError.notFCPXML(error.localizedDescription)
        }
        guard let root = doc.rootElement(), root.tag == "fcpxml" else {
            throw SilenceCutError.notFCPXML("missing <fcpxml> root")
        }
        self.document = doc
        self.version = root.attr("version") ?? "1.0"
        self.baseURL = baseURL
        index()
    }

    private func index() {
        guard let root = document.rootElement() else { return }
        resources = [:]
        for res in root.firstChild("resources")?.elementChildren ?? [] {
            if let id = res.attr("id") { resources[id] = res }
        }
        projects = []
        func walk(_ el: XMLElement, path: [Int], eventName: String?) {
            var eventName = eventName
            if el.tag == "event" { eventName = el.attr("name") }
            if el.tag == "project" {
                if let seq = el.firstChild("sequence"), let spine = seq.firstChild("spine") {
                    let duration = seq.time("duration") ?? .zero
                    projects.append(Project(name: el.attr("name") ?? "Untitled Project", eventName: eventName,
                                            duration: duration, element: el, sequence: seq, spine: spine, path: path))
                }
                return
            }
            guard ["fcpxml", "library", "event"].contains(el.tag) else { return }
            for (i, child) in (el.children ?? []).enumerated() {
                if let c = child as? XMLElement { walk(c, path: path + [i], eventName: eventName) }
            }
        }
        walk(root, path: [], eventName: nil)
    }

    public var libraryLocation: String? {
        document.rootElement()?.firstChild("library")?.attr("location")
    }

    func resource(_ id: String?) -> XMLElement? {
        guard let id else { return nil }
        return resources[id]
    }

    func frameDuration(ofFormat id: String?) -> RationalTime? {
        resource(id)?.time("frameDuration")
    }

    /// Frame duration of a project's sequence (falls back to 1/30 s when the format has none).
    func frameDuration(of project: Project) -> RationalTime {
        frameDuration(ofFormat: project.sequence.attr("format")) ?? RationalTime(1, 30)
    }

    // MARK: Timing

    private static let ntscRates: [(Double, RationalTime)] = [
        (23.976, RationalTime(1001, 24000)), (29.97, RationalTime(1001, 30000)),
        (47.952, RationalTime(1001, 48000)), (59.94, RationalTime(1001, 60000)),
        (119.88, RationalTime(1001, 120000)),
    ]

    static func frameDuration(forRateString string: String?) -> RationalTime? {
        guard let string, let rate = Double(string), rate > 0 else { return nil }
        for (value, fd) in ntscRates where abs(rate - value) < 0.02 { return fd }
        let rounded = rate.rounded()
        if abs(rate - rounded) < 0.001 { return RationalTime(1, Int64(rounded)) }
        return RationalTime(1000, Int64((rate * 1000).rounded()))
    }

    private static func isNTSC(_ fd: RationalTime) -> Bool { fd.num % 1001 == 0 }

    /// How fast an element's local time runs relative to the timeline that contains it.
    ///
    /// Final Cut Pro plays rate-conformed media frame-for-frame when the rates are close
    /// (23.98 in 24, 25 in 24, ...), so a clip's `start` (in media time) advances faster or
    /// slower than its `duration` (in timeline time). Verified against FCP exports.
    func conformFactor(of el: XMLElement, sequenceFrameDuration: RationalTime?) -> RationalTime {
        guard let conform = el.firstChild("conform-rate"), conform.attr("scaleEnabled") != "0",
              let seqFD = sequenceFrameDuration,
              let srcFD = FCPXMLFile.frameDuration(forRateString: conform.attr("srcFrameRate")),
              srcFD != seqFD else { return RationalTime(1) }
        let ratio = srcFD / seqFD
        if abs(ratio.seconds - 1) < 0.05 { return ratio }
        let srcNTSC = FCPXMLFile.isNTSC(srcFD), seqNTSC = FCPXMLFile.isNTSC(seqFD)
        if srcNTSC && !seqNTSC { return RationalTime(1001, 1000) }
        if !srcNTSC && seqNTSC { return RationalTime(1000, 1001) }
        return RationalTime(1)
    }

    func timing(of el: XMLElement, sequenceFrameDuration: RationalTime?) -> ElementTiming? {
        var duration = el.time("duration")
        if duration == nil, el.tag == "asset-clip" || el.tag == "audio" || el.tag == "video" {
            duration = resource(el.attr("ref"))?.time("duration")
        }
        guard let duration, duration > .zero else { return nil }
        return ElementTiming(offset: el.time("offset") ?? .zero,
                             start: el.time("start") ?? .zero,
                             duration: duration,
                             factor: conformFactor(of: el, sequenceFrameDuration: sequenceFrameDuration))
    }

    /// Length of a connected storyline, derived from its children.
    func storylineDuration(_ spine: XMLElement) -> RationalTime {
        var end = RationalTime.zero
        for child in spine.elementChildren where child.tag != "transition" {
            guard let d = child.time("duration") ?? resource(child.attr("ref"))?.time("duration") else { continue }
            end = max(end, (child.time("offset") ?? .zero) + d)
        }
        return end
    }

    // MARK: Media

    struct MediaReference {
        let url: URL
        let bookmark: Data?
        let name: String
        let start: RationalTime
        let duration: RationalTime?
    }

    /// The media file behind an asset, if it has audio.
    func audioMedia(forAsset id: String?) -> MediaReference? {
        guard let asset = resource(id), asset.tag == "asset", asset.attr("hasAudio") == "1" else { return nil }
        let reps = asset.elements(forName: "media-rep")
        let rep = reps.first { ($0.attr("kind") ?? "original-media") == "original-media" } ?? reps.first
        // FCPXML 1.8 and earlier keep the path on the asset itself.
        guard let src = rep?.attr("src") ?? asset.attr("src"), !src.isEmpty else { return nil }
        let url: URL?
        if src.contains("://") || src.hasPrefix("file:") {
            url = URL(string: src) ?? src.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap(URL.init(string:))
        } else if src.hasPrefix("/") {
            url = URL(fileURLWithPath: src.removingPercentEncoding ?? src)
        } else {
            url = baseURL.map { URL(fileURLWithPath: src.removingPercentEncoding ?? src, relativeTo: $0).absoluteURL }
        }
        guard let url, url.isFileURL else { return nil }
        let bookmark = rep?.firstChild("bookmark")?.stringValue.flatMap {
            Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters)
        }
        return MediaReference(url: url, bookmark: bookmark, name: asset.attr("name") ?? url.lastPathComponent,
                              start: asset.time("start") ?? .zero, duration: asset.time("duration"))
    }

    // MARK: Output

    /// Serializes a document the way Final Cut Pro writes its own exports.
    static func serialize(_ document: XMLDocument) -> Data {
        guard let root = document.rootElement() else { return Data() }
        // Whitespace is preserved on the way in and out so title text is never reflowed.
        let body = root.xmlString(options: [.nodePreserveWhitespace])
        let text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n\n" + body + "\n"
        return tidy(Data(text.utf8))
    }

    /// Two fix-ups for Foundation's XML writer:
    ///  - it writes literal newlines and tabs inside attribute values, which an XML parser turns
    ///    into spaces on the way back in (flattening multi-line notes and titles), so they are
    ///    written as character references instead;
    ///  - it writes empty elements as `<a></a>`; Final Cut Pro writes `<a/>`.
    static func tidy(_ data: Data) -> Data {
        enum State { case text, tag, attr(UInt8), comment, cdata, pi, doctype }
        var out = [UInt8]()
        out.reserveCapacity(data.count + 1024)
        let bytes = [UInt8](data)
        var state = State.text
        var i = 0
        let n = bytes.count
        var tagName: ArraySlice<UInt8> = []
        var isEndTag = false
        func matches(_ s: String, at index: Int) -> Bool {
            let u = Array(s.utf8)
            guard index + u.count <= n else { return false }
            for k in 0..<u.count where bytes[index + k] != u[k] { return false }
            return true
        }
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
        while i < n {
            let b = bytes[i]
            switch state {
            case .text:
                if b == lt {
                    if matches("<!--", at: i) { state = .comment }
                    else if matches("<![CDATA[", at: i) { state = .cdata }
                    else if matches("<?", at: i) { state = .pi }
                    else if matches("<!", at: i) { state = .doctype }
                    else {
                        state = .tag
                        isEndTag = i + 1 < n && bytes[i + 1] == slash
                        var j = i + 1
                        while j < n, bytes[j] != gt, bytes[j] != slash, bytes[j] != 0x20, bytes[j] != 0x0A, bytes[j] != 0x09, bytes[j] != 0x0D { j += 1 }
                        tagName = bytes[(i + 1)..<j]
                    }
                }
                out.append(b)
            case .tag:
                if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                    state = .attr(b)
                    out.append(b)
                } else if b == gt {
                    state = .text
                    // "<name ...></name>" -> "<name .../>"
                    let selfClosed = i > 0 && bytes[i - 1] == slash
                    let closeLength = tagName.count + 3
                    if !isEndTag, !selfClosed, !tagName.isEmpty, i + closeLength < n,
                       bytes[i + 1] == lt, bytes[i + 2] == slash,
                       bytes[(i + 3)..<(i + 3 + tagName.count)].elementsEqual(tagName), bytes[i + 3 + tagName.count] == gt {
                        out.append(slash)
                        out.append(gt)
                        i += closeLength
                    } else {
                        out.append(b)
                    }
                } else {
                    out.append(b)
                }
            case .attr(let quote):
                if b == quote { state = .tag; out.append(b) }
                else if b == 0x0A { out.append(contentsOf: Array("&#10;".utf8)) }
                else if b == 0x0D { out.append(contentsOf: Array("&#13;".utf8)) }
                else if b == 0x09 { out.append(contentsOf: Array("&#9;".utf8)) }
                else { out.append(b) }
            case .comment:
                out.append(b)
                if b == gt, i >= 2, bytes[i - 1] == UInt8(ascii: "-"), bytes[i - 2] == UInt8(ascii: "-") { state = .text }
            case .cdata:
                out.append(b)
                if b == gt, i >= 2, bytes[i - 1] == UInt8(ascii: "]"), bytes[i - 2] == UInt8(ascii: "]") { state = .text }
            case .pi:
                out.append(b)
                if b == gt, i >= 1, bytes[i - 1] == UInt8(ascii: "?") { state = .text }
            case .doctype:
                out.append(b)
                if b == gt { state = .text }
            }
            i += 1
        }
        return Data(out)
    }
}
