import Foundation
import Network
import AVFoundation

/// TCP server that receives AUDP audio from iPhone and plays it.
@MainActor
final class AudioServer: ObservableObject {
    @Published var isListening = false
    @Published var isConnected = false
    @Published var statusText = "Idle"
    @Published var formatText = ""
    @Published var elapsed: TimeInterval = 0
    @Published var totalBytes: Int = 0
    @Published var levelLeft: Float = 0
    @Published var levelRight: Float = 0
    @Published var isRecording = false

    private var listener: NWListener?
    private var connection: NWConnection?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var sampleRate: Double = 0
    private var channels: Int = 0
    private var startTime: Date?
    private var statsTimer: Timer?
    private var wavFileHandle: FileHandle?
    private var wavFilePath: URL?
    private var wavDataLength: UInt32 = 0

    private let headerSize = 12
    private let magic: UInt32 = 0x41554450

    // MARK: - Server Control

    func start(port: UInt16) {
        stop()

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            statusText = "Failed to create listener: \(error.localizedDescription)"
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isListening = true
                    self.statusText = "Listening on port \(port)…"
                case .failed(let error):
                    self.statusText = "Listener failed: \(error.localizedDescription)"
                    self.isListening = false
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.handleNewConnection(conn)
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        stopRecording()
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        stopAudio()
        isListening = false
        isConnected = false
        statusText = "Idle"
        formatText = ""
        elapsed = 0
        totalBytes = 0
        levelLeft = 0
        levelRight = 0
        statsTimer?.invalidate()
        statsTimer = nil
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ conn: NWConnection) {
        // Close existing connection
        connection?.cancel()
        stopAudio()

        connection = conn
        isConnected = true
        totalBytes = 0
        startTime = Date()
        statusText = "Connected — reading header…"

        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startTime else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.readHeader()
                case .failed, .cancelled:
                    self.statusText = "Disconnected"
                    self.isConnected = false
                    self.stopAudio()
                    self.statsTimer?.invalidate()
                    self.levelLeft = 0
                    self.levelRight = 0
                default:
                    break
                }
            }
        }

        conn.start(queue: .main)
    }

    private func readHeader() {
        connection?.receive(minimumIncompleteLength: headerSize, maximumLength: headerSize) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, let data, data.count == self.headerSize else {
                    self?.statusText = "Header read failed"
                    return
                }

                let m = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
                guard m == self.magic else {
                    self.statusText = "Bad magic: 0x\(String(format: "%08X", m))"
                    return
                }

                let sr = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
                let ch = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt16.self).littleEndian }
                let bps = data.withUnsafeBytes { $0.load(fromByteOffset: 10, as: UInt16.self).littleEndian }

                self.sampleRate = Double(sr)
                self.channels = Int(ch)
                self.formatText = "\(sr) Hz · \(ch)ch · \(bps)-bit"
                self.statusText = "Streaming"

                self.setupAudio(sampleRate: Double(sr), channels: Int(ch))
                self.readFrameSize()
            }
        }
    }

    private func readFrameSize() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, let data, data.count == 4 else { return }
                let frameSize = Int(data.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
                guard frameSize > 0 && frameSize < 1_048_576 else {
                    self.readFrameSize()
                    return
                }
                self.readFrameData(size: frameSize)
            }
        }
    }

    private func readFrameData(size: Int) {
        receiveExact(size: size) { [weak self] data in
            Task { @MainActor in
                guard let self, let data else { return }
                self.totalBytes += data.count
                self.processAudio(data)
                self.readFrameSize()
            }
        }
    }

    private func receiveExact(size: Int, accumulated: Data = Data(), completion: @escaping (Data?) -> Void) {
        let remaining = size - accumulated.count
        guard remaining > 0 else {
            completion(accumulated)
            return
        }

        connection?.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, _, error in
            guard let data, !data.isEmpty else {
                completion(nil)
                return
            }
            var combined = accumulated
            combined.append(data)
            if combined.count >= size {
                completion(combined)
            } else {
                self?.receiveExact(size: size, accumulated: combined, completion: completion)
            }
        }
    }

    // MARK: - Audio Engine

    private func setupAudio(sampleRate: Double, channels: Int) {
        stopAudio()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            statusText = "Failed to create audio format"
            return
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            statusText = "Audio engine failed: \(error.localizedDescription)"
            return
        }

        player.play()

        audioEngine = engine
        playerNode = player
        audioFormat = format
    }

    private func processAudio(_ data: Data) {
        guard let format = audioFormat, let player = playerNode else { return }

        let frameCount = AVAudioFrameCount(data.count / (Int(format.streamDescription.pointee.mBitsPerChannel / 8) * Int(format.channelCount)))
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

        buffer.frameLength = frameCount
        data.withUnsafeBytes { src in
            if let srcBase = src.baseAddress, let dst = buffer.int16ChannelData?[0] {
                memcpy(dst, srcBase, data.count)
            }
        }

        // Calculate levels
        updateLevels(data: data)

        // Play
        player.scheduleBuffer(buffer)

        // Record
        if isRecording, let fh = wavFileHandle {
            fh.write(data)
            wavDataLength += UInt32(data.count)
        }
    }

    private func updateLevels(data: Data) {
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let count = samples.count
            guard count > 0 else { return }

            var sumL: Float = 0
            var sumR: Float = 0
            let ch = max(1, channels)
            let frames = count / ch

            for i in 0..<frames {
                let l = Float(samples[i * ch]) / 32768.0
                sumL += l * l
                if ch > 1 {
                    let r = Float(samples[i * ch + 1]) / 32768.0
                    sumR += r * r
                }
            }

            let rmsL = sqrt(sumL / Float(frames))
            let rmsR = ch > 1 ? sqrt(sumR / Float(frames)) : rmsL

            // Convert to dB-ish scale (0...1)
            let dbL = max(0, min(1, 1 + (20 * log10(max(rmsL, 0.0001))) / 60))
            let dbR = max(0, min(1, 1 + (20 * log10(max(rmsR, 0.0001))) / 60))

            Task { @MainActor in
                self.levelLeft = dbL
                self.levelRight = dbR
            }
        }
    }

    private func stopAudio() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        audioFormat = nil
    }

    // MARK: - Recording

    func startRecording() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let filename = "GameCapture_\(Int(Date().timeIntervalSince1970)).wav"
        let url = desktop.appendingPathComponent(filename)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: url.path) else { return }

        // Write placeholder WAV header (44 bytes)
        let header = createWAVHeader(dataSize: 0, sampleRate: UInt32(sampleRate), channels: UInt16(channels), bitsPerSample: 16)
        fh.write(header)

        wavFileHandle = fh
        wavFilePath = url
        wavDataLength = 0
        isRecording = true
    }

    func stopRecording() {
        guard isRecording, let fh = wavFileHandle, let url = wavFilePath else { return }

        // Rewrite header with correct size
        fh.seek(toFileOffset: 0)
        let header = createWAVHeader(dataSize: wavDataLength, sampleRate: UInt32(sampleRate), channels: UInt16(channels), bitsPerSample: 16)
        fh.write(header)
        fh.closeFile()

        wavFileHandle = nil
        wavFilePath = nil
        isRecording = false
        statusText = "Saved: \(url.lastPathComponent)"
    }

    private func createWAVHeader(dataSize: UInt32, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
        var header = Data(capacity: 44)
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let fileSize = dataSize + 36

        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        return header
    }
}
