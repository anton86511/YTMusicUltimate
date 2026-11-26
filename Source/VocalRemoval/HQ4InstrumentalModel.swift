import Accelerate
import CoreML

enum InstrumentalComputeMode { case cpuOnly, cpuAndGPU, gpuPreferred }

enum InstrumentalError: Error {
    case fft, modelOutput, gpuUnavailable
}

@available(iOS 16.0, *)
final class HQ4InstrumentalModel {
    static let sampleRate = 44_100
    static let window = 255 * 1_024
    // This hop maps to an exact whole number of frames at 48 kHz as well.
    static let hop = 235_200

    private let spectrum: Spectrogram
    private let url: URL
    private let computeMode: InstrumentalComputeMode
    private let cpuModel: SpectrogramCoreML?
    private var gpuModel: SpectrogramCoreML?
    private var failedGPUEpoch: UInt?

    init(url: URL, computeMode: InstrumentalComputeMode = .cpuAndGPU) throws {
        self.url = url
        self.computeMode = computeMode
        spectrum = try Spectrogram(size: 5_120, bins: 2_560, hop: 1_024, frames: 256, outputGain: 1)
        if computeMode == .gpuPreferred {
            cpuModel = nil
        } else {
            cpuModel = try SpectrogramCoreML(url: url, bins: spectrum.bins, frames: spectrum.frames,
                                            computeUnits: .cpuOnly)
        }
    }

    func separate(_ audio: [[Float]], gpuEpoch: () -> UInt?) throws -> [[Float]] {
        let epoch = computeMode == .cpuOnly ? nil : gpuEpoch()
        let canTryGPU = epoch != nil && epoch != failedGPUEpoch
        guard canTryGPU || cpuModel != nil else { throw InstrumentalError.gpuUnavailable }

        let mix = spectrum.analyze(audio)
        let prediction: [Float]
        if let epoch, let result = predictWithGPU(mix, epoch: epoch, gpuEpoch: gpuEpoch) {
            prediction = result
        } else if let cpuModel {
            prediction = try cpuModel.predict(mix)
        } else {
            throw InstrumentalError.gpuUnavailable
        }
        return try spectrum.reconstruct(prediction)
    }

    private func predictWithGPU(_ mix: [Float], epoch: UInt, gpuEpoch: () -> UInt?) -> [Float]? {
        guard gpuEpoch() == epoch, epoch != failedGPUEpoch else { return nil }
        do {
            if gpuModel == nil {
                gpuModel = try SpectrogramCoreML(url: url, bins: spectrum.bins, frames: spectrum.frames,
                                                computeUnits: .cpuAndGPU)
            }
            guard gpuEpoch() == epoch else { return nil }
            return try gpuModel?.predict(mix)
        } catch {
            // A prediction already in flight can lose access to the GPU at lock.
            failedGPUEpoch = epoch
            gpuModel = nil
            return nil
        }
    }
}

private func reflected(_ index: Int, length: Int) -> Int {
    if length <= 1 { return 0 }
    let period = 2 * (length - 1)
    let wrapped = (index % period + period) % period
    return min(wrapped, period - wrapped)
}

@available(iOS 16.0, *)
private final class SpectrogramCoreML {
    private let model: MLModel
    private let input: MLMultiArray
    private let features: MLDictionaryFeatureProvider
    private let shape: [Int]
    private let contiguous: [Int]
    private let bins: Int
    private let frames: Int

    init(url: URL, bins: Int, frames: Int, computeUnits: MLComputeUnits) throws {
        let shape = [1, 4, bins, frames]
        self.shape = shape
        self.bins = bins
        self.frames = frames
        self.contiguous = [4 * bins * frames, bins * frames, frames, 1]
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
        guard let source = model.modelDescription.inputDescriptionsByName["input"]?.multiArrayConstraint,
              let result = model.modelDescription.outputDescriptionsByName["output"]?.multiArrayConstraint,
              source.shape.map(\.intValue) == shape, result.shape.map(\.intValue) == shape,
              source.dataType == .float16, result.dataType == .float16 else {
            throw InstrumentalError.modelOutput
        }
        input = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
        features = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])
    }

    func predict(_ mix: [Float]) throws -> [Float] {
        guard mix.count == input.count, input.strides.map(\.intValue) == contiguous
        else { throw InstrumentalError.modelOutput }
        let destination = input.dataPointer.assumingMemoryBound(to: Float16.self)
        for i in mix.indices { destination[i] = Float16(mix[i]) }
        let prediction = try model.prediction(from: features)
        guard let output = prediction.featureValue(for: "output")?.multiArrayValue,
              output.dataType == .float16,
              output.shape.map(\.intValue) == shape
        else { throw InstrumentalError.modelOutput }
        let strides = output.strides.map(\.intValue)
        return withExtendedLifetime(output) {
            let source = output.dataPointer.assumingMemoryBound(to: Float16.self)
            if strides == contiguous {
                return (0..<output.count).map { Float(source[$0]) }
            }
            return contiguousOutput(strides: strides, read: { Float(source[$0]) })
        }
    }

    private func contiguousOutput(strides: [Int], read: (Int) -> Float) -> [Float] {
        var values = Array(repeating: Float.zero, count: 4 * bins * frames)
        for plane in 0..<4 {
            for bin in 0..<bins {
                let start = (plane * bins + bin) * frames
                let offset = plane * strides[1] + bin * strides[2]
                for frame in 0..<frames {
                    values[start + frame] = read(offset + frame * strides[3])
                }
            }
        }
        return values
    }
}

private final class Spectrogram {
    let bins: Int
    let frames: Int
    let sampleCount: Int
    private let n: Int
    private let half: Int
    private let hop: Int
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private let hann: [Float]
    private let synthesisScale: [Float]

    init(size: Int, bins: Int, hop: Int, frames: Int, outputGain: Float) throws {
        guard bins > 0, bins <= size / 2 else { throw InstrumentalError.fft }
        let length = vDSP_Length(size)
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, length, .FORWARD) else { throw InstrumentalError.fft }
        guard let inverse = vDSP_DFT_zop_CreateSetup(nil, length, .INVERSE) else {
            vDSP_DFT_DestroySetup(forward)
            throw InstrumentalError.fft
        }
        let hann = (0..<size).map { i in 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(size)) }
        let count = (frames - 1) * hop
        let half = size / 2
        var norm = Array(repeating: Float.zero, count: count)
        for frame in 0..<frames {
            let start = frame * hop - half
            for i in max(0, -start)..<min(size, count - start) {
                norm[start + i] += hann[i] * hann[i]
            }
        }
        self.forward = forward
        self.inverse = inverse
        self.hann = hann
        self.synthesisScale = norm.map { outputGain / (Float(size) * max($0, 0.000001)) }
        self.n = size
        self.half = half
        self.bins = bins
        self.frames = frames
        self.hop = hop
        self.sampleCount = count
    }

    deinit {
        vDSP_DFT_DestroySetup(inverse)
        vDSP_DFT_DestroySetup(forward)
    }

    func analyze(_ audio: [[Float]]) -> [Float] {
        var spec = Array(repeating: Float.zero, count: 4 * bins * frames)
        var re = Array(repeating: Float.zero, count: n)
        var im = re
        var realSpectrum = re
        var imagSpectrum = re
        for channel in 0..<2 {
            let realBase = (2 * channel) * bins * frames
            let imagBase = realBase + bins * frames
            let samples = audio[channel]
            for frame in 0..<frames {
                let start = frame * hop - half
                if start >= 0 && start + n <= sampleCount {
                    samples.withUnsafeBufferPointer { samples in
                        hann.withUnsafeBufferPointer { window in
                            vDSP_vmul(samples.baseAddress! + start, 1, window.baseAddress!, 1, &re, 1, vDSP_Length(n))
                        }
                    }
                } else {
                    for i in 0..<n {
                        re[i] = samples[reflected(start + i, length: sampleCount)] * hann[i]
                    }
                }
                vDSP_vclr(&im, 1, vDSP_Length(n))
                vDSP_DFT_Execute(forward, re, im, &realSpectrum, &imagSpectrum)
                for bin in 0..<bins {
                    let index = bin * frames + frame
                    spec[realBase + index] = realSpectrum[bin]
                    spec[imagBase + index] = imagSpectrum[bin]
                }
            }
        }
        return spec
    }

    func reconstruct(_ stem: [Float]) throws -> [[Float]] {
        var audioOut = [[Float]]()
        audioOut.reserveCapacity(2)
        var re = Array(repeating: Float.zero, count: n)
        var im = re
        var signal = re
        var imaginarySignal = re
        for channel in 0..<2 {
            let realBase = (2 * channel) * bins * frames
            let imagBase = realBase + bins * frames
            var reconstructed = Array(repeating: Float.zero, count: sampleCount)
            for frame in 0..<frames {
                re[0] = stem[realBase + frame]
                im[0] = 0
                re[half] = 0
                im[half] = 0
                for bin in 1..<bins {
                    let index = bin * frames + frame
                    let real = stem[realBase + index]
                    let imag = stem[imagBase + index]
                    re[bin] = real
                    im[bin] = imag
                    re[n - bin] = real
                    im[n - bin] = -imag
                }
                vDSP_DFT_Execute(inverse, re, im, &signal, &imaginarySignal)
                let start = frame * hop - half
                for i in max(0, -start)..<min(n, sampleCount - start) {
                    reconstructed[start + i] += signal[i] * hann[i]
                }
            }
            for i in 0..<sampleCount {
                reconstructed[i] *= synthesisScale[i]
                guard reconstructed[i].isFinite else { throw InstrumentalError.modelOutput }
            }
            audioOut.append(reconstructed)
        }
        return audioOut
    }

}
