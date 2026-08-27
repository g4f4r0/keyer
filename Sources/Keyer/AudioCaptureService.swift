import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os
import WaveCore

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID
    let isSystemDefault: Bool
}

enum AudioInputDevices {
    static func available() -> [AudioInputDevice] {
        let defaultID = systemDefaultDeviceID()
        return allDeviceIDs().compactMap { deviceID in
            guard hasInputChannels(deviceID),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID),
                  let name = stringProperty(kAudioObjectPropertyName, deviceID: deviceID) else {
                return nil
            }
            return AudioInputDevice(id: uid, name: name, deviceID: deviceID,
                                    isSystemDefault: deviceID == defaultID)
        }
        .sorted { lhs, rhs in
            if lhs.isSystemDefault != rhs.isSystemDefault { return lhs.isSystemDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        available().first(where: { $0.id == uid })?.deviceID
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &byteCount) == noErr,
              byteCount > 0 else { return [] }
        var devices = Array(repeating: AudioDeviceID(0),
                            count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size)
        let status = devices.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       0, nil, &byteCount, bytes.baseAddress!)
        }
        return status == noErr ? devices : []
    }

    private static func systemDefaultDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &byteCount, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteCount) == noErr,
              byteCount >= MemoryLayout<AudioBufferList>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(byteCount),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, storage) == noErr else {
            return false
        }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector,
                                       deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &value) == noErr else {
            return nil
        }
        return value?.takeUnretainedValue() as String?
    }
}

struct CapturedAudio: Sendable {
    let wav: Data
    let durationSeconds: Double
    let droppedBuffers: Int
    let peakBufferBytes: Int
    let finalizationMilliseconds: Double
    let engineStopMilliseconds: Double
    let accumulatorFinishMilliseconds: Double
    let wavEncodingMilliseconds: Double
}

struct AudioStartupTiming: Sendable {
    let configurationMilliseconds: Double
    let accumulatorMilliseconds: Double
    let tapInstallationMilliseconds: Double
    let engineStartMilliseconds: Double
}

enum AudioCaptureError: Error, Sendable {
    case alreadyRecording
    case unavailable
    case converterFailed
    case tooShort
    case droppedAudio
}

private struct PCMState: @unchecked Sendable {
    var samples: [Int16]
    var readIndex = 0
    var writeIndex = 0
    var count = 0
    var droppedBuffers = 0
    var peakCount = 0
}

private final class PCMAccumulator: @unchecked Sendable {
    struct FinishedCapture {
        let wav: Data
        let sampleCount: Int
        let droppedBuffers: Int
        let peakBufferBytes: Int
        let encodingMilliseconds: Double
    }

    static let sampleRate = 16_000
    static let ringCapacity = 128_000
    static let maximumSamples = sampleRate * KeyerConfiguration.shared.int(
        "dictation.maximum_duration_seconds", default: 900
    )

    private let ring = OSAllocatedUnfairLock(initialState: PCMState(samples: Array(repeating: 0, count: ringCapacity)))
    private let outputQueue = DispatchQueue(label: "com.keyer.audio-drain", qos: .userInteractive)
    private lazy var drainSource: DispatchSourceUserDataAdd = {
        let source = DispatchSource.makeUserDataAddSource(queue: outputQueue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        return source
    }()
    private var pcm = Data()
    private var drainScratch: [Int16] = []
    private let onLimitReached: @Sendable () -> Void
    private var notifiedLimit = false

    init(onLimitReached: @escaping @Sendable () -> Void) {
        self.onLimitReached = onLimitReached
        pcm.reserveCapacity(Self.sampleRate * 2 * 15)
        drainScratch.reserveCapacity(Self.ringCapacity)
        _ = drainSource
    }

    func append(_ pointer: UnsafePointer<Float>, count incomingCount: Int) {
        guard incomingCount > 0 else { return }
        let accepted = ring.withLockIfAvailableUnchecked { state -> Bool in
            guard incomingCount <= state.samples.count - state.count else {
                state.droppedBuffers += 1
                return false
            }
            for offset in 0..<incomingCount {
                let sample = max(-1, min(1, pointer[offset]))
                state.samples[state.writeIndex] = Int16(sample * Float(Int16.max))
                state.writeIndex = (state.writeIndex + 1) % state.samples.count
            }
            state.count += incomingCount
            state.peakCount = max(state.peakCount, state.count)
            return true
        }
        if accepted == nil {
            ring.withLockIfAvailableUnchecked { $0.droppedBuffers += 1 }
        }
        drainSource.add(data: 1)
    }

    func finish() throws -> FinishedCapture {
        try outputQueue.sync {
            drain()
            let stats = ring.withLockUnchecked { ($0.droppedBuffers, $0.peakCount) }
            let sampleCount = pcm.count / MemoryLayout<Int16>.size
            let encodingStart = ContinuousClock.now
            let wav = try WAVEncoder.encodePCM16Mono(pcm)
            let encodingMS = Self.elapsedMS(since: encodingStart)
            let result = FinishedCapture(
                wav: wav,
                sampleCount: sampleCount,
                droppedBuffers: stats.0,
                peakBufferBytes: stats.1 * MemoryLayout<Int16>.size,
                encodingMilliseconds: encodingMS
            )
            resetStorage()
            return result
        }
    }

    func reset() {
        outputQueue.sync {
            drain()
            resetStorage()
        }
    }

    private func drain() {
        drainScratch.removeAll(keepingCapacity: true)
        ring.withLockUnchecked { state in
            guard state.count > 0 else { return }
            while state.count > 0 {
                drainScratch.append(state.samples[state.readIndex])
                state.readIndex = (state.readIndex + 1) % state.samples.count
                state.count -= 1
            }
        }
        guard !drainScratch.isEmpty else { return }
        let availableSamples = max(0, Self.maximumSamples - pcm.count / 2)
        if drainScratch.count > availableSamples {
            drainScratch.removeLast(drainScratch.count - availableSamples)
        }
        if !drainScratch.isEmpty {
            drainScratch.withUnsafeBytes { pcm.append(contentsOf: $0) }
        }
        if pcm.count / MemoryLayout<Int16>.size >= Self.maximumSamples, !notifiedLimit {
            notifiedLimit = true
            onLimitReached()
        }
    }

    private func resetStorage() {
        pcm.removeAll(keepingCapacity: true)
        drainScratch.removeAll(keepingCapacity: true)
        notifiedLimit = false
        ring.withLockUnchecked { state in
            state.readIndex = 0
            state.writeIndex = 0
            state.count = 0
            state.droppedBuffers = 0
            state.peakCount = 0
        }
    }

    private static func elapsedMS(since instant: ContinuousClock.Instant) -> Double {
        let duration = instant.duration(to: .now)
        return Double(duration.components.seconds) * 1_000 +
            Double(duration.components.attoseconds) / 1e15
    }
}

final class AudioCaptureService: @unchecked Sendable {
    private struct CaptureTiming: Sendable {
        var startedAt: ContinuousClock.Instant?
        var firstBufferMilliseconds: Double?
    }

    private let controlLock = OSAllocatedUnfairLock(initialState: false)
    private let inputDeviceUID = OSAllocatedUnfairLock(initialState: "")
    private let lifecycleLock = NSLock()
    private var engine: AVAudioEngine?
    private var accumulator: PCMAccumulator?
    private var preparedAccumulator: PCMAccumulator?
    private var converter: AVAudioConverter?
    private var reusableOutput: AVAudioPCMBuffer?
    private var tapInstalled = false
    private var configuredDeviceUID: String?
    private let startupTiming = OSAllocatedUnfairLock<AudioStartupTiming?>(initialState: nil)
    private let captureTiming = OSAllocatedUnfairLock(initialState: CaptureTiming())
    private let limitHandler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    var onLevel: (@Sendable (Float) -> Void)?
    var onLimitReached: (@Sendable () -> Void)? {
        get { limitHandler.withLock { $0 } }
        set { limitHandler.withLock { $0 = newValue } }
    }

    func selectInputDevice(uid: String) {
        let changed = inputDeviceUID.withLock { current in
            let changed = current != uid
            current = uid
            return changed
        }
        guard changed, !controlLock.withLock({ $0 }) else { return }
        lifecycleLock.lock()
        discardPreparedLocked()
        lifecycleLock.unlock()
    }

    func prepare() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        try configureIfNeededLocked()
    }

    func prepareForNextCapture() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard engine != nil, !controlLock.withLock({ $0 }) else { return }
        engine?.prepare()
    }

    func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard controlLock.withLock({ recording in
            guard !recording else { return false }
            recording = true
            return true
        }) else { throw AudioCaptureError.alreadyRecording }

        do {
            let configurationStart = ContinuousClock.now
            try configureIfNeededLocked()
            let configurationMS = elapsedMS(since: configurationStart)
            guard let engine, let converter else { throw AudioCaptureError.unavailable }
            converter.reset()
            let accumulatorStart = ContinuousClock.now
            let accumulator = preparedAccumulator ?? makeAccumulator()
            preparedAccumulator = nil
            self.accumulator = accumulator
            let accumulatorMS = elapsedMS(since: accumulatorStart)
            let engineStart = ContinuousClock.now
            captureTiming.withLock {
                $0.startedAt = engineStart
                $0.firstBufferMilliseconds = nil
            }
            try engine.start()
            startupTiming.withLock {
                $0 = AudioStartupTiming(configurationMilliseconds: configurationMS,
                                        accumulatorMilliseconds: accumulatorMS,
                                        tapInstallationMilliseconds: 0,
                                        engineStartMilliseconds: elapsedMS(since: engineStart))
            }
        } catch {
            discardPreparedLocked()
            throw error
        }
    }

    func lastStartupTiming() -> AudioStartupTiming? {
        startupTiming.withLock { $0 }
    }

    func firstBufferMilliseconds() -> Double? {
        captureTiming.withLock { $0.firstBufferMilliseconds }
    }

    func stop() throws -> CapturedAudio {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let start = ContinuousClock.now
        let engineStopStart = ContinuousClock.now
        engine?.stop()
        let engineStopMS = elapsedMS(since: engineStopStart)
        guard let accumulator else {
            resetCaptureLocked()
            throw AudioCaptureError.unavailable
        }
        let accumulatorStart = ContinuousClock.now
        let finished = try accumulator.finish()
        let accumulatorMS = elapsedMS(since: accumulatorStart)
        resetCaptureLocked(reusing: accumulator)
        if finished.droppedBuffers > 0 { throw AudioCaptureError.droppedAudio }
        let duration = Double(finished.sampleCount) / Double(PCMAccumulator.sampleRate)
        guard duration >= 0.18 else { throw AudioCaptureError.tooShort }
        return CapturedAudio(wav: finished.wav, durationSeconds: duration,
                             droppedBuffers: finished.droppedBuffers,
                             peakBufferBytes: finished.peakBufferBytes,
                             finalizationMilliseconds: elapsedMS(since: start),
                             engineStopMilliseconds: engineStopMS,
                             accumulatorFinishMilliseconds: accumulatorMS,
                             wavEncodingMilliseconds: finished.encodingMilliseconds)
    }

    func cancel() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        engine?.stop()
        accumulator?.reset()
        resetCaptureLocked(reusing: accumulator)
    }

    private func consume(_ input: AVAudioPCMBuffer) {
        captureTiming.withLock { timing in
            if timing.firstBufferMilliseconds == nil, let startedAt = timing.startedAt {
                timing.firstBufferMilliseconds = elapsedMS(since: startedAt)
            }
        }
        guard let converter, let output = reusableOutput, let accumulator else { return }
        output.frameLength = 0
        let provider = ConverterInput(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            guard let buffer = provider.take() else {
                state.pointee = .noDataNow
                return nil
            }
            state.pointee = .haveData
            return buffer
        }
        guard status != AVAudioConverterOutputStatus.error, conversionError == nil,
              let channel = output.floatChannelData?.pointee else { return }
        let count = Int(output.frameLength)
        accumulator.append(channel, count: count)
        if count > 0 {
            var peak: Float = 0
            for index in stride(from: 0, to: count, by: 16) { peak = max(peak, abs(channel[index])) }
            let decibels = 20 * log10(max(peak, 0.000_1))
            let visibleLevel = min(1, max(0, (decibels + 50) / 35))
            onLevel?(visibleLevel)
        }
    }

    private func configureIfNeededLocked() throws {
        let selectedUID = inputDeviceUID.withLock { $0 }
        if engine != nil, configuredDeviceUID == selectedUID { return }
        if engine != nil { discardPreparedLocked() }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !selectedUID.isEmpty, let selectedID = AudioInputDevices.deviceID(forUID: selectedUID),
           let audioUnit = input.audioUnit {
            var deviceID = selectedID
            let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &deviceID,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw AudioCaptureError.unavailable }
        }
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Double(PCMAccumulator.sampleRate),
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioCaptureError.unavailable
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(65_536 * ratio) + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.converterFailed
        }
        self.engine = engine
        self.converter = converter
        reusableOutput = output
        preparedAccumulator = makeAccumulator()
        configuredDeviceUID = selectedUID
        input.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        tapInstalled = true
        engine.prepare()
    }

    private func resetCaptureLocked(reusing reusableAccumulator: PCMAccumulator? = nil) {
        accumulator = nil
        if engine != nil, let reusableAccumulator {
            preparedAccumulator = reusableAccumulator
        }
        controlLock.withLock { $0 = false }
    }

    private func makeAccumulator() -> PCMAccumulator {
        PCMAccumulator { [weak self] in
            let handler = self?.limitHandler.withLock { $0 }
            handler?()
        }
    }

    private func discardPreparedLocked() {
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.stop()
        engine = nil
        converter = nil
        reusableOutput = nil
        configuredDeviceUID = nil
        accumulator = nil
        preparedAccumulator = nil
        controlLock.withLock { $0 = false }
    }

    private func elapsedMS(since instant: ContinuousClock.Instant) -> Double {
        let duration = instant.duration(to: .now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}

private final class ConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let consumed = OSAllocatedUnfairLock(initialState: false)

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        let shouldReturn = consumed.withLock { used -> Bool in
            guard !used else { return false }
            used = true
            return true
        }
        return shouldReturn ? buffer : nil
    }
}
