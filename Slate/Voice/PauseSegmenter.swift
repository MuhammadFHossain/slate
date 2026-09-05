import Foundation

/// Finds the pauses in a stretch of 16 kHz audio, so a dictation can be cut
/// into paragraphs where you actually stopped for a beat, and so the live
/// transcript only ever re-runs the part you are still speaking.
///
/// Speech is detected with an adaptive RMS gate: the floor comes from the
/// quietest fifth of the frames (room tone), the ceiling from the loudest,
/// so a quiet mic and a loud one both separate words from silence.
enum PauseSegmenter {
    /// 20 ms analysis frames at 16 kHz.
    static let frameSize = 320
    /// A silence this long, after real speech, is a paragraph break.
    static let paragraphGap: TimeInterval = 1.1
    /// Speech shorter than this since the last cut is a breath, not a paragraph.
    static let minSpeech: TimeInterval = 0.5
    /// Where inside the gap to cut: this far after the speech stopped, so the
    /// finished paragraph keeps a little trailing room and no clipped ending.
    static let cutOffset: TimeInterval = 0.45

    /// Cut points (sample indices into `samples`) at or after `start`, each the
    /// start of a new paragraph. A cut is placed only after `minSpeech` of
    /// speech since the previous cut and a silence of at least `paragraphGap`.
    static func cutPoints(in samples: [Float], from start: Int = 0, sampleRate: Double = 16000) -> [Int] {
        let start = max(0, min(start, samples.count))
        let available = samples.count - start
        let frameCount = available / frameSize
        guard frameCount >= 10 else { return [] }

        var rms = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frameCount {
                var sum: Float = 0
                let lo = start + frame * frameSize
                for index in lo..<(lo + frameSize) {
                    let sample = buffer[index]
                    sum += sample * sample
                }
                rms[frame] = (sum / Float(frameSize)).squareRoot()
            }
        }
        let threshold = speechThreshold(rms)

        let gapFrames = max(1, Int(paragraphGap * sampleRate) / frameSize)
        let minSpeechFrames = max(1, Int(minSpeech * sampleRate) / frameSize)
        let cutOffsetFrames = max(0, Int(cutOffset * sampleRate) / frameSize)

        var cuts: [Int] = []
        var speechFramesSinceCut = 0
        var speechRun = 0
        var silentRun = 0
        var lastSpeechFrame = -1

        for frame in 0..<frameCount {
            if rms[frame] >= threshold {
                speechRun += 1
                // Two frames (40 ms) of signal is a voice; one is a click.
                if speechRun >= 2 {
                    speechFramesSinceCut += speechRun == 2 ? 2 : 1
                    silentRun = 0
                    lastSpeechFrame = frame
                }
            } else {
                speechRun = 0
                silentRun += 1
                if silentRun == gapFrames,
                   speechFramesSinceCut >= minSpeechFrames,
                   lastSpeechFrame >= 0 {
                    let cutFrame = min(lastSpeechFrame + 1 + cutOffsetFrames, frameCount)
                    cuts.append(start + cutFrame * frameSize)
                    speechFramesSinceCut = 0
                }
            }
        }
        return cuts
    }

    /// Contiguous ranges covering `samples[start...]`, split at the cut points.
    static func segments(in samples: [Float], from start: Int = 0) -> [Range<Int>] {
        let start = max(0, min(start, samples.count))
        var ranges: [Range<Int>] = []
        var begin = start
        for cut in cutPoints(in: samples, from: start) where cut > begin && cut < samples.count {
            ranges.append(begin..<cut)
            begin = cut
        }
        if begin < samples.count {
            ranges.append(begin..<samples.count)
        }
        return ranges
    }

    /// Adaptive speech gate: well above the room tone, a fraction of the loud
    /// frames, and never below a hard floor so a silent buffer has no speech.
    /// The room-tone term is capped against the loud frames, so a window that
    /// is mostly continuous speech (the live tail) does not put the gate
    /// above its own quieter words.
    private static func speechThreshold(_ rms: [Float]) -> Float {
        let sorted = rms.sorted()
        guard !sorted.isEmpty else { return 1 }
        let floor = sorted[sorted.count / 10]
        let loud = sorted[min(sorted.count - 1, (sorted.count * 95) / 100)]
        return max(min(floor * 3, loud * 0.3), loud * 0.10, 0.0015)
    }
}
