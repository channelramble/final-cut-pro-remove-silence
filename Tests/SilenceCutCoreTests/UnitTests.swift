import XCTest
@testable import SilenceCutCore

final class RationalTimeTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(RationalTime(fcpxml: "1001/30000s"), RationalTime(1001, 30000))
        XCTAssertEqual(RationalTime(fcpxml: "3600s"), RationalTime(3600))
        XCTAssertEqual(RationalTime(fcpxml: "76000/2400s"), RationalTime(95, 3))
        XCTAssertEqual(RationalTime(fcpxml: "1.5s"), RationalTime(3, 2))
        XCTAssertEqual(RationalTime(fcpxml: "0s"), .zero)
        XCTAssertNil(RationalTime(fcpxml: "abc"))
        XCTAssertNil(RationalTime(fcpxml: nil))
        XCTAssertNil(RationalTime(fcpxml: "5/0s"))
    }

    func testFormatting() {
        XCTAssertEqual(RationalTime(3600).fcpxmlString, "3600s")
        XCTAssertEqual(RationalTime(2002, 60000).fcpxmlString, "1001/30000s")
        XCTAssertEqual(RationalTime(-1, 2).fcpxmlString, "-1/2s")
    }

    func testArithmeticStaysExact() {
        let frame = RationalTime(1001, 30000)
        var t = RationalTime.zero
        for _ in 0..<107892 { t += frame }      // one hour of 29.97 frames
        XCTAssertEqual(t, frame * RationalTime(107892))
        XCTAssertEqual((t / frame).den, 1)
        XCTAssertEqual(t - t, .zero)
        // Mixed audio-sample and frame denominators with hour-sized values.
        let a = RationalTime(172972800, 48000) + RationalTime(1001, 24000) * RationalTime(86400)
        XCTAssertEqual(a.seconds, 3603.6 + 3603.6, accuracy: 1e-9)
    }

    func testRounding() {
        let fd = RationalTime(1, 30)
        XCTAssertEqual(RationalTime(1, 20).roundedDown(toMultipleOf: fd), RationalTime(1, 30))
        XCTAssertEqual(RationalTime(1, 20).roundedUp(toMultipleOf: fd), RationalTime(2, 30))
        XCTAssertEqual(RationalTime(2, 30).roundedUp(toMultipleOf: fd), RationalTime(2, 30))
        XCTAssertEqual(RationalTime(-1, 20).roundedDown(toMultipleOf: fd), RationalTime(-2, 30))
    }

    func testRangeSubtraction() {
        func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: RationalTime(a), end: RationalTime(b)) }
        XCTAssertEqual(TimeRanges.subtract([r(2, 3), r(5, 7)], from: r(0, 10)), [r(0, 2), r(3, 5), r(7, 10)])
        XCTAssertEqual(TimeRanges.subtract([r(0, 3)], from: r(0, 10)), [r(3, 10)])
        XCTAssertEqual(TimeRanges.subtract([r(0, 10)], from: r(2, 4)), [])
        XCTAssertEqual(TimeRanges.subtract([r(8, 12)], from: [r(0, 9), r(10, 20)]), [r(0, 8), r(12, 20)])
        XCTAssertEqual(TimeRanges.normalized([r(5, 7), r(1, 3), r(3, 4), r(6, 9), r(2, 2)]), [r(1, 4), r(5, 9)])
    }
}

final class TimeChainTests: XCTestCase {
    func testAffineAndInverse() {
        let chain = TimeChain.identity.appendingAffine(scale: 1, offset: -3600).appendingAffine(scale: 2, offset: 10)
        XCTAssertEqual(chain.apply(3605), 20, accuracy: 1e-9)
        let inverse = chain.inverseInterval(20, 30)!
        XCTAssertEqual(inverse.0, 3605, accuracy: 1e-9)
        XCTAssertEqual(inverse.1, 3610, accuracy: 1e-9)
    }

    func testTimeMap() {
        // 200% speed: 10 s of clip time covers 20 s of media.
        let map = TimeMapFunction(times: [0, 10], values: [0, 20])
        XCTAssertEqual(map.value(at: 2.5), 5, accuracy: 1e-9)
        let hull = map.inverseHull(4, 8)!
        XCTAssertEqual(hull.0, 2, accuracy: 1e-9)
        XCTAssertEqual(hull.1, 4, accuracy: 1e-9)
        // Reverse playback.
        let reverse = TimeMapFunction(times: [0, 10], values: [10, 0])
        let r = reverse.inverseHull(2, 4)!
        XCTAssertEqual(r.0, 6, accuracy: 1e-9)
        XCTAssertEqual(r.1, 8, accuracy: 1e-9)
    }
}

final class AutomaticThresholdTests: XCTestCase {
    private func recording(floor: Float, speech: Float, silenceShare: Double, count: Int = 20000) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { i in
            if Double(i % 1000) / 1000 < silenceShare {
                return floor + Float.random(in: -2...2, using: &generator)
            }
            // Speech levels spread over ~30 dB below the loud parts.
            return speech - Float.random(in: 0...30, using: &generator) * Float.random(in: 0...1, using: &generator)
        }
    }

    func testSitsBetweenNoiseAndSpeech() {
        for (floor, speech) in [(-72.0, -15.0), (-58.0, -18.0), (-45.0, -14.0), (-38.0, -12.0)] as [(Float, Float)] {
            let t = SilenceDetector.automaticThreshold(levels: recording(floor: floor, speech: speech, silenceShare: 0.3))
            XCTAssertGreaterThan(t, floor + 5, "threshold must clear the noise floor (\(floor))")
            XCTAssertLessThan(t, speech - 12, "threshold must stay well below speech (\(speech))")
        }
    }

    func testConstantAudioHasNoSilence() {
        // Music or steady ambience: nothing should fall below the threshold.
        var generator = SystemRandomNumberGenerator()
        let levels = (0..<5000).map { _ in Float(-25) + Float.random(in: -4...4, using: &generator) }
        let t = SilenceDetector.automaticThreshold(levels: levels)
        XCTAssertEqual(levels.filter { $0 < t }.count, 0)
    }

    func testDigitalSilenceDoesNotSkewTheFloor() {
        var levels = recording(floor: -55, speech: -16, silenceShare: 0.3)
        levels.append(contentsOf: [Float](repeating: AudioEnvelope.floorDB, count: 8000))
        let t = SilenceDetector.automaticThreshold(levels: levels)
        XCTAssertGreaterThan(t, -50)
        XCTAssertLessThan(t, -28)
    }
}
