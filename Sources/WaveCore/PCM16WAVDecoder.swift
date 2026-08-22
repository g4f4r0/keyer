import Foundation

public enum PCM16WAVDecoderError: Error, Equatable, Sendable {
    case invalidHeader
    case missingAudioData
}

public enum PCM16WAVDecoder {
    public static func decode(_ data: Data) throws -> [Float] {
        guard data.count > 44,
              String(data: data.prefix(4), encoding: .ascii) == "RIFF",
              String(data: data.dropFirst(8).prefix(4), encoding: .ascii) == "WAVE" else {
            throw PCM16WAVDecoderError.invalidHeader
        }

        var offset = 12
        var payload: Data?
        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let length = Int(data[offset + 4])
                | (Int(data[offset + 5]) << 8)
                | (Int(data[offset + 6]) << 16)
                | (Int(data[offset + 7]) << 24)
            let start = offset + 8
            let end = start + length
            guard end <= data.count else { throw PCM16WAVDecoderError.missingAudioData }
            if chunkID == "data" {
                payload = data[start..<end]
                break
            }
            offset = end + (length % 2)
        }
        guard let payload, payload.count >= 2 else {
            throw PCM16WAVDecoderError.missingAudioData
        }

        var samples = [Float]()
        samples.reserveCapacity(payload.count / 2)
        var index = payload.startIndex
        while index + 1 < payload.endIndex {
            let bits = UInt16(payload[index]) | (UInt16(payload[index + 1]) << 8)
            samples.append(Float(Int16(bitPattern: bits)) / 32_768)
            index += 2
        }
        return samples
    }
}
