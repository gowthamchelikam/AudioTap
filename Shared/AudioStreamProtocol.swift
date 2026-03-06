import Foundation

struct AudioStreamHeader {
    static let magic: UInt32 = 0x41554450 // "AUDP"
    static let size = 12

    let sampleRate: UInt32
    let channels: UInt16
    let bitsPerSample: UInt16

    func toData() -> Data {
        var data = Data(capacity: Self.size)
        var m = Self.magic.littleEndian
        var r = sampleRate.littleEndian
        var c = channels.littleEndian
        var b = bitsPerSample.littleEndian
        withUnsafeBytes(of: &m) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &r) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &c) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
        return data
    }
}

enum AudioStreamFrame {
    static func wrap(_ pcmData: Data) -> Data {
        var size = UInt32(pcmData.count).littleEndian
        var frame = Data(capacity: 4 + pcmData.count)
        withUnsafeBytes(of: &size) { frame.append(contentsOf: $0) }
        frame.append(pcmData)
        return frame
    }
}
