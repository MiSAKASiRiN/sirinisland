import Accelerate
import CoreAudio
import Foundation

enum SpectrumBands {
    static let count = 32

    static func compact(_ levels: [CGFloat]) -> [CGFloat] {
        (0..<6).map { group in
            let start = group * levels.count / 6
            let end = (group + 1) * levels.count / 6
            return levels[start..<end].max() ?? 0
        }
    }
}

@available(macOS 14.2, *)
final class SpectrumAnalyzer {
    private let size: Int
    private let hop: Int
    private let secondsPerHop: Double
    private let transform: vDSP.DiscreteFourierTransform<Float>
    private let window: [Float]
    private let zeros: [Float]
    private let bins: [Range<Int>]
    private var channels = [[Float]]()
    private var filled = 0
    private var input: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var powers: [Float]
    private var levels = [CGFloat](repeating: 0, count: SpectrumBands.count)
    private var reference = 0.003
    private var holdRemaining = 0.0

    init(rate: Double) throws {
        // Resolve the lowest log bands even on high-rate output devices.
        let n = 1 << Int(ceil(log2(max(256, rate / 7.5))))
        size = n
        hop = min(n, max(1, Int(rate * 0.032)))
        secondsPerHop = Double(hop) / rate
        transform = try vDSP.DiscreteFourierTransform(previous: nil, count: n, direction: .forward,
                                                       transformType: .complexComplex, ofType: Float.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        zeros = [Float](repeating: 0, count: n)
        input = zeros
        real = zeros
        imaginary = zeros
        powers = [Float](repeating: 0, count: n/2)
        let upper = min(16_000, rate/2)
        let lower = min(40, upper/2)
        let edges = (0...SpectrumBands.count).map { index in
            let hz = lower * pow(upper/lower, Double(index) / Double(SpectrumBands.count))
            return min(n/2, max(1, Int(ceil(hz * Double(n) / rate))))
        }
        bins = zip(edges, edges.dropFirst()).map { $0..<$1 }
    }

    func consume(_ list: UnsafePointer<AudioBufferList>) -> [CGFloat]? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var frames = Int.max
        var channelCount = 0
        for b in buffers {
            guard b.mNumberChannels > 0, b.mData != nil else { return nil }
            frames = min(frames, Int(b.mDataByteSize) / MemoryLayout<Float>.stride / Int(b.mNumberChannels))
            channelCount += Int(b.mNumberChannels)
        }
        guard channelCount > 0, frames > 0 else { return nil }
        if channels.count != channelCount {
            channels = Array(repeating: zeros, count: channelCount)
            filled = 0
        }

        var offset = 0
        var result: [CGFloat]?
        while offset < frames {
            let take = min(frames-offset, size-filled)
            var firstChannel = 0
            for b in buffers {
                let stride = Int(b.mNumberChannels)
                let pcm = b.mData!.assumingMemoryBound(to: Float.self)
                for channel in 0..<stride {
                    channels[firstChannel+channel].withUnsafeMutableBufferPointer { dest in
                        for i in 0..<take {
                            let sample = pcm[(offset+i)*stride+channel]
                            dest[filled+i] = sample.isFinite ? sample : 0
                        }
                    }
                }
                firstChannel += stride
            }
            filled += take
            offset += take
            if filled == size {
                result = analyze()
                filled = size-hop
                for c in channels.indices {
                    channels[c].withUnsafeMutableBufferPointer { buf in
                        let p = buf.baseAddress!
                        memmove(p, p+hop, filled * MemoryLayout<Float>.stride)
                    }
                }
            }
        }
        return result
    }

    private func analyze() -> [CGFloat] {
        vDSP.clear(&powers)
        // Combine power after transforming each channel so opposite stereo phases don't cancel.
        for samples in channels {
            vDSP.multiply(samples, window, result: &input)
            transform.transform(inputReal: input, inputImaginary: zeros, outputReal: &real, outputImaginary: &imaginary)
            for i in powers.indices { powers[i] += real[i]*real[i] + imaginary[i]*imaginary[i] }
        }
        // RMS calibration for a Hann window and the one-sided power spectrum.
        let scale = 4 / (sqrt(3 * Double(channels.count)) * Double(size))
        let amplitudes = bins.map { sqrt(Double(powers[$0].reduce(0, +))) * scale }
        let peak = amplitudes.max() ?? 0
        let release = max(0, secondsPerHop-holdRemaining)
        holdRemaining = max(0, holdRemaining-secondsPerHop)
        reference = max(0.003, reference * exp(-release/1.3))
        if peak >= reference {
            reference = peak
            holdRemaining = 0.36
        }
        for i in levels.indices {
            let amplitude = amplitudes[i]
            let target = amplitude > 0.0001 ? 0.94 * max(0, 1 + 20 * log10(amplitude/reference) / 42) : 0
            let response = target > levels[i] ? 0.88 : 0.42
            levels[i] += (target-levels[i]) * response
            if levels[i] < 0.002 { levels[i] = 0 }
        }
        return levels
    }
}
