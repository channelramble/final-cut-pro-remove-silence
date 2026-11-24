import Foundation
import AVFoundation
import Accelerate

/// Loudness of a media file over time: one RMS level (dBFS) per `hop` seconds,
/// taking the loudest channel so a mic recorded on a single channel still counts.
public struct AudioEnvelope: Sendable {
    public static let floorDB: Float = -160

    /// File time of the first value.
    public let startTime: Double
    public let hop: Double
    public let levels: [Float]

    public init(startTime: Double, hop: Double, levels: [Float]) {
        self.startTime = startTime
        self.hop = hop
        self.levels = levels
    }

    public var endTime: Double { startTime + Double(levels.count) * hop }

    /// Loudest level between two file times.
    public func maxLevel(from a: Double, to b: Double) -> Float {
        let lo = min(a, b), hi = max(a, b)
        var i0 = Int(((lo - startTime) / hop).rounded(.down))
        var i1 = Int(((hi - startTime) / hop - 1e-9).rounded(.down))
        if i1 < 0 || i0 >= levels.count { return AudioEnvelope.floorDB }
        i0 = max(i0, 0)
        i1 = min(max(i1, i0), levels.count - 1)
        var peak = levels[i0]
        if i1 > i0 { for i in (i0 + 1)...i1 where levels[i] > peak { peak = levels[i] } }
        return peak
    }
}

public struct MediaRequest: Sendable {
    public let url: URL
    public let bookmark: Data?
    /// File-time range that is actually used on the timeline.
    public let range: ClosedRange<Double>
}

public protocol EnvelopeProvider: Sendable {
    /// Returns the envelope covering `request.range`, or throws when the media can't be read.
    func envelope(for request: MediaRequest, hop: Double, progress: @Sendable (Double) -> Void) async throws -> AudioEnvelope
}

/// Reads audio with AVFoundation, so anything Final Cut Pro can import natively works.
public struct AVFoundationEnvelopeProvider: EnvelopeProvider {
    public init() {}

    public func envelope(for request: MediaRequest, hop: Double, progress: @Sendable (Double) -> Void) async throws -> AudioEnvelope {
        var url = request.url
        var scoped: URL?
        if !FileManager.default.isReadableFile(atPath: url.path), let bookmark = request.bookmark {
            // Sandboxed hosts get access to media through the bookmark FCP puts in the XML.
            var stale = false
            for options in [URL.BookmarkResolutionOptions.withSecurityScope, []] {
                if let resolved = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) {
                    if resolved.startAccessingSecurityScopedResource() { scoped = resolved }
                    url = resolved
                    break
                }
            }
        }
        defer { scoped?.stopAccessingSecurityScopedResource() }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw SilenceCutError.io("Media file is missing or not readable: \(url.path)")
        }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw SilenceCutError.io("No audio track in \(url.lastPathComponent)")
        }
        // Hops sit on a fixed grid from the start of the file, so a level never depends on
        // which part of the file was asked for.
        let lower = (max(0, request.range.lowerBound) / hop).rounded(.down) * hop
        let upper = max(lower + hop, request.range.upperBound)
        let count = Int(((upper - lower) / hop).rounded(.up))
        var power = [Float](repeating: 0, count: count)
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            try readTrack(track, of: asset, from: lower, to: upper, hop: hop, into: &power) { fraction in
                progress((Double(index) + fraction) / Double(tracks.count))
            }
        }
        let levels = power.map { $0 > 1e-16 ? 10 * log10f($0) : AudioEnvelope.floorDB }
        return AudioEnvelope(startTime: lower, hop: hop, levels: levels)
    }

    /// Accumulates the per-hop mean square of every channel in `track`, keeping the loudest.
    private func readTrack(_ track: AVAssetTrack, of asset: AVAsset, from lower: Double, to upper: Double, hop: Double,
                           into power: inout [Float], progress: (Double) -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SilenceCutError.io("Can't decode audio in this file") }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: lower, preferredTimescale: 48000),
                                       end: CMTime(seconds: upper, preferredTimescale: 48000))
        guard reader.startReading() else {
            throw SilenceCutError.io(reader.error?.localizedDescription ?? "Can't read audio")
        }

        let hopCount = power.count
        var sums: [Float] = []      // per channel, current hop
        var filled = 0              // samples accumulated in the current hop
        var currentHop = -1
        var scratch = [Float]()
        var bufferCount = 0

        func flush() {
            guard currentHop >= 0, currentHop < hopCount, filled > 0 else { return }
            var peak: Float = 0
            for s in sums { peak = max(peak, s / Float(filled)) }
            if peak > power[currentHop] { power[currentHop] = peak }
        }

        while let sample = output.copyNextSampleBuffer() {
            bufferCount += 1
            if bufferCount % 64 == 0 {
                if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            }
            guard let format = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let sampleRate = asbd.mSampleRate
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, sampleRate > 0 else { continue }
            if sums.count != channels { flush(); sums = [Float](repeating: 0, count: channels); filled = 0 }

            let byteCount = frames * channels * MemoryLayout<Float>.size
            guard CMBlockBufferGetDataLength(block) >= byteCount else { continue }
            if scratch.count < frames * channels { scratch = [Float](repeating: 0, count: frames * channels) }
            let status = scratch.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }

            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { continue }
            let samplesPerHop = sampleRate * hop
            var frame = 0
            scratch.withUnsafeBufferPointer { buffer in
                while frame < frames {
                    let time = pts + Double(frame) / sampleRate - lower
                    let hopIndex = Int((time / hop + 1e-9).rounded(.down))
                    if hopIndex != currentHop {
                        flush()
                        currentHop = hopIndex
                        for c in 0..<channels { sums[c] = 0 }
                        filled = 0
                    }
                    // Frames left before the next hop boundary.
                    let hopEnd = Double(hopIndex + 1) * hop
                    let untilBoundary = Int(((hopEnd - time) * sampleRate).rounded(.up))
                    let run = max(1, min(frames - frame, min(untilBoundary, Int(samplesPerHop.rounded(.up)))))
                    if hopIndex >= 0 && hopIndex < hopCount {
                        for c in 0..<channels {
                            var sum: Float = 0
                            vDSP_svesq(buffer.baseAddress! + frame * channels + c, vDSP_Stride(channels), &sum, vDSP_Length(run))
                            sums[c] += sum
                        }
                        filled += run
                    }
                    frame += run
                }
            }
            progress(min(1, max(0, (pts - lower) / max(upper - lower, 0.001))))
        }
        flush()
        if reader.status == .failed {
            throw SilenceCutError.io(reader.error?.localizedDescription ?? "Audio decoding failed")
        }
    }
}
