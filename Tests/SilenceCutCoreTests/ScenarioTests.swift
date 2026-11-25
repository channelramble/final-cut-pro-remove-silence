import XCTest
@testable import SilenceCutCore

/// Hand-built projects that pin down specific editing behaviour.
final class ScenarioTests: XCTestCase {
    /// Audio that is loud exactly inside the given file-time ranges.
    struct ScriptedProvider: EnvelopeProvider {
        var loud: [String: [ClosedRange<Double>]]
        /// Audible but quiet audio (-48 dB): word beginnings and endings, breaths, rustling.
        var soft: [String: [ClosedRange<Double>]] = [:]
        /// Clearly audible but well below the voice (-30 dB): a mutter, a sigh, a chair.
        var medium: [String: [ClosedRange<Double>]] = [:]

        func envelope(for request: MediaRequest, hop: Double, progress: @Sendable (Double) -> Void) async throws -> AudioEnvelope {
            let ranges = loud[request.url.lastPathComponent] ?? []
            let softRanges = soft[request.url.lastPathComponent] ?? []
            let mediumRanges = medium[request.url.lastPathComponent] ?? []
            let first = Int((max(0, request.range.lowerBound) / hop).rounded(.down))
            let last = Int((request.range.upperBound / hop).rounded(.up))
            let levels: [Float] = (first..<max(first + 1, last)).map { i in
                let t = (Double(i) + 0.5) * hop
                if ranges.contains(where: { $0.contains(t) }) { return -15 }
                if mediumRanges.contains(where: { $0.contains(t) }) { return -30 }
                return softRanges.contains { $0.contains(t) } ? -48 : -70
            }
            return AudioEnvelope(startTime: Double(first) * hop, hop: hop, levels: levels)
        }
    }

    private func document(spine: String, extraResources: String = "", tcStart: String = "0s", duration: String = "60s") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>

        <fcpxml version="1.13">
            <resources>
                <format id="r1" name="FFVideoFormat1080p30" frameDuration="100/3000s" width="1920" height="1080" colorSpace="1-1-1 (Rec. 709)"/>
                <asset id="r2" name="talk" uid="A1" start="0s" duration="120s" hasVideo="1" format="r1" hasAudio="1" videoSources="1" audioSources="1" audioChannels="2" audioRate="48000">
                    <media-rep kind="original-media" src="file:///media/talk.mov"/>
                </asset>
                <asset id="r3" name="voiceover" uid="A2" start="0s" duration="120s" hasAudio="1" audioSources="1" audioChannels="1" audioRate="48000">
                    <media-rep kind="original-media" src="file:///media/voiceover.wav"/>
                </asset>
                <asset id="r4" name="music" uid="A3" start="0s" duration="300s" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000">
                    <media-rep kind="original-media" src="file:///media/music.wav"/>
                </asset>
                <effect id="r5" name="Basic Title" uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"/>
                <effect id="r6" name="Cross Dissolve" uid="FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265"/>
                \(extraResources)
            </resources>
            <library location="file:///Users/me/Movies/Lib.fcpbundle/">
                <event name="Event" uid="E1">
                    <asset-clip ref="r2" name="talk" duration="120s" format="r1" audioRole="dialogue"/>
                    <project name="Other project" uid="P0">
                        <sequence format="r1" duration="1s" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                            <spine><gap name="Gap" offset="0s" start="0s" duration="1s"/></spine>
                        </sequence>
                    </project>
                    <project name="Scenario" uid="P1" modDate="2026-11-20 07:00:00 -0800">
                        <sequence format="r1" duration="\(duration)" tcStart="\(tcStart)" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                            <spine>
        \(spine)
                            </spine>
                        </sequence>
                    </project>
                </event>
                <smart-collection name="Projects" match="all"><match-clip rule="is" type="project"/></smart-collection>
            </library>
        </fcpxml>
        """.utf8)
    }

    private var settings: SilenceSettings {
        var s = SilenceSettings.default
        s.autoThreshold = false
        s.thresholdDB = -40
        s.padding = 0.1
        return s
    }

    private func project(_ file: FCPXMLFile) -> FCPXMLFile.Project { file.projects.first { $0.name == "Scenario" }! }

    private func seconds(_ el: XMLElement, _ name: String) -> Double { (el.time(name) ?? .zero).seconds }

    // MARK: -

    func testBasicCutSplitsTheClipAndClosesTheGap() async throws {
        // Speech 0–10 and 20–30 in a 30 s clip: the 10 s silence goes, minus padding.
        let data = document(spine: #"<asset-clip ref="r2" offset="0s" name="talk" duration="30s" audioRole="dialogue"/>"#, duration: "30s")
        let file = try FCPXMLFile(data: data)
        let provider = ScriptedProvider(loud: ["talk.mov": [0...10, 20...30]])
        let outcome = try await cutAndVerify(file, project: project(file), settings: settings, provider: provider, label: "basic")!
        XCTAssertEqual(outcome.result.cutCount, 1)
        XCTAssertEqual(outcome.result.removals[0].start.seconds, 10.1, accuracy: 0.034)
        XCTAssertEqual(outcome.result.removals[0].end.seconds, 19.9, accuracy: 0.034)

        let clips = outcome.output.projects[0].spine.elementChildren
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(seconds(clips[0], "offset"), 0)
        XCTAssertEqual(seconds(clips[0], "duration"), 10.1, accuracy: 0.034)
        XCTAssertEqual(seconds(clips[1], "offset"), seconds(clips[0], "duration"), accuracy: 1e-9)
        XCTAssertEqual(seconds(clips[1], "start"), 19.9, accuracy: 0.034, "second piece must start where the silence ended")
        XCTAssertEqual(seconds(clips[1], "duration"), 30 - seconds(clips[1], "start"), accuracy: 1e-9)

        // Only the new project comes back, aimed at the library it came from.
        let root = outcome.output.document.rootElement()!
        XCTAssertEqual(outcome.output.projects.map(\.name), ["Scenario - Silence Removed"])
        XCTAssertEqual(root.firstChild("library")?.firstChild("event")?.elementChildren.count, 1)
        XCTAssertEqual(root.firstChild("library")?.elements(forName: "smart-collection").count, 0)
        let options = root.firstChild("import-options")?.elements(forName: "option") ?? []
        XCTAssertEqual(options.first { $0.attr("key") == "library location" }?.attr("value"), "file:///Users/me/Movies/Lib.fcpbundle/")
        XCTAssertTrue(String(decoding: outcome.data.prefix(60), as: UTF8.self).hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>"))
    }

    func testOriginalDocumentIsNotModified() async throws {
        let data = document(spine: #"<asset-clip ref="r2" offset="0s" name="talk" duration="30s" audioRole="dialogue"/>"#, duration: "30s")
        let file = try FCPXMLFile(data: data)
        let before = file.document.xmlString
        let provider = ScriptedProvider(loud: ["talk.mov": [0...10, 20...30]])
        _ = try await cutAndVerify(file, project: project(file), settings: settings, provider: provider, label: "pure")
        XCTAssertEqual(file.document.xmlString, before)
    }

    func testShortPausesAndLeadingTrailingSilence() async throws {
        // 0–2 silent (leading), speech with a 0.3 s pause at 5.0, silent from 12 to the end.
        let data = document(spine: #"<asset-clip ref="r2" offset="0s" name="talk" duration="20s" audioRole="dialogue"/>"#, duration: "20s")
        let file = try FCPXMLFile(data: data)
        let provider = ScriptedProvider(loud: ["talk.mov": [2...5, 5.3...12]])
        let outcome = try await cutAndVerify(file, project: project(file), settings: settings, provider: provider, label: "edges")!
        XCTAssertEqual(outcome.result.cutCount, 2, "the 0.3 s pause must survive")
        XCTAssertEqual(outcome.result.removals[0].start.seconds, 0, "leading silence is cut right from the start")
        XCTAssertEqual(outcome.result.removals[0].end.seconds, 1.9, accuracy: 0.034)
        XCTAssertEqual(outcome.result.removals[1].start.seconds, 12.1, accuracy: 0.034)
        XCTAssertEqual(outcome.result.removals[1].end.seconds, 20, "trailing silence is cut through to the end")
    }

    func testClicksInsideSilenceAreIgnored() async throws {
        let data = document(spine: #"<asset-clip ref="r2" offset="0s" name="talk" duration="20s" audioRole="dialogue"/>"#, duration: "20s")
        let file = try FCPXMLFile(data: data)
        let provider = ScriptedProvider(loud: ["talk.mov": [0...5, 8...8.04, 12...20]])
        let outcome = try await cutAndVerify(file, project: project(file), settings: settings, provider: provider, label: "click")!
        XCTAssertEqual(outcome.result.cutCount, 1, "a 40 ms click shouldn't split the silence in two")
    }

    // MARK: - Protecting speech and natural pauses

    private func removals(loud: [ClosedRange<Double>], soft: [ClosedRange<Double>] = [], medium: [ClosedRange<Double>] = [],
                          settings: SilenceSettings? = nil) async throws -> [TimeRange] {
        let data = document(spine: #"<asset-clip ref="r2" offset="0s" name="talk" duration="30s" audioRole="dialogue"/>"#, duration: "30s")
        let file = try FCPXMLFile(data: data)
        let provider = ScriptedProvider(loud: ["talk.mov": loud], soft: ["talk.mov": soft], medium: ["talk.mov": medium])
        let analysis = try await file.analyze(project: project(file), scope: .primaryStoryline, provider: provider)
        return SilenceDetector.detect(analysis, settings: settings ?? self.settings).removals
    }

    func testPresets() {
        let presets = SilenceSettings.default
        XCTAssertTrue(presets.autoThreshold)
        XCTAssertEqual(presets.minimumSilence, 0.85, "natural pauses are shorter than this; dead air is longer")
        XCTAssertEqual(presets.padding, 0.03, "tight clip-to-clip pacing")
        XCTAssertEqual(presets.minimumSound, 0.4, "nothing shorter than this is left behind as a clip")
        XCTAssertEqual(presets.scope, .primaryStoryline)
    }

    func testNaturalPausesAreNotCut() async throws {
        // Pauses of 0.4 s and 0.7 s mid-thought, then 3 s of dead air before a retake.
        let cuts = try await removals(loud: [0...5, 5.4...10, 10.7...15, 18...30])
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].start.seconds, 15.1, accuracy: 0.02)
        XCTAssertEqual(cuts[0].end.seconds, 17.9, accuracy: 0.02)
    }

    func testCutsLandRightAgainstTheAudiblePartOfSpeech() async throws {
        // The last word fades for 0.2 s below the silence level and the next one is preceded by
        // a faint breath. Neither holds the cut off: with the presets, each side keeps only the
        // 0.03 s gap (plus at most one 60 fps... here 30 fps frame of rounding).
        let cuts = try await removals(loud: [0...10, 20...30], soft: [10...10.2, 19.8...20], settings: .default)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertGreaterThanOrEqual(cuts[0].start.seconds, 10.03 - 0.001)
        XCTAssertLessThanOrEqual(cuts[0].start.seconds, 10.03 + 1.0 / 30 + 0.011)
        XCTAssertLessThanOrEqual(cuts[0].end.seconds, 19.97 + 0.001)
        XCTAssertGreaterThanOrEqual(cuts[0].end.seconds, 19.97 - 1.0 / 30 - 0.011)
    }

    func testBreathsAndRustlingAreStillSilence() async throws {
        // Quiet noise that never reaches the silence level doesn't interrupt the silence.
        let cuts = try await removals(loud: [0...10, 20...30], soft: [13...14.5])
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].start.seconds, 10.1, accuracy: 0.02)
        XCTAssertEqual(cuts[0].end.seconds, 19.9, accuracy: 0.02)
    }

    func testFinalConsonantIsNotMistakenForAClick() async throws {
        // "…bu-t": a 40 ms burst 80 ms after the word belongs to the word.
        let cuts = try await removals(loud: [0...10, 10.08...10.12, 20...30])
        XCTAssertEqual(cuts.count, 1)
        XCTAssertGreaterThanOrEqual(cuts[0].start.seconds, 10.12 + 0.1 - 0.02, "the consonant must survive")
    }

    func testStrayNoiseBetweenTakesGoesWithTheSilence() async throws {
        // A 0.15 s tap on the desk in the middle of dead air isn't worth a clip of its own…
        let tap = try await removals(loud: [0...10, 14...14.15, 20...30])
        XCTAssertEqual(tap.count, 1)
        XCTAssertEqual(tap[0].duration.seconds, 9.8, accuracy: 0.04)
        // …but a word is.
        let word = try await removals(loud: [0...10, 14...14.6, 20...30])
        XCTAssertEqual(word.count, 2)
    }

    // MARK: - No tiny clips

    func testNoSliverIsLeftWhereTwoClipsMeet() async throws {
        // Clip A ends in silence and clip B starts in silence. The edit point between them is
        // on a frame but not on the analysis grid, which used to leave a few frames of each
        // clip standing there.
        let spine = """
        <asset-clip ref="r2" offset="0s" name="A" duration="601/30s" audioRole="dialogue"/>
        <asset-clip ref="r3" offset="601/30s" name="B" start="50s" duration="599/30s" audioRole="dialogue"/>
        """
        let file = try FCPXMLFile(data: document(spine: spine, duration: "40s"))
        let provider = ScriptedProvider(loud: ["talk.mov": [0...10], "voiceover.wav": [55...70]])
        for presets in [settings, SilenceSettings.default] {
            let outcome = try await cutAndVerify(file, project: project(file), settings: presets, provider: provider, label: "edit point")!
            XCTAssertEqual(outcome.result.cutCount, 1, "one silence, running across the edit point")
            let clips = outcome.output.projects[0].spine.elementChildren
            XCTAssertEqual(clips.map { $0.attr("name") }, ["A", "B"])
            XCTAssertEqual(seconds(clips[0], "duration"), 10, accuracy: 0.15)
            XCTAssertEqual(seconds(clips[1], "start"), 55, accuracy: 0.15)
        }
    }

    func testAccidentalFractionOfASecondClipIsRemoved() async throws {
        // A 0.1 s recording (the record button tapped twice) sitting between two takes: too short
        // to judge on its own, so it is held to the level of the rest and goes with the silence.
        let spine = """
        <asset-clip ref="r2" offset="0s" name="take 1" duration="12s" audioRole="dialogue"/>
        <asset-clip ref="r3" offset="12s" name="oops" duration="3/30s" audioRole="dialogue"/>
        <asset-clip ref="r2" offset="363/30s" name="take 2" start="40s" duration="537/30s" audioRole="dialogue"/>
        """
        let file = try FCPXMLFile(data: document(spine: spine, duration: "30s"))
        let provider = ScriptedProvider(loud: ["talk.mov": [0...10, 42...60]])
        let outcome = try await cutAndVerify(file, project: project(file), settings: .default, provider: provider, label: "tiny clip")!
        XCTAssertEqual(outcome.output.projects[0].spine.elementChildren.map { $0.attr("name") }, ["take 1", "take 2"])
    }

    func testClustersOfClicksAreNotWorthAClip() async throws {
        // Click, click… click: three blips spread over a third of a second.
        let cuts = try await removals(loud: [0...10, 14...14.03, 14.09...14.12, 14.3...14.33, 20...30])
        XCTAssertEqual(cuts.count, 1)
    }

    func testBriefQuietNoiseBetweenTakesIsDropped() async throws {
        // A 0.7 s mutter far below the level of the voice goes with the silence…
        let mutter = try await removals(loud: [0...10, 20...30], medium: [14...14.7])
        XCTAssertEqual(mutter.count, 1)
        // …something that long at speaking level stays…
        let word = try await removals(loud: [0...10, 14...14.7, 20...30])
        XCTAssertEqual(word.count, 2)
        // …and so does a longer quiet passage: it might be someone speaking softly.
        let quietSpeech = try await removals(loud: [0...10, 20...30], medium: [14...16])
        XCTAssertEqual(quietSpeech.count, 2)
    }

    func testNoClipShorterThanTheMinimumIsLeftBetweenCuts() async throws {
        // A mix of debris between takes; every surviving stretch between two cuts is a real one.
        let cuts = try await removals(loud: [0...10, 12...12.2, 14...14.05, 16...16.3, 18...18.9, 22...30], settings: .default)
        let kept = zip(cuts, cuts.dropFirst()).map { $1.start.seconds - $0.end.seconds }
        XCTAssertEqual(kept.count, 1, "only the 0.9 s stretch survives")
        XCTAssertTrue(kept.allSatisfy { $0 >= SilenceSettings.default.minimumSound })
    }

    func testShortWordBetweenNaturalPausesIsKept() async throws {
        // "…that's it. (pause) So, (pause) the next one…" — nothing here is dead air.
        let cuts = try await removals(loud: [0...10, 10.4...10.6, 11.1...30])
        XCTAssertEqual(cuts.count, 0)
    }

    func testMarkersFollowTheirContent() async throws {
        let spine = """
        <asset-clip ref="r2" offset="0s" name="talk" duration="30s" audioRole="dialogue">
            <marker start="5s" duration="100/3000s" value="in first speech"/>
            <marker start="15s" duration="100/3000s" value="in silence"/>
            <chapter-marker start="25s" duration="100/3000s" value="in second speech" posterOffset="11/30s"/>
            <audio-channel-source srcCh="1, 2" role="dialogue.dialogue-1"/>
        </asset-clip>
        """
        let file = try FCPXMLFile(data: document(spine: spine, duration: "30s"))
        let provider = ScriptedProvider(loud: ["talk.mov": [0...10, 20...30]])
        let outcome = try await cutAndVerify(file, project: project(file), settings: settings, provider: provider, label: "markers")!
        let clips = outcome.output.projects[0].spine.elementChildren
        XCTAssertEqual(clips.count, 2)
        let first = clips[0].elementChildren.filter { FCPTag.marker.contains($0.tag) }
        let second = clips[1].elementChildren.filter { FCPTag.marker.contains($0.tag) }
        XCTAssertEqual(first.map { $0.attr("value") }, ["in first speech"])
        XCTAssertEqual(second.map { $0.attr("value") }, ["in silence", "in second speech"])
        XCTAssertEqual(seconds(first[0], "start"), 5)
        XCTAssertEqual(seconds(second[0], "start"), seconds(clips[1], "start"), "marker from the removed silence lands on the cut")
        XCTAssertEqual(seconds(second[1], "start"), 25, "media time of a surviving marker never changes")
        // Markers must come before audio-channel-source (DTD order) — covered by validation in cutAndVerify.
    }

    func testConnectedClipsStayWholeAndStayInSync() async throws {
        // Music under everything, a title over the second sentence, a title sitting in the silence.
        let spine = """
        <asset-clip ref="r2" offset="0s" name="talk" duration="30s" audioRole="dialogue">
            <asset-clip ref="r4" lane="-1" offset="0s" name="music" duration="30s" audioRole="music"/>
            <title ref="r5" lane="1" offset="22s" name="over speech" start="3600s" duration="5s">
                <text><text-style ref="ts1">Hello</text-style></text>
                <text-style-def id="ts1"><text-style font="Helvetica" fontSize="63" fontColor="1 1 1 1"/></text-style-def>
            </title>
            <title ref="r5" lane="2" offset="14s" name="in silence" start="3600s" duration="4s">
                <text><text-style ref="ts2">There</text-style></text>
                <text-style-def id="ts2"><text-style font="Helvetica" fontSize="63" fontColor="1 1 1 1"/></text-style-def>
            </title>
        </asset-clip>
        """
        let file = try FCPXMLFile(data: document(spine: spine, duration: "30s"))
        let provider = ScriptedProvider(loud: ["talk.mov": [0...10, 20...30], "music.wav": [0...300]])
        let outcome = try await cutAndVerify(file, project: project(file), settings: settings, provider: provider, label: "connected")!
        XCTAssertEqual(outcome.result.cutCount, 1, "connected music must not hide the silence in the primary storyline")
        let clips = outcome.output.projects[0].spine.elementChildren
        XCTAssertEqual(clips.count, 2)
        let firstChildren = clips[0].elementChildren.filter(\.isAnchored)
        let secondChildren = clips[1].elementChildren.filter(\.isAnchored)
        XCTAssertEqual(firstChildren.map { $0.attr("name") }, ["music"])
        XCTAssertEqual(seconds(firstChildren[0], "duration"), 30, "music is not cut")
        XCTAssertEqual(Set(secondChildren.map { $0.attr("name") ?? "" }), ["over speech", "in silence"])
        let overSpeech = secondChildren.first { $0.attr("name") == "over speech" }!
        XCTAssertEqual(seconds(overSpeech, "offset"), 22, "still attached to the same frame of the talking head")
        XCTAssertEqual(seconds(overSpeech, "duration"), 5)
        let inSilence = secondChildren.first { $0.attr("name") == "in silence" }!
        XCTAssertEqual(seconds(inSilence, "offset"), seconds(clips[1], "start"), "moved to the first frame after the cut")
    }

    func testTransitionsAreNeverCutInto() async throws {
        // Silence spans the edit point between two clips that are joined by a 2 s dissolve.
        let spine = """
        <asset-clip ref="r2" offset="0s" name="A" duration="20s" audioRole="dialogue"/>
        <transition name="Cross Dissolve" offset="19s" duration="2s"><filter-video ref="r6" name="Cross Dissolve"/></transition>
        <asset-clip ref="r2" offset="20s" name="B" start="40s" duration="20s" audioRole="dialogue"/>
        """
        let file = try FCPXMLFile(data: document(spine: spine, duration: "40s"))
        let provider = ScriptedProvider(loud: ["talk.mov": [0...12, 48...60]])   // silent from 12 s to 28 s on the timeline
        let outcome = try await cutAndVerify(file, project: project(file), settings: settings, provider: provider, label: "transition")!
        XCTAssertEqual(outcome.result.cutCount, 2)
        XCTAssertEqual(outcome.result.removals[0].end.seconds, 19, "stops where the dissolve begins")
        XCTAssertEqual(outcome.result.removals[1].start.seconds, 21, "resumes where the dissolve ends")
        let out = outcome.output.projects[0].spine.elementChildren
        XCTAssertEqual(out.map(\.tag), ["asset-clip", "asset-clip", "transition", "asset-clip", "asset-clip"])
        // The dissolve still straddles the edit point, with its one-second handles on both sides.
        let edit = seconds(out[3], "offset")
        XCTAssertEqual(seconds(out[2], "offset"), edit - 1, accuracy: 1e-9)
        XCTAssertEqual(seconds(out[1], "duration"), 1, accuracy: 1e-9)
        XCTAssertEqual(seconds(out[3], "duration"), 1, accuracy: 1e-9)
    }

    func testAllClipsScopeCutsConnectedVoiceover() async throws {
        // B-roll gap in the primary storyline with the voice-over connected underneath.
        let spine = """
        <gap name="Gap" offset="0s" start="3600s" duration="30s">
            <asset-clip ref="r3" lane="-1" offset="3600s" name="voiceover" duration="30s" audioRole="dialogue"/>
            <title ref="r5" lane="1" offset="3602s" name="title" start="3600s" duration="20s"/>
        </gap>
        """
        let file = try FCPXMLFile(data: document(spine: spine, duration: "30s"))
        let provider = ScriptedProvider(loud: ["voiceover.wav": [0...10, 20...30]])

        // Primary only: a gap has no audio, so there is nothing to cut.
        let primary = try await file.analyze(project: project(file), scope: .primaryStoryline, provider: provider)
        XCTAssertFalse(primary.hasAudio)

        var all = settings
        all.scope = .allClips
        let outcome = try await cutAndVerify(file, project: project(file), settings: all, provider: provider, label: "voiceover")!
        XCTAssertEqual(outcome.result.cutCount, 1)
        let gaps = outcome.output.projects[0].spine.elementChildren
        XCTAssertEqual(gaps.map(\.tag), ["gap", "gap"])
        let voice = gaps.flatMap { $0.elementChildren.filter { $0.attr("name") == "voiceover" } }
        XCTAssertEqual(voice.count, 2, "the voice-over is cut along with the storyline")
        XCTAssertEqual(seconds(voice[1], "start"), outcome.result.removals[0].end.seconds, accuracy: 1e-9)
        let titles = gaps.flatMap { $0.elementChildren.filter { $0.attr("name") == "title" } }
        XCTAssertEqual(titles.count, 1, "clips without audio stay whole")
        XCTAssertEqual(seconds(titles[0], "duration"), 20)
    }

    func testAllClipsScopeRespectsConnectedMusic() async throws {
        let spine = """
        <asset-clip ref="r2" offset="0s" name="talk" duration="30s" audioRole="dialogue">
            <asset-clip ref="r4" lane="-1" offset="0s" name="music" duration="30s" audioRole="music"/>
        </asset-clip>
        """
        let file = try FCPXMLFile(data: document(spine: spine, duration: "30s"))
        let provider = ScriptedProvider(loud: ["talk.mov": [0...10, 20...30], "music.wav": [0...300]])
        var all = settings
        all.scope = .allClips
        let analysis = try await file.analyze(project: project(file), scope: .allClips, provider: provider)
        XCTAssertEqual(SilenceDetector.detect(analysis, settings: all).cutCount, 0, "with music playing there is no silence")
    }

    func testMutedAndDisabledClipsAreLeftAlone() async throws {
        let spine = """
        <asset-clip ref="r2" offset="0s" name="muted b-roll" duration="10s" audioRole="dialogue"><adjust-volume amount="-96dB"/></asset-clip>
        <asset-clip ref="r2" offset="10s" name="video only" duration="10s" srcEnable="video"/>
        <asset-clip ref="r2" offset="20s" name="disabled" duration="10s" enabled="0"/>
        <title ref="r5" offset="30s" name="title" start="3600s" duration="10s"/>
        <asset-clip ref="r2" offset="40s" name="talk" start="40s" duration="20s" audioRole="dialogue"/>
        """
        let file = try FCPXMLFile(data: document(spine: spine, duration: "60s"))
        let provider = ScriptedProvider(loud: ["talk.mov": [40...45, 55...60]])
        let outcome = try await cutAndVerify(file, project: project(file), settings: settings, provider: provider, label: "muted")!
        XCTAssertEqual(outcome.result.cutCount, 1)
        XCTAssertGreaterThan(outcome.result.removals[0].start.seconds, 40, "silent-by-design clips are not treated as silence")
        XCTAssertEqual(outcome.output.projects[0].spine.elementChildren.map { $0.attr("name") },
                       ["muted b-roll", "video only", "disabled", "title", "talk", "talk"])
    }

    func testClipVolumeCountsInManualMode() async throws {
        // -15 dB audio turned down by 30 dB sits below a -40 dB threshold.
        let spine = """
        <asset-clip ref="r2" offset="0s" name="quiet" duration="10s" audioRole="dialogue"><adjust-volume amount="-30dB"/></asset-clip>
        <asset-clip ref="r2" offset="10s" name="talk" start="10s" duration="10s" audioRole="dialogue"/>
        """
        let file = try FCPXMLFile(data: document(spine: spine, duration: "20s"))
        let provider = ScriptedProvider(loud: ["talk.mov": [0...20]])
        let analysis = try await file.analyze(project: project(file), scope: .primaryStoryline, provider: provider)
        let manual = SilenceDetector.detect(analysis, settings: settings)
        XCTAssertEqual(manual.cutCount, 1)
        XCTAssertEqual(manual.removals[0].start.seconds, 0)
        // Auto mode judges each recording against itself, so turning a clip down changes nothing.
        XCTAssertEqual(SilenceDetector.detect(analysis, settings: .default).cutCount, 0)
    }

    func testSplitEditsKeepTheirAudioOverhang() async throws {
        // L-cut: clip A's audio runs 2 s past its picture.
        let spine = """
        <asset-clip ref="r2" offset="0s" name="A" duration="20s" audioStart="0s" audioDuration="22s" audioRole="dialogue"/>
        <asset-clip ref="r3" offset="20s" name="B" start="50s" duration="20s" audioRole="dialogue"/>
        """
        let file = try FCPXMLFile(data: document(spine: spine, duration: "40s"))
        let provider = ScriptedProvider(loud: ["talk.mov": [0...5, 15...22], "voiceover.wav": [50...70]])
        let outcome = try await cutAndVerify(file, project: project(file), settings: settings, provider: provider, label: "L-cut")!
        XCTAssertEqual(outcome.result.cutCount, 1)
        let clips = outcome.output.projects[0].spine.elementChildren
        XCTAssertEqual(clips.count, 3)
        XCTAssertNil(clips[0].attr("audioStart"), "the first piece no longer reaches the overhang")
        XCTAssertEqual(seconds(clips[1], "audioStart"), seconds(clips[1], "start"), accuracy: 1e-9)
        XCTAssertEqual(seconds(clips[1], "audioDuration"), seconds(clips[1], "duration") + 2, accuracy: 1e-9, "the last piece keeps the 2 s overhang")
    }

    func testFadesStayOnTheOuterEdges() async throws {
        let spine = """
        <asset-clip ref="r2" offset="0s" name="talk" duration="40s" audioRole="dialogue">
            <adjust-volume amount="-3dB">
                <param name="amount"><fadeIn type="easeIn" duration="1s"/><fadeOut type="easeOut" duration="2s"/></param>
            </adjust-volume>
        </asset-clip>
        """
        let file = try FCPXMLFile(data: document(spine: spine, duration: "40s"))
        let provider = ScriptedProvider(loud: ["talk.mov": [0...10, 15...25, 30...40]])
        let outcome = try await cutAndVerify(file, project: project(file), settings: settings, provider: provider, label: "fades")!
        let clips = outcome.output.projects[0].spine.elementChildren
        XCTAssertEqual(clips.count, 3)
        func fades(_ clip: XMLElement) -> [String] {
            ((try? clip.nodes(forXPath: ".//fadeIn | .//fadeOut")) ?? []).compactMap { $0.name }
        }
        XCTAssertEqual(fades(clips[0]), ["fadeIn"])
        XCTAssertEqual(fades(clips[1]), [])
        XCTAssertEqual(fades(clips[2]), ["fadeOut"])
        XCTAssertEqual(clips.map { $0.firstChild("adjust-volume")?.attr("amount") }, ["-3dB", "-3dB", "-3dB"])
    }

    func testTimecodeStartAndNTSCFrameRate() async throws {
        let ntsc = """
        <format id="r9" name="FFVideoFormat1080p2997" frameDuration="1001/30000s" width="1920" height="1080"/>
        <asset id="r10" name="ntsc" uid="A9" start="0s" duration="120s" hasVideo="1" format="r9" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000">
            <media-rep kind="original-media" src="file:///media/ntsc.mov"/>
        </asset>
        """
        let data = String(decoding: document(spine: #"<asset-clip ref="r10" offset="108108000/30000s" name="ntsc" duration="900900/30000s" format="r9" audioRole="dialogue"/>"#,
                                             extraResources: ntsc, tcStart: "108108000/30000s", duration: "900900/30000s"), as: UTF8.self)
            .replacingOccurrences(of: #"<sequence format="r1" duration="900900/30000s""#, with: #"<sequence format="r9" duration="900900/30000s""#)
        let file = try FCPXMLFile(data: Data(data.utf8))
        let provider = ScriptedProvider(loud: ["ntsc.mov": [0...10, 20...30.03]])
        let outcome = try await cutAndVerify(file, project: project(file), settings: settings, provider: provider, label: "ntsc")!
        XCTAssertEqual(outcome.result.cutCount, 1)
        let fd = RationalTime(1001, 30000)
        for clip in outcome.output.projects[0].spine.elementChildren {
            XCTAssertEqual((clip.time("offset")! / fd).den, 1)
            XCTAssertEqual((clip.time("duration")! / fd).den, 1)
        }
        XCTAssertEqual(outcome.output.projects[0].spine.elementChildren[0].time("offset"), RationalTime(108108000, 30000))
    }

    func testEverythingSilentIsAnError() async throws {
        let data = document(spine: #"<asset-clip ref="r2" offset="0s" name="talk" duration="30s" audioRole="dialogue"/>"#, duration: "30s")
        let file = try FCPXMLFile(data: data)
        let analysis = try await file.analyze(project: project(file), scope: .primaryStoryline, provider: ScriptedProvider(loud: [:]))
        let result = SilenceDetector.detect(analysis, settings: settings)
        XCTAssertEqual(result.removedDuration.seconds, 30)
        XCTAssertThrowsError(try file.documentRemoving(result.removals, from: analysis, newProjectName: "x")) { error in
            guard case SilenceCutError.nothingLeft = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testNotFCPXML() {
        XCTAssertThrowsError(try FCPXMLFile(data: Data("hello".utf8)))
        XCTAssertThrowsError(try FCPXMLFile(data: Data("<xmeml version=\"5\"/>".utf8)))
    }

    func testTextAndWhitespaceAreByteStable() async throws {
        // A title whose text runs include a space-only run, entities and non-ASCII characters.
        let spine = """
        <asset-clip ref="r2" offset="0s" name="talk &amp; &quot;more&quot; &lt;é&gt;" duration="30s" audioRole="dialogue">
            <title ref="r5" lane="1" offset="1s" name="t" start="3600s" duration="5s">
                <text><text-style ref="ts1">Hello</text-style><text-style ref="ts2"> </text-style><text-style ref="ts1">Wörld  &amp; co </text-style></text>
                <text-style-def id="ts1"><text-style font="Helvetica" fontSize="63"/></text-style-def>
                <text-style-def id="ts2"><text-style font="Helvetica" fontSize="20"/></text-style-def>
            </title>
        </asset-clip>
        """
        let file = try FCPXMLFile(data: document(spine: spine, duration: "30s"))
        let provider = ScriptedProvider(loud: ["talk.mov": [0...10, 20...30]])
        let outcome = try await cutAndVerify(file, project: project(file), settings: settings, provider: provider, label: "text")!
        let text = String(decoding: outcome.data, as: UTF8.self)
        XCTAssertTrue(text.contains(#"<text><text-style ref="ts1">Hello</text-style><text-style ref="ts2"> </text-style><text-style ref="ts1">Wörld  &amp; co </text-style></text>"#))
        XCTAssertTrue(text.contains(#"name="talk &amp; &quot;more&quot; &lt;é&gt;""#))
        XCTAssertTrue(text.contains(#"<text-style font="Helvetica" fontSize="63"/>"#), "empty elements stay self-closing")
    }

    func testMultiLineAttributesSurvive() async throws {
        let spine = """
        <asset-clip ref="r2" offset="0s" name="talk" duration="30s" audioRole="dialogue">
            <note>line one&#10;line two</note>
            <marker start="5s" duration="100/3000s" value="first&#10;second" note="a&#9;b"/>
        </asset-clip>
        """
        let file = try FCPXMLFile(data: document(spine: spine, duration: "30s"))
        let provider = ScriptedProvider(loud: ["talk.mov": [0...10, 20...30]])
        let outcome = try await cutAndVerify(file, project: project(file), settings: settings, provider: provider, label: "multiline")!
        let marker = outcome.output.projects[0].spine.elementChildren[0].firstChild("marker")!
        XCTAssertEqual(marker.attr("value"), "first\nsecond")
        XCTAssertEqual(marker.attr("note"), "a\tb")
    }
}
