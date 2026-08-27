import AVFoundation
import AudioToolbox
import Foundation
import os
import WaveCore

struct CapturedMeetingAudio: Sendable {
    let fileURL: URL
    let durationSeconds: Double
    let droppedBuffers: Int
    let peakBufferBytes: Int
}

private struct MeetingCaptureState: Sendable {
    var recording = false
    var paused = false
}

private struct MeetingPCMState: @unchecked Sendable {
    var samples: [Int16]
    var readIndex = 0
    var writeIndex = 0
    var count = 0
    var droppedBuffers = 0
    var peakCount = 0
}

private final class StreamingPCMWriter: @unchecked Sendable {
    static let sampleRate = 16_000
    static let ringCapacity = 128_000
    static let maximumSamples = sampleRate * 60 * 60 * KeyerConfiguration.shared.int(
        "meetings.maximum_duration_hours", default: 6
    )

    private let ring = OSAllocatedUnfairLock(
        initialState: MeetingPCMState(samples: Array(repeating: 0, count: ringCapacity))
    )
    private let outputQueue = DispatchQueue(label: "com.keyer.meeting-audio-drain", qos: .userInitiated)
    private lazy var drainSource: DispatchSourceUserDataAdd = {
        let source = DispatchSource.makeUserDataAddSource(queue: outputQueue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        return source
    }()
    private let fileURL: URL
    private var handle: FileHandle?
    private var scratch: [Int16] = []
    private var writtenSamples = 0
    private var notifiedLimit = false
    private let onLimitReached: @Sendable () -> Void

    init(fileURL: URL, onLimitReached: @escaping @Sendable () -> Void) throws {
        self.fileURL = fileURL
        self.onLimitReached = onLimitReached
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: fileURL.path, contents: Data(repeating: 0, count: 44))
        handle = try FileHandle(forWritingTo: fileURL)
        try handle?.seekToEnd()
        scratch.reserveCapacity(Self.ringCapacity)
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

    func finish() throws -> CapturedMeetingAudio {
        try outputQueue.sync {
            drain()
            guard let handle else { throw AudioCaptureError.unavailable }
            let stats = ring.withLockUnchecked { ($0.droppedBuffers, $0.peakCount) }
            let header = try WAVEncoder.header(
                pcmByteCount: writtenSamples * MemoryLayout<Int16>.size,
                sampleRate: Self.sampleRate
            )
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header)
            try handle.synchronize()
            try handle.close()
            self.handle = nil
            return CapturedMeetingAudio(
                fileURL: fileURL,
                durationSeconds: Double(writtenSamples) / Double(Self.sampleRate),
                droppedBuffers: stats.0,
                peakBufferBytes: stats.1 * MemoryLayout<Int16>.size
            )
        }
    }

    func discard() {
        outputQueue.sync {
            drain()
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func drain() {
        scratch.removeAll(keepingCapacity: true)
        ring.withLockUnchecked { state in
            while state.count > 0 {
                scratch.append(state.samples[state.readIndex])
                state.readIndex = (state.readIndex + 1) % state.samples.count
                state.count -= 1
            }
        }
        guard !scratch.isEmpty, let handle else { return }
        let remaining = max(0, Self.maximumSamples - writtenSamples)
        if scratch.count > remaining {
            scratch.removeLast(scratch.count - remaining)
        }
        if !scratch.isEmpty {
            do {
                try scratch.withUnsafeBytes { try handle.write(contentsOf: $0) }
                writtenSamples += scratch.count
            } catch {
                ring.withLockUnchecked { $0.droppedBuffers += 1 }
            }
        }
        if writtenSamples >= Self.maximumSamples, !notifiedLimit {
            notifiedLimit = true
            onLimitReached()
        }
    }
}

final class MeetingAudioCaptureService: @unchecked Sendable {
    private let captureState = OSAllocatedUnfairLock(initialState: MeetingCaptureState())
    private let inputDeviceUID = OSAllocatedUnfairLock(initialState: "")
    private let lifecycleLock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var reusableOutput: AVAudioPCMBuffer?
    private var writer: StreamingPCMWriter?
    private var configuredDeviceUID: String?
    private var tapInstalled = false
    private let limitHandler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

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
        guard changed, !captureState.withLock({ $0.recording }) else { return }
        lifecycleLock.withLock { discardConfigurationLocked() }
    }

    func prepare() throws {
        try lifecycleLock.withLock { try configureIfNeededLocked() }
    }

    func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard captureState.withLock({ state in
            guard !state.recording else { return false }
            state.recording = true
            state.paused = false
            return true
        }) else { throw AudioCaptureError.alreadyRecording }

        do {
            try configureIfNeededLocked()
            guard let engine, let converter else { throw AudioCaptureError.unavailable }
            converter.reset()
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "com.keyer.app-meetings", directoryHint: .isDirectory)
            let url = directory.appending(path: "meeting-\(UUID().uuidString.lowercased()).wav")
            writer = try StreamingPCMWriter(fileURL: url) { [weak self] in
                self?.limitHandler.withLock { $0 }?()
            }
            try engine.start()
        } catch {
            writer?.discard()
            writer = nil
            captureState.withLock {
                $0.recording = false
                $0.paused = false
            }
            throw error
        }
    }

    func pause() {
        captureState.withLock { state in
            if state.recording { state.paused = true }
        }
    }

    func resume() {
        captureState.withLock { state in
            if state.recording { state.paused = false }
        }
    }

    func stop() throws -> CapturedMeetingAudio {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        engine?.stop()
        guard let writer else {
            resetStateLocked()
            throw AudioCaptureError.unavailable
        }
        self.writer = nil
        let capture = try writer.finish()
        resetStateLocked()
        guard capture.droppedBuffers == 0 else {
            try? FileManager.default.removeItem(at: capture.fileURL)
            throw AudioCaptureError.droppedAudio
        }
        guard capture.durationSeconds >= 0.18 else {
            try? FileManager.default.removeItem(at: capture.fileURL)
            throw AudioCaptureError.tooShort
        }
        return capture
    }

    func cancel() {
        lifecycleLock.withLock {
            engine?.stop()
            writer?.discard()
            writer = nil
            resetStateLocked()
        }
    }

    private func consume(_ input: AVAudioPCMBuffer) {
        let shouldCapture = captureState.withLock { $0.recording && !$0.paused }
        guard shouldCapture, let converter, let output = reusableOutput, let writer else { return }
        output.frameLength = 0
        let provider = MeetingConverterInput(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            guard let buffer = provider.take() else {
                state.pointee = .noDataNow
                return nil
            }
            state.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil,
              let channel = output.floatChannelData?.pointee else { return }
        writer.append(channel, count: Int(output.frameLength))
    }

    private func configureIfNeededLocked() throws {
        let selectedUID = inputDeviceUID.withLock { $0 }
        if engine != nil, configuredDeviceUID == selectedUID { return }
        discardConfigurationLocked()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !selectedUID.isEmpty, let selectedID = AudioInputDevices.deviceID(forUID: selectedUID),
           let audioUnit = input.audioUnit {
            var deviceID = selectedID
            guard AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ) == noErr else { throw AudioCaptureError.unavailable }
        }
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(StreamingPCMWriter.sampleRate),
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(ceil(65_536 * targetFormat.sampleRate / sourceFormat.sampleRate) + 256)
              ) else { throw AudioCaptureError.unavailable }
        self.engine = engine
        self.converter = converter
        reusableOutput = output
        configuredDeviceUID = selectedUID
        input.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        tapInstalled = true
        engine.prepare()
    }

    private func resetStateLocked() {
        captureState.withLock {
            $0.recording = false
            $0.paused = false
        }
    }

    private func discardConfigurationLocked() {
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.stop()
        engine = nil
        converter = nil
        reusableOutput = nil
        configuredDeviceUID = nil
    }
}

private final class MeetingConverterInput: @unchecked Sendable {
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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
