import Foundation
import XCTest
@testable import SilenceCutCore

enum Paths {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let media = root.appendingPathComponent("Tests/Fixtures/media")
    static let dtds = root.appendingPathComponent("vendor/dtd")
    static let samples = root.appendingPathComponent("vendor/samples/swift-fcpxml/Tests/SwiftFCPXMLTests/TestResource/FCPXML Exports")

    static var hasMedia: Bool { FileManager.default.fileExists(atPath: media.appendingPathComponent("talk_room.mov").path) }
    static var hasSamples: Bool { FileManager.default.fileExists(atPath: samples.path) }
}

/// Deterministic fake audio: alternating blocks of "speech" (-18 dB) and "room tone" (-65 dB)
/// whose lengths depend only on the file name and the absolute file time.
struct SyntheticProvider: EnvelopeProvider {
    var loud: Float = -18
    var quiet: Float = -65

    static func isLoud(file: String, time: Double) -> Bool {
        var seed = UInt64(5381)
        for byte in file.utf8 { seed = seed &* 33 &+ UInt64(byte) }
        // Walk blocks from zero until we reach `time`.
        var t = 0.0
        var loud = seed % 2 == 0
        var state = seed
        while true {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double((state >> 33) % 1000) / 1000
            let length = loud ? 0.4 + unit * 3.5 : 0.2 + unit * 2.5
            if time < t + length { return loud }
            t += length
            loud.toggle()
        }
    }

    func envelope(for request: MediaRequest, hop: Double, progress: @Sendable (Double) -> Void) async throws -> AudioEnvelope {
        let name = request.url.lastPathComponent
        let first = Int((max(0, request.range.lowerBound) / hop).rounded(.down))
        let last = Int((request.range.upperBound / hop).rounded(.up))
        var levels: [Float] = []
        levels.reserveCapacity(max(0, last - first))
        for i in first..<max(first + 1, last) {
            levels.append(SyntheticProvider.isLoud(file: name, time: (Double(i) + 0.5) * hop) ? loud : quiet)
        }
        return AudioEnvelope(startTime: Double(first) * hop, hop: hop, levels: levels)
    }
}

/// Validates a document against the DTD Final Cut Pro ships for its version.
func dtdErrors(_ data: Data) throws -> String? {
    let text = String(decoding: data.prefix(400), as: UTF8.self)
    guard let range = text.range(of: #"fcpxml version="([0-9.]+)""#, options: .regularExpression) else { return "no version" }
    let version = text[range].split(separator: "\"")[1].replacingOccurrences(of: ".", with: "_")
    let dtd = Paths.dtds.appendingPathComponent("FCPXMLv\(version).dtd")
    guard FileManager.default.fileExists(atPath: dtd.path) else { return nil }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("silencecut-\(UUID().uuidString).fcpxml")
    try data.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
    process.arguments = ["--noout", "--dtdvalid", dtd.path, file.path]
    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = Pipe()
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? nil : String(decoding: output, as: UTF8.self)
}

struct CutOutcome {
    let analysis: TimelineAnalysis
    let result: DetectionResult
    let output: FCPXMLFile
    let outputAnalysis: TimelineAnalysis
    let data: Data
}

/// Runs the whole pipeline and checks everything that must hold for any project.
@discardableResult
func cutAndVerify(_ file: FCPXMLFile, project: FCPXMLFile.Project, settings: SilenceSettings, provider: EnvelopeProvider,
                  label: String, validate: Bool = true, fileRef: StaticString = #filePath, line: UInt = #line) async throws -> CutOutcome? {
    let analysis: TimelineAnalysis
    do {
        analysis = try await file.analyze(project: project, scope: settings.scope, provider: provider)
    } catch SilenceCutError.emptyProject {
        return nil
    }
    guard analysis.hasAudio else { return nil }
    let result = SilenceDetector.detect(analysis, settings: settings)
    guard result.cutCount > 0 else { return nil }
    let fd = analysis.frameDuration

    // Cuts are sorted, disjoint, inside the timeline, and clear of protected ranges.
    var previousEnd = analysis.timelineStart
    for r in result.removals {
        XCTAssertGreaterThanOrEqual(r.start, previousEnd, "\(label): removals overlap", file: fileRef, line: line)
        XCTAssertGreaterThan(r.end, r.start, "\(label): empty removal", file: fileRef, line: line)
        XCTAssertLessThanOrEqual(r.end, analysis.timelineEnd, "\(label): removal past the end", file: fileRef, line: line)
        for p in analysis.protectedRanges {
            XCTAssertNil(r.intersection(p), "\(label): removal \(r) cuts into protected range \(p)", file: fileRef, line: line)
        }
        previousEnd = r.end
    }

    let data: Data
    do {
        data = try file.documentRemoving(result.removals, from: analysis, newProjectName: project.name + " - Silence Removed")
    } catch SilenceCutError.nothingLeft {
        return nil
    }
    if validate, let errors = try dtdErrors(data) {
        XCTFail("\(label): output is not valid FCPXML:\n\(errors.prefix(1500))", file: fileRef, line: line)
    }

    let output = try FCPXMLFile(data: data)
    XCTAssertEqual(output.projects.count, 1, "\(label): exactly one project should come back", file: fileRef, line: line)
    guard let outProject = output.projects.first else { return nil }
    XCTAssertEqual(outProject.name, project.name + " - Silence Removed", file: fileRef, line: line)
    XCTAssertNil(outProject.element.attr("uid"), "\(label): the copy must not reuse the project's uid", file: fileRef, line: line)

    let outAnalysis = try await output.analyze(project: outProject, scope: settings.scope, provider: provider)

    // The new timeline is exactly as much shorter as was removed, and has no holes.
    XCTAssertEqual(outAnalysis.duration, analysis.duration - result.removedDuration, "\(label): wrong new duration", file: fileRef, line: line)
    XCTAssertEqual(outAnalysis.timelineStart, analysis.timelineStart, "\(label): timeline start moved", file: fileRef, line: line)
    if let original = project.sequence.time("duration"), let new = outProject.sequence.time("duration") {
        XCTAssertEqual(new, original - result.removedDuration, "\(label): sequence duration attribute", file: fileRef, line: line)
    }
    var cursor = outAnalysis.timelineStart
    let originalOnGrid = analysis.items.allSatisfy { ($0.timing.offset / fd).den == 1 && ($0.timing.duration / fd).den == 1 }
    for item in outAnalysis.items where !item.isTransition {
        XCTAssertEqual(item.timing.offset, cursor, "\(label): gap or overlap in primary storyline at \(cursor.seconds)", file: fileRef, line: line)
        cursor = item.range.end
        if originalOnGrid {
            XCTAssertEqual((item.timing.offset / fd).den, 1, "\(label): clip offset off the frame grid", file: fileRef, line: line)
            XCTAssertEqual((item.timing.duration / fd).den, 1, "\(label): clip duration off the frame grid", file: fileRef, line: line)
        }
    }
    for item in outAnalysis.items where item.isTransition {
        XCTAssertGreaterThanOrEqual(item.timing.offset, outAnalysis.timelineStart, file: fileRef, line: line)
        XCTAssertLessThanOrEqual(item.range.end, outAnalysis.timelineEnd, "\(label): transition hangs off the end", file: fileRef, line: line)
    }
    XCTAssertEqual(outAnalysis.items.filter(\.isTransition).count, analysis.items.filter(\.isTransition).count,
                   "\(label): transitions lost", file: fileRef, line: line)

    // What you hear at every surviving moment is what you heard there before.
    let before = analysis.displayLevels(buckets: analysis.hopCount)
    let after = outAnalysis.displayLevels(buckets: outAnalysis.hopCount)
    let hop = TimelineAnalysis.hop
    let start = analysis.timelineStart.seconds
    /// Original timeline time for a time on the new timeline.
    let removalSeconds = result.removals.map { (start: $0.start.seconds, duration: $0.duration.seconds) }
    func originalTime(_ newTime: Double) -> Double {
        var t = newTime
        for r in removalSeconds {
            if r.start <= t + 1e-9 { t += r.duration } else { break }
        }
        return t
    }
    var mismatches = 0
    for h in 0..<outAnalysis.hopCount {
        // A hop that straddles a cut hears a little of both sides, so look around both ends.
        var lo = Float.infinity, hi = -Float.infinity
        for edge in [0.001, 0.999] {
            let oldHop = Int(((originalTime(start + (Double(h) + edge) * hop) - start) / hop).rounded(.down))
            for k in max(0, oldHop - 2)...max(0, min(before.count - 1, oldHop + 2)) {
                lo = min(lo, before[k]); hi = max(hi, before[k])
            }
        }
        // Hops at the edge of a piece cover less audio, so allow a few dB; a real timing error
        // (one frame is over three hops) moves speech by tens of dB and trips this everywhere.
        if after[h] < lo - 3 || after[h] > hi + 3 {
            mismatches += 1
            if ProcessInfo.processInfo.environment["SC_DEBUG"] != nil, mismatches < 25 {
                print(String(format: "[mismatch] %@ new hop %d (t=%.2f, orig t=%.2f): after %.1f, before range %.1f…%.1f", label, h,
                             Double(h) * hop, originalTime(start + (Double(h) + 0.5) * hop) - start, after[h], lo, hi))
            }
        }
    }
    XCTAssertLessThanOrEqual(mismatches, max(2, outAnalysis.hopCount / 300),
                             "\(label): audio after the cut differs from the original at \(mismatches) of \(outAnalysis.hopCount) points",
                             file: fileRef, line: line)

    return CutOutcome(analysis: analysis, result: result, output: output, outputAnalysis: outAnalysis, data: data)
}

/// Clips connected directly to the primary storyline.
func connectedClips(in project: FCPXMLFile.Project) -> [XMLElement] {
    project.spine.elementChildren.flatMap { item in
        item.elementChildren.filter { FCPTag.story.contains($0.tag) && $0.isAnchored }
    }
}
