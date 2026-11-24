import XCTest
@testable import SilenceCutCore

/// End-to-end tests on real audio files decoded with AVFoundation.
/// The media is synthetic speech with pauses of known length (scripts/make-test-media.sh).
final class MediaTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(Paths.hasMedia, "run scripts/make-test-media.sh to generate the test media")
    }

    private func mediaURL(_ name: String) -> String { Paths.media.appendingPathComponent(name).absoluteString }

    private var mediaDuration: Double {
        Double((try? String(contentsOf: Paths.media.appendingPathComponent("duration.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 41.9
    }

    /// A 30 fps project whose primary storyline is `spine`.
    private func project(assets: [(id: String, file: String, hasVideo: Bool)], spine: String, frames: Int,
                         sequenceFormat: String = "r1") throws -> FCPXMLFile {
        let assetXML = assets.map { a in
            """
            <asset id="\(a.id)" name="\(a.file)" uid="UID-\(a.file)" start="0s" duration="\(Int(mediaDuration * 30))/30s" \(a.hasVideo ? "hasVideo=\"1\" format=\"r1\" videoSources=\"1\"" : "") hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000">
                <media-rep kind="original-media" src="\(mediaURL(a.file))"/>
            </asset>
            """
        }.joined(separator: "\n")
        return try FCPXMLFile(data: Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>

        <fcpxml version="1.13">
            <resources>
                <format id="r1" name="FFVideoFormat720p30" frameDuration="100/3000s" width="1280" height="720" colorSpace="1-1-1 (Rec. 709)"/>
                <format id="r24" name="FFVideoFormat720p24" frameDuration="100/2400s" width="1280" height="720" colorSpace="1-1-1 (Rec. 709)"/>
                <format id="r2398" name="FFVideoFormat720p2398" frameDuration="1001/24000s" width="1280" height="720" colorSpace="1-1-1 (Rec. 709)"/>
                \(assetXML)
            </resources>
            <library location="file:///Users/me/Movies/Lib.fcpbundle/">
                <event name="Event" uid="E1">
                    <project name="Talk" uid="P1">
                        <sequence format="\(sequenceFormat)" duration="\(frames)/30s" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                            <spine>
        \(spine)
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """.utf8))
    }

    private func singleClip(_ file: String, hasVideo: Bool = true) throws -> FCPXMLFile {
        let frames = Int(mediaDuration * 30)
        return try project(assets: [("r2", file, hasVideo)],
                           spine: #"<asset-clip ref="r2" offset="0s" name="talk" duration="\#(frames)/30s" audioRole="dialogue"/>"#, frames: frames)
    }

    /// Where the clean recording contains sound louder than `level`, per 10 ms hop.
    /// The voice sits around -16 dB, so -35 dB is clearly audible speech and -50 dB is the
    /// very last of a word fading out.
    private func speechMask(above level: Float = -35) async throws -> [Bool] {
        let url = Paths.media.appendingPathComponent("speech_clean.wav")
        let envelope = try await AVFoundationEnvelopeProvider().envelope(
            for: MediaRequest(url: url, bookmark: nil, range: 0...mediaDuration), hop: TimelineAnalysis.hop) { _ in }
        return envelope.levels.map { $0 > level }
    }

    private func removedMask(_ result: DetectionResult, hops: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: hops)
        for r in result.removals {
            let a = max(0, Int((r.start.seconds / TimelineAnalysis.hop).rounded(.up)))
            let b = min(hops, Int((r.end.seconds / TimelineAnalysis.hop).rounded(.down)))
            if b > a { for h in a..<b { mask[h] = true } }
        }
        return mask
    }

    // MARK: - The default settings on real speech

    func testDefaultsRemoveSilenceWithoutTouchingSpeech() async throws {
        let speech = try await speechMask()
        let faint = try await speechMask(above: -50)
        let silenceSeconds = Double(faint.filter { !$0 }.count) * TimelineAnalysis.hop
        // Quiet studio, ordinary room, noisy room; lossless and AAC-in-MOV.
        for file in ["speech_studio.wav", "speech_room.wav", "speech_noisy.wav", "talk_studio.mov", "talk_room.mov", "talk_noisy.mov"] {
            let fcpxml = try singleClip(file, hasVideo: file.hasSuffix(".mov"))
            let outcome = try await cutAndVerify(fcpxml, project: fcpxml.projects[0], settings: .default,
                                                 provider: AVFoundationEnvelopeProvider(), label: file)
            let result = try XCTUnwrap(outcome?.result, "\(file): nothing was cut")
            let removed = removedMask(result, hops: speech.count)

            // No false positives: not a single moment of audible speech is removed.
            let speechCut = zip(speech, removed).filter { $0 && $1 }.count
            XCTAssertEqual(speechCut, 0, "\(file): \(Double(speechCut) * TimelineAnalysis.hop) s of speech was cut")

            // The presets cut tight on purpose — the cut lands while the last of a word is still
            // fading — but what they trim is only that faint tail: a few hundredths of a second
            // of audio more than 35 dB below the voice, across the whole recording.
            let faintCut = zip(faint, removed).filter { $0 && $1 }.count
            XCTAssertLessThanOrEqual(faintCut, 5, "\(file): \(Double(faintCut) * TimelineAnalysis.hop) s of fading speech was cut")

            // And it is effective: most of the dead air is gone, including every long pause.
            XCTAssertGreaterThan(result.removedDuration.seconds, silenceSeconds * 0.6,
                                 "\(file): only \(result.removedDuration.seconds) s of \(silenceSeconds) s silence removed")
            XCTAssertGreaterThanOrEqual(result.cutCount, 8, file)

            // After the cut, no pause longer than the minimum is left.
            var manual = SilenceSettings.default
            manual.autoThreshold = false
            manual.thresholdDB = result.displayThresholdDB
            let leftover = SilenceDetector.detect(outcome!.outputAnalysis, settings: manual)
            XCTAssertLessThanOrEqual(leftover.cutCount, 1, "\(file): silences remain after cutting")
            print(String(format: "[media] %@: threshold %.1f dB, %d cuts, removed %.1f s of %.1f s silence", file,
                         result.displayThresholdDB, result.cutCount, result.removedDuration.seconds, silenceSeconds))
        }
    }

    func testManualThresholdDefaultIsSafeOnOrdinaryRecordings() async throws {
        let speech = try await speechMask()
        var settings = SilenceSettings.default
        settings.autoThreshold = false          // the manual slider's starting value, -35 dB
        for file in ["speech_studio.wav", "speech_room.wav", "speech_noisy.wav"] {
            let fcpxml = try singleClip(file, hasVideo: false)
            let analysis = try await fcpxml.analyze(project: fcpxml.projects[0], scope: .primaryStoryline)
            let result = SilenceDetector.detect(analysis, settings: settings)
            let removed = removedMask(result, hops: speech.count)
            XCTAssertEqual(zip(speech, removed).filter { $0 && $1 }.count, 0, "\(file): speech cut at -35 dB")
            XCTAssertGreaterThanOrEqual(result.cutCount, 8, file)
        }
    }

    func testShortPausesBetweenWordsSurvive() async throws {
        let fcpxml = try singleClip("speech_room.wav", hasVideo: false)
        let analysis = try await fcpxml.analyze(project: fcpxml.projects[0], scope: .primaryStoryline)
        let relaxed = SilenceDetector.detect(analysis, settings: .default)
        var aggressive = SilenceSettings.default
        aggressive.minimumSilence = 0.2
        aggressive.padding = 0.05
        let tight = SilenceDetector.detect(analysis, settings: aggressive)
        XCTAssertGreaterThan(tight.cutCount, relaxed.cutCount, "a shorter minimum silence should find the short pauses too")
        XCTAssertGreaterThan(tight.removedDuration, relaxed.removedDuration)
    }

    func testAACAndPCMAgreeOnWhereTheCutsAre() async throws {
        // Compressed audio has encoder delay; cut points must still land on the same frames.
        let wav = try singleClip("speech_room.wav", hasVideo: false)
        let mov = try singleClip("talk_room.mov")
        let a = SilenceDetector.detect(try await wav.analyze(project: wav.projects[0], scope: .primaryStoryline), settings: .default)
        let b = SilenceDetector.detect(try await mov.analyze(project: mov.projects[0], scope: .primaryStoryline), settings: .default)
        XCTAssertEqual(a.cutCount, b.cutCount)
        for (x, y) in zip(a.removals, b.removals) {
            XCTAssertEqual(x.start.seconds, y.start.seconds, accuracy: 0.07)
            XCTAssertEqual(x.end.seconds, y.end.seconds, accuracy: 0.07)
        }
    }

    // MARK: - Things that are not silence

    func testMusicAndAmbienceAreNotSilence() async throws {
        let frames = Int(mediaDuration * 30)
        // A music clip and a quiet B-roll clip sit in the primary storyline around the talking head.
        let spine = """
        <asset-clip ref="r3" offset="0s" name="music" duration="300/30s" audioRole="music"/>
        <asset-clip ref="r2" offset="300/30s" name="talk" duration="\(frames)/30s" audioRole="dialogue"/>
        <asset-clip ref="r4" offset="\(frames + 300)/30s" name="broll" duration="450/30s" audioRole="dialogue"/>
        """
        let fcpxml = try project(assets: [("r2", "talk_room.mov", true), ("r3", "music.wav", false), ("r4", "broll.mov", true)],
                                 spine: spine, frames: frames + 750)
        let outcome = try await cutAndVerify(fcpxml, project: fcpxml.projects[0], settings: .default,
                                             provider: AVFoundationEnvelopeProvider(), label: "music+broll")
        let result = try XCTUnwrap(outcome?.result)
        let talk = 10.0...(10.0 + mediaDuration)
        for r in result.removals {
            XCTAssertTrue(talk.contains(r.start.seconds) && talk.contains(r.end.seconds),
                          "cut \(r) falls in the music or the B-roll, which have no speech-style silences")
        }
        let names = outcome!.output.projects[0].spine.elementChildren.map { $0.attr("name") ?? "" }
        XCTAssertEqual(names.first, "music")
        XCTAssertEqual(names.last, "broll")
        XCTAssertEqual(names.filter { $0 == "music" }.count, 1)
        XCTAssertEqual(names.filter { $0 == "broll" }.count, 1)
    }

    // MARK: - Timing edge cases on real media

    func testRateConformedClip() async throws {
        // 23.98 fps media in a 24 fps project plays 0.1 % fast; cuts must follow the audio exactly.
        let frames = Int(mediaDuration * 24 / 1.001) - 2
        let spine = """
        <asset-clip ref="r2" offset="0s" name="talk" duration="\(frames)/24s" format="r2398" audioRole="dialogue">
            <conform-rate srcFrameRate="23.98"/>
        </asset-clip>
        """
        let fcpxml = try project(assets: [("r2", "talk_room_2398.mov", true)], spine: spine, frames: frames * 30 / 24, sequenceFormat: "r24")
        let outcome = try await cutAndVerify(fcpxml, project: fcpxml.projects[0], settings: .default,
                                             provider: AVFoundationEnvelopeProvider(), label: "conform")
        let result = try XCTUnwrap(outcome?.result)
        XCTAssertGreaterThanOrEqual(result.cutCount, 8)
        // Every piece starts on a whole source frame.
        let sourceFrame = RationalTime(1001, 24000)
        for clip in outcome!.output.projects[0].spine.elementChildren {
            XCTAssertEqual(((clip.time("start") ?? .zero) / sourceFrame).den, 1, "start \(clip.attr("start") ?? "") is off the media's frame grid")
        }
        // Cut positions are 0.1 % earlier on the timeline than in the media.
        let plain = try singleClip("talk_room.mov")
        let reference = SilenceDetector.detect(try await plain.analyze(project: plain.projects[0], scope: .primaryStoryline), settings: .default)
        XCTAssertEqual(reference.cutCount, result.cutCount)
        if let lastConformed = result.removals.dropLast().last, let lastPlain = reference.removals.dropLast().last {
            XCTAssertEqual(lastConformed.start.seconds, lastPlain.start.seconds / 1.001, accuracy: 0.06)
        }
    }

    func testRetimedClip() async throws {
        // The clip plays at 125 %: 10 s of timeline covers 12.5 s of media.
        let duration = mediaDuration
        let frames = Int(duration / 1.25 * 30) - 1
        let spine = """
        <asset-clip ref="r2" offset="0s" name="talk" duration="\(frames)/30s" audioRole="dialogue">
            <timeMap>
                <timept time="0s" value="0s" interp="smooth2"/>
                <timept time="\(Int(duration / 1.25 * 3000))/3000s" value="\(Int(duration * 3000))/3000s" interp="smooth2"/>
            </timeMap>
        </asset-clip>
        """
        let fcpxml = try project(assets: [("r2", "talk_room.mov", true)], spine: spine, frames: frames)
        let outcome = try await cutAndVerify(fcpxml, project: fcpxml.projects[0], settings: .default,
                                             provider: AVFoundationEnvelopeProvider(), label: "retimed")
        let result = try XCTUnwrap(outcome?.result)
        let plain = try singleClip("talk_room.mov")
        let reference = SilenceDetector.detect(try await plain.analyze(project: plain.projects[0], scope: .primaryStoryline), settings: .default)
        // The long pauses are found at 1/1.25 of their media position.
        let long = reference.removals.filter { $0.duration.seconds > 1.5 }
        for r in long {
            let expected = (r.start.seconds + r.end.seconds) / 2 / 1.25
            XCTAssertTrue(result.removals.contains { $0.start.seconds < expected && $0.end.seconds > expected },
                          "pause at media time \(r) not found at \(expected) on the retimed timeline")
        }
    }

    func testUnreadableMediaIsReportedAndLeftAlone() async throws {
        let frames = Int(mediaDuration * 30)
        let spine = """
        <asset-clip ref="r2" offset="0s" name="talk" duration="\(frames)/30s" audioRole="dialogue"/>
        <asset-clip ref="r3" offset="\(frames)/30s" name="missing" duration="300/30s" audioRole="dialogue"/>
        """
        let fcpxml = try project(assets: [("r2", "talk_room.mov", true), ("r3", "does_not_exist.mov", true)], spine: spine, frames: frames + 300)
        let analysis = try await fcpxml.analyze(project: fcpxml.projects[0], scope: .primaryStoryline)
        XCTAssertEqual(analysis.unreadableMedia, ["does_not_exist.mov"])
        let result = SilenceDetector.detect(analysis, settings: .default)
        XCTAssertGreaterThan(result.cutCount, 0)
        XCTAssertTrue(result.removals.allSatisfy { $0.end.seconds <= mediaDuration + 0.001 }, "the unreadable clip must not be cut")
    }

    func testAnalysisSpeed() async throws {
        let fcpxml = try singleClip("talk_room.mov")
        let started = Date()
        _ = try await fcpxml.analyze(project: fcpxml.projects[0], scope: .primaryStoryline)
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "[media] analyzed %.0f s of AAC audio in %.2f s (%.0fx realtime)", mediaDuration, elapsed, mediaDuration / elapsed))
        XCTAssertLessThan(elapsed, 5)
    }
}
