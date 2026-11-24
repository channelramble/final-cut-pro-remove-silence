import XCTest
@testable import SilenceCutCore

/// Runs the cutter over real Final Cut Pro exports (compound clips, multicam, sync clips,
/// auditions, transitions, retimed and rate-conformed media, captions, secondary storylines…)
/// with fake audio, and checks the structural guarantees on every one of them.
final class SampleProjectTests: XCTestCase {
    private func sampleFiles() throws -> [URL] {
        try XCTSkipUnless(Paths.hasSamples, "sample exports not downloaded")
        return try FileManager.default.contentsOfDirectory(at: Paths.samples, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "fcpxml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func run(scope: DetectionScope) async throws {
        var settings = SilenceSettings.default
        settings.autoThreshold = false
        settings.thresholdDB = -40
        settings.padding = 0.1
        settings.scope = scope
        var processed = 0, totalCuts = 0
        for url in try sampleFiles() {
            let file = try FCPXMLFile(contentsOf: url)
            // The one hand-written sample that doesn't follow the DTD to begin with.
            let validate = try dtdErrors(Data(contentsOf: url)) == nil
            for project in file.projects {
                let label = "\(url.lastPathComponent)/\(project.name)/\(scope.rawValue)"
                let connectedBefore = connectedClips(in: project)
                guard let outcome = try await cutAndVerify(file, project: project, settings: settings,
                                                           provider: SyntheticProvider(), label: label, validate: validate) else { continue }
                processed += 1
                totalCuts += outcome.result.cutCount
                if scope == .primaryStoryline {
                    // Connected clips are never dropped or duplicated when only the primary storyline is analyzed.
                    let after = connectedClips(in: outcome.output.projects[0])
                    XCTAssertEqual(after.count, connectedBefore.count, "\(label): connected clips lost or duplicated")
                    XCTAssertEqual(after.map { $0.attr("name") ?? "" }.sorted(), connectedBefore.map { $0.attr("name") ?? "" }.sorted(), label)
                }
            }
        }
        print("[samples] scope=\(scope.rawValue): \(processed) projects cut, \(totalCuts) cuts in total")
        XCTAssertGreaterThan(processed, 15, "expected most sample projects to have cuttable audio")
        XCTAssertGreaterThan(totalCuts, 50)
    }

    func testPrimaryStorylineScope() async throws { try await run(scope: .primaryStoryline) }
    func testAllClipsScope() async throws { try await run(scope: .allClips) }

    func testEveryProjectIsFound() throws {
        var names: [String] = []
        for url in try sampleFiles() {
            names.append(contentsOf: try FCPXMLFile(contentsOf: url).projects.map(\.name))
        }
        XCTAssertGreaterThan(names.count, 30)
    }
}
