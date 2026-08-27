import Foundation

public enum WAVEncoderError: Error, Equatable, Sendable {
    case invalidSampleRate
    case payloadTooLarge
}
public enum WAVEncoder {
    public static func header(pcmByteCount: Int, sampleRate: Int = 16_000) throws -> Data {
        guard sampleRate > 0 else { throw WAVEncoderError.invalidSampleRate }
        guard pcmByteCount >= 0, pcmByteCount <= Int(UInt32.max) - 36 else {
            throw WAVEncoderError.payloadTooLarge
        }

        var wav = Data(capacity: 44)
        wav.appendASCII("RIFF")
        wav.appendLE(UInt32(36 + pcmByteCount))
        wav.appendASCII("WAVEfmt ")
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(1))
        wav.appendLE(UInt16(1))
        wav.appendLE(UInt32(sampleRate))
        wav.appendLE(UInt32(sampleRate * 2))
        wav.appendLE(UInt16(2))
        wav.appendLE(UInt16(16))
        wav.appendASCII("data")
        wav.appendLE(UInt32(pcmByteCount))
        return wav
    }

    public static func encodePCM16Mono(_ pcm: Data, sampleRate: Int = 16_000) throws -> Data {
        var wav = try header(pcmByteCount: pcm.count, sampleRate: sampleRate)
        wav.reserveCapacity(44 + pcm.count)
        wav.append(pcm)
        return wav
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
