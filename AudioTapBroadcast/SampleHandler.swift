import ReplayKit
import AVFoundation

class SampleHandler: RPBroadcastSampleHandler {

    private var outputStream: OutputStream?
    private var isConnected = false
    private var headerSent = false

    private var actualSampleRate: UInt32 = 0
    private var actualChannels: UInt16 = 0

    private var lastConnectAttempt: Date = .distantPast
    private let reconnectInterval: TimeInterval = 2.0
    private let defaults = UserDefaults(suiteName: "group.audiotap.shared")

    // MARK: - Lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let host = defaults?.string(forKey: "receiverHost") ?? "192.168.2.1"
        let port = UInt32(defaults?.string(forKey: "receiverPort") ?? "7654") ?? 7654
        setStatus("connecting")
        connectToReceiver(host: host, port: port)
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        disconnect()
        setStatus("stopped")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .audioApp:
            handleAppAudio(sampleBuffer)
        case .audioMic, .video:
            break
        @unknown default:
            break
        }
    }

    private func setStatus(_ status: String) {
        defaults?.set(status, forKey: "broadcastStatus")
        defaults?.set(Date().timeIntervalSince1970, forKey: "broadcastStatusTime")
    }

    // MARK: - Audio Processing

    private func handleAppAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isConnected, let outputStream = outputStream else {
            tryReconnect()
            return
        }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }

        let sampleRate = UInt32(asbd.pointee.mSampleRate)
        let channels = UInt16(asbd.pointee.mChannelsPerFrame)
        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isBigEndian = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let bitsPerChannel = asbd.pointee.mBitsPerChannel

        // Diagnostic: write format info + raw bytes to shared defaults ONCE
        if defaults?.string(forKey: "debugAudio") == nil {
            let flags = String(format: "0x%X", asbd.pointee.mFormatFlags)
            var diag = "rate=\(sampleRate) ch=\(channels) bpc=\(bitsPerChannel) flags=\(flags) float=\(isFloat) ni=\(isNonInterleaved) be=\(isBigEndian)"

            // Dump first 32 raw bytes from the CMSampleBuffer
            var length = 0
            var dataPtr: UnsafeMutablePointer<Int8>?
            if let bb = CMSampleBufferGetDataBuffer(sampleBuffer) {
                CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr)
                if let p = dataPtr {
                    let bytes = Data(bytes: p, count: min(64, length))
                    diag += " len=\(length) hex=\(bytes.map { String(format: "%02x", $0) }.joined())"
                    // Interpret first 8 values as float32
                    let floats = (0..<min(8, length/4)).map { i -> Float32 in
                        bytes.withUnsafeBytes { $0.load(fromByteOffset: i * 4, as: Float32.self) }
                    }
                    diag += " f32=\(floats.map { String(format: "%.6f", $0) })"
                }
            }
            defaults?.set(diag, forKey: "debugAudio")
        }

        // Send header on first audio frame with ACTUAL format
        if !headerSent {
            actualSampleRate = sampleRate
            actualChannels = channels

            let header = AudioStreamHeader(
                sampleRate: sampleRate,
                channels: channels,
                bitsPerSample: 16
            )
            let headerData = header.toData()
            let written = headerData.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return outputStream.write(base, maxLength: headerData.count)
            }
            if written < 0 {
                isConnected = false
                setStatus("disconnected")
                return
            }
            headerSent = true
            setStatus("streaming")
        }

        guard let pcmData = extractAndConvertAudio(
            from: sampleBuffer,
            channels: Int(channels),
            isFloat: isFloat,
            isNonInterleaved: isNonInterleaved,
            isBigEndian: isBigEndian,
            bitsPerChannel: bitsPerChannel
        ) else {
            return
        }

        sendFrame(pcmData, to: outputStream)
    }

    /// Extract audio using AudioBufferList API, then convert to interleaved little-endian Int16.
    private func extractAndConvertAudio(
        from sampleBuffer: CMSampleBuffer,
        channels: Int,
        isFloat: Bool,
        isNonInterleaved: Bool,
        isBigEndian: Bool,
        bitsPerChannel: UInt32
    ) -> Data? {

        var blockBuffer: CMBlockBuffer?
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        let bufferCount = isNonInterleaved ? channels : 1
        let ablSize = MemoryLayout<AudioBufferList>.size +
                       max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.size

        let ablRaw = UnsafeMutableRawPointer.allocate(
            byteCount: ablSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let abl = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
        defer { ablRaw.deallocate() }

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: ablSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let bufferList = UnsafeMutableAudioBufferListPointer(abl)

        if isFloat && bitsPerChannel == 32 {
            if isNonInterleaved && channels > 1 {
                return convertNonInterleavedFloat32ToInterleavedInt16(
                    bufferList: bufferList,
                    channels: channels,
                    samplesPerChannel: numSamples
                )
            } else {
                guard bufferList.count > 0,
                      let data = bufferList[0].mData else { return nil }
                let totalFloats = Int(bufferList[0].mDataByteSize) / 4
                return convertInterleavedFloat32ToInt16(
                    data.assumingMemoryBound(to: Float32.self),
                    count: totalFloats
                )
            }
        } else if !isFloat && bitsPerChannel == 16 {
            if isNonInterleaved && channels > 1 {
                return interleaveInt16Channels(
                    bufferList: bufferList,
                    channels: channels,
                    samplesPerChannel: numSamples,
                    swapBytes: isBigEndian
                )
            } else {
                guard bufferList.count > 0,
                      let data = bufferList[0].mData else { return nil }
                let byteCount = Int(bufferList[0].mDataByteSize)
                if isBigEndian {
                    return swapInt16Endianness(data, byteCount: byteCount)
                }
                return Data(bytes: data, count: byteCount)
            }
        } else {
            var result = Data()
            for buf in bufferList {
                if let data = buf.mData {
                    result.append(Data(bytes: data, count: Int(buf.mDataByteSize)))
                }
            }
            return result.isEmpty ? nil : result
        }
    }

    /// Convert non-interleaved Float32 planes to interleaved Int16.
    /// Input:  Buffer0=[L1,L2,...,Ln], Buffer1=[R1,R2,...,Rn]
    /// Output: [L1,R1,L2,R2,...,Ln,Rn] as Int16
    private func convertNonInterleavedFloat32ToInterleavedInt16(
        bufferList: UnsafeMutableAudioBufferListPointer,
        channels: Int,
        samplesPerChannel: Int
    ) -> Data {
        var channelPtrs = [UnsafePointer<Float32>]()
        for ch in 0..<min(channels, bufferList.count) {
            guard let data = bufferList[ch].mData else { continue }
            channelPtrs.append(data.assumingMemoryBound(to: Float32.self))
        }
        let actualChannels = channelPtrs.count
        guard actualChannels > 0 else { return Data() }

        let samplesFromBuffer = Int(bufferList[0].mDataByteSize) / 4
        let actualSamples = min(samplesPerChannel, samplesFromBuffer)
        let totalSamples = actualSamples * actualChannels

        var output = Data(count: totalSamples * 2)
        output.withUnsafeMutableBytes { outBuf in
            guard let outPtr = outBuf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<actualSamples {
                for ch in 0..<actualChannels {
                    let sample = max(-1.0, min(1.0, channelPtrs[ch][i]))
                    outPtr[i * actualChannels + ch] = Int16(sample * Float32(Int16.max))
                }
            }
        }
        return output
    }

    /// Convert interleaved Float32 to Int16.
    private func convertInterleavedFloat32ToInt16(
        _ ptr: UnsafePointer<Float32>,
        count: Int
    ) -> Data {
        var output = Data(count: count * 2)
        output.withUnsafeMutableBytes { outBuf in
            guard let outPtr = outBuf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<count {
                let sample = max(-1.0, min(1.0, ptr[i]))
                outPtr[i] = Int16(sample * Float32(Int16.max))
            }
        }
        return output
    }

    /// Interleave already-Int16 non-interleaved channels, with optional byte-swap.
    private func interleaveInt16Channels(
        bufferList: UnsafeMutableAudioBufferListPointer,
        channels: Int,
        samplesPerChannel: Int,
        swapBytes: Bool = false
    ) -> Data {
        var channelPtrs = [UnsafePointer<Int16>]()
        for ch in 0..<min(channels, bufferList.count) {
            guard let data = bufferList[ch].mData else { continue }
            channelPtrs.append(data.assumingMemoryBound(to: Int16.self))
        }
        let actualChannels = channelPtrs.count
        guard actualChannels > 0 else { return Data() }

        let actualSamples = min(samplesPerChannel, Int(bufferList[0].mDataByteSize) / 2)
        let totalSamples = actualSamples * actualChannels

        var output = Data(count: totalSamples * 2)
        output.withUnsafeMutableBytes { outBuf in
            guard let outPtr = outBuf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<actualSamples {
                for ch in 0..<actualChannels {
                    let sample = channelPtrs[ch][i]
                    outPtr[i * actualChannels + ch] = swapBytes ? sample.byteSwapped : sample
                }
            }
        }
        return output
    }

    /// Swap endianness of every Int16 sample in a raw buffer.
    private func swapInt16Endianness(_ data: UnsafeMutableRawPointer, byteCount: Int) -> Data {
        let sampleCount = byteCount / 2
        let srcPtr = data.assumingMemoryBound(to: Int16.self)
        var output = Data(count: byteCount)
        output.withUnsafeMutableBytes { outBuf in
            guard let outPtr = outBuf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                outPtr[i] = srcPtr[i].byteSwapped
            }
        }
        return output
    }

    // MARK: - Network

    private func sendFrame(_ pcmData: Data, to outputStream: OutputStream) {
        let frame = AudioStreamFrame.wrap(pcmData)
        frame.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                let written = outputStream.write(base, maxLength: frame.count)
                if written < 0 {
                    isConnected = false
                    headerSent = false
                    setStatus("disconnected")
                }
            }
        }
    }

    private func connectToReceiver(host: String, port: UInt32) {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocketToHost(
            kCFAllocatorDefault,
            host as CFString,
            port,
            &readStream,
            &writeStream
        )

        guard let cfOutput = writeStream?.takeRetainedValue() else { return }
        readStream?.release()

        let output = cfOutput as OutputStream
        output.open()
        self.outputStream = output
        self.isConnected = true
        self.headerSent = false
        self.lastConnectAttempt = Date()
    }

    private func tryReconnect() {
        guard Date().timeIntervalSince(lastConnectAttempt) > reconnectInterval else { return }
        let host = defaults?.string(forKey: "receiverHost") ?? "192.168.2.1"
        let port = UInt32(defaults?.string(forKey: "receiverPort") ?? "7654") ?? 7654
        connectToReceiver(host: host, port: port)
    }

    private func disconnect() {
        outputStream?.close()
        outputStream = nil
        isConnected = false
        headerSent = false
    }
}
