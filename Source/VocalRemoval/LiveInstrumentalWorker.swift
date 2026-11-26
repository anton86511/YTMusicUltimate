import Foundation
import UIKit

@available(iOS 16.0, *)
final class LiveInstrumentalWorker {
    private let queue = DispatchQueue(label: "com.ytmu.instrumental", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var model: HQ4InstrumentalModel?
    private var stream: HQ4Stream?
    private var generation: UInt32 = 0
    private let activityLock = NSLock()
    private var foregroundEpoch: UInt?
    private var activityEpoch: UInt = 0
    private var activityObservers: [NSObjectProtocol] = []

    func start(url: URL, computeMode: InstrumentalComputeMode, completion: @escaping (Bool) -> Void) {
        observeAppActivity()
        queue.async {
            do {
                let model = try HQ4InstrumentalModel(url: url, computeMode: computeMode)
                self.model = model
                self.generation = 0
                if !YTMUInstrumentalEnable() {
                    self.model = nil
                    completion(false)
                    return
                }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(35), leeway: .milliseconds(5))
                timer.setEventHandler { [weak self] in
                    guard let self = self else { return }
                    autoreleasepool { self.process() }
                }
                self.timer = timer
                timer.resume()
                completion(true)
            } catch {
                self.stopOnQueue()
                completion(false)
            }
        }
    }

    private func observeAppActivity() {
        guard activityObservers.isEmpty else { return }
        let center = NotificationCenter.default
        activityObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.setForeground(false)
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.setForeground(false)
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.setForeground(true)
            }
        ]
        setForeground(UIApplication.shared.applicationState == .active)
    }

    deinit {
        for observer in activityObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private func setForeground(_ active: Bool) {
        activityLock.lock()
        activityEpoch &+= 1
        foregroundEpoch = active ? activityEpoch : nil
        activityLock.unlock()
    }

    private func currentGPUEpoch() -> UInt? {
        activityLock.lock()
        defer { activityLock.unlock() }
        return foregroundEpoch
    }

    func stop() {
        YTMUInstrumentalDisable()
        queue.async {
            YTMUInstrumentalDisable()
            self.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        stream = nil
        model = nil
    }

    private func process() {
        let source = YTMUInstrumentalCurrentStream()
        guard source.generation != 0, let model = model else { return }
        if source.generation != generation {
            stream = HQ4Stream(sampleRate: Int(source.sampleRate))
            generation = source.generation
        }
        let thermal = ProcessInfo.processInfo.thermalState
        stream?.process(generation: generation, useModel: thermal != .serious && thermal != .critical) { audio in
            return try? model.separate(audio, gpuEpoch: self.currentGPUEpoch)
        }
    }
}

@available(iOS 16.0, *)
private final class HQ4Stream {
    private let frameCount: Int
    private let hop: Int
    private let toModel: HQ4Resampler
    private let fromModel: HQ4Resampler
    private var input: [YTMUStereoFrame]
    private var count = 0
    private var position: UInt64 = 0
    private var pending: [YTMUStereoFrame] = []
    private var output: [YTMUStereoFrame] = []
    private var written = 0

    init(sampleRate: Int) {
        let modelRate = HQ4InstrumentalModel.sampleRate
        frameCount = (HQ4InstrumentalModel.window * sampleRate + modelRate - 1) / modelRate
        hop = HQ4InstrumentalModel.hop * sampleRate / modelRate
        toModel = HQ4Resampler(from: sampleRate, to: modelRate)
        fromModel = HQ4Resampler(from: modelRate, to: sampleRate)
        input = Array(repeating: YTMUStereoFrame(left: 0, right: 0), count: frameCount)
    }

    func process(generation: UInt32, useModel: Bool, separate: ([[Float]]) -> [[Float]]?) {
        if written < output.count {
            flush(generation)
            return
        }

        let appended = input.withUnsafeMutableBufferPointer { buffer in
            YTMUInstrumentalRead(generation, buffer.baseAddress! + count, UInt32(frameCount - count))
        }
        count += Int(appended)
        guard count == frameCount else { return }

        let stems: [[Float]]?
        if useModel {
            let frames = toModel.convert(input, count: HQ4InstrumentalModel.window)
            stems = separate([frames.map(\.left), frames.map(\.right)])
        } else {
            stems = nil
        }
        if let stems {
            let wet = zip(stems[0], stems[1]).map { YTMUStereoFrame(left: $0.0, right: $0.1) }
            output = fromModel.convert(wet, count: frameCount)
        } else {
            output = input
        }

        let overlap = frameCount - hop
        for i in pending.indices {
            let mix = Float(i + 1) / Float(overlap + 1)
            output[i].left = pending[i].left * (1 - mix) + output[i].left * mix
            output[i].right = pending[i].right * (1 - mix) + output[i].right * mix
        }
        if stems != nil {
            pending = Array(output[hop...])
            output.removeLast(overlap)
        } else {
            // Leave this range empty so the render thread plays delayed original audio.
            // Keep the overlapping original frames for a clean return to the model.
            pending = Array(input[hop...])
            output.removeAll(keepingCapacity: true)
        }
        input.replaceSubrange(0..<overlap, with: Array(input[hop...]))
        count = overlap
        written = 0
        if stems != nil { flush(generation) }
        else { position += UInt64(hop) }
    }

    private func flush(_ generation: UInt32) {
        let sent = output.withUnsafeBufferPointer { buffer in
            YTMUInstrumentalWrite(generation, buffer.baseAddress! + written,
                                    UInt32(output.count - written), position)
        }
        position += UInt64(sent)
        written += Int(sent)
    }
}

// The two supported rates have a repeating rational phase. A windowed sinc
// filter avoids sending aliased high frequencies to the model at 48 kHz.
private struct HQ4Resampler {
    private let numerator: Int
    private let denominator: Int
    private let kernels: [[Float]]
    private let radius = 16

    init(from: Int, to: Int) {
        let unit = from == to ? from : 300
        numerator = from / unit
        denominator = to / unit
        let radius = 16
        let cutoff = min(1, Double(to) / Double(from))
        kernels = from == to ? [] : (0..<(to / unit)).map { phase in
            let weights = (-radius + 1...radius).map { tap -> Double in
                let distance = Double(tap) - Double(phase) / Double(to / unit)
                let argument = Double.pi * distance * cutoff
                let sinc = argument == 0 ? 1 : sin(argument) / argument
                return abs(distance) < Double(radius)
                    ? sinc * (0.5 + 0.5 * cos(Double.pi * distance / Double(radius))) : 0
            }
            let sum = weights.reduce(0, +)
            return weights.map { Float($0 / sum) }
        }
    }

    func convert(_ input: [YTMUStereoFrame], count: Int) -> [YTMUStereoFrame] {
        guard !kernels.isEmpty else { return input }
        return (0..<count).map { index in
            let phase = index * numerator
            let start = phase / denominator - radius + 1
            let kernel = kernels[phase % denominator]
            var frame = YTMUStereoFrame(left: 0, right: 0)
            for tap in kernel.indices {
                let sample = input[min(input.count - 1, max(0, start + tap))]
                frame.left += sample.left * kernel[tap]
                frame.right += sample.right * kernel[tap]
            }
            return frame
        }
    }
}

@available(iOS 16.0, *)
private let vocalWorker = LiveInstrumentalWorker()

@_cdecl("YTMUStartVocalRemoval")
public func startVocalRemoval(_ modelPath: UnsafePointer<CChar>?,
                             _ completion: @escaping @convention(block) (Bool) -> Void) {
    guard #available(iOS 16.0, *), let modelPath else {
        completion(false)
        return
    }
    vocalWorker.start(url: URL(fileURLWithPath: String(cString: modelPath))) { success in
        DispatchQueue.main.async { completion(success) }
    }
}

@_cdecl("YTMUStopVocalRemoval")
public func stopVocalRemoval() {
    if #available(iOS 16.0, *) { vocalWorker.stop() }
}
