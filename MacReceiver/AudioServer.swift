import Foundation
import Network
import AVFoundation
import AppKit
import UniformTypeIdentifiers

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
    private var startTime: Date?
    private var statsTimer: Timer?
    private var wavFileHandle: FileHandle?
    private var wavFilePath: URL?
    private var wavDataLength: UInt32 = 0
    private var sampleRate: Double = 0
    private var channels: Int = 0

    /// Audio pipeline — owns the NWConnection and audio engine, runs off main thread
    private let pipeline = AudioPipeline()

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
                    self.statusText = "Listening on port \(port)..."
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
        pipeline.stop()
        listener?.cancel()
        listener = nil
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
        pipeline.stop()

        isConnected = true
        totalBytes = 0
        startTime = Date()
        statusText = "Connected — reading header..."

        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startTime else { return }
                self.elapsed = Date().timeIntervalSince(start)
                let (l, r) = self.pipeline.levels
                self.levelLeft = l
                self.levelRight = r
                self.totalBytes = self.pipeline.bytesReceived
            }
        }

        // Hand connection to the pipeline — it owns the read loop and audio from here
        pipeline.start(connection: conn) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .headerParsed(let sr, let ch, let bps):
                    self.sampleRate = Double(sr)
                    self.channels = Int(ch)
                    self.formatText = "\(sr) Hz · \(ch)ch · \(bps)-bit"
                    self.statusText = "Streaming"
                case .disconnected:
                    self.statusText = "Disconnected"
                    self.isConnected = false
                    self.statsTimer?.invalidate()
                    self.levelLeft = 0
                    self.levelRight = 0
                case .error(let msg):
                    self.statusText = msg
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        let panel = NSSavePanel()
        panel.title = "Save Recording"
        panel.nameFieldStringValue = "GameCapture_\(Int(Date().timeIntervalSince1970)).wav"
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: url.path) else { return }

        let header = createWAVHeader(dataSize: 0, sampleRate: UInt32(sampleRate), channels: UInt16(channels), bitsPerSample: 16)
        fh.write(header)

        wavFileHandle = fh
        wavFilePath = url
        wavDataLength = 0
        isRecording = true
        pipeline.recordingFileHandle = fh
    }

    func stopRecording() {
        guard isRecording, let fh = wavFileHandle, let url = wavFilePath else { return }

        pipeline.recordingFileHandle = nil

        // Finalize WAV header with actual data length
        let dataLen = pipeline.recordedBytes
        fh.seek(toFileOffset: 0)
        let header = createWAVHeader(dataSize: dataLen, sampleRate: UInt32(sampleRate), channels: UInt16(channels), bitsPerSample: 16)
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

// MARK: - Audio Pipeline

/// Events sent from pipeline back to AudioServer for UI updates
enum PipelineEvent: Sendable {
    case headerParsed(sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16)
    case disconnected
    case error(String)
}

/// Owns NWConnection + AVAudioEngine. Runs entirely on a dedicated high-priority queue.
/// The main thread is NEVER in the audio path.
final class AudioPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.audiotap.audio", qos: .userInteractive)

    private var connection: NWConnection?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var channelCount: Int = 0
    private var callback: (@Sendable (PipelineEvent) -> Void)?

    private let headerSize = 12
    private let magic: UInt32 = 0x41554450

    // Pending buffer cap
    private var pendingBuffers: Int = 0
    private let maxPending = 3

    // Level meters (polled by main thread timer)
    private var _levelLeft: Float = 0
    private var _levelRight: Float = 0
    private var lastLevelTime: UInt64 = 0

    // Stats
    private var _bytesReceived: Int = 0
    private var _recordedBytes: UInt32 = 0

    // Recording
    var recordingFileHandle: FileHandle?

    var levels: (Float, Float) { (_levelLeft, _levelRight) }
    var bytesReceived: Int { _bytesReceived }
    var recordedBytes: UInt32 { _recordedBytes }

    func start(connection conn: NWConnection, callback: @escaping @Sendable (PipelineEvent) -> Void) {
        queue.async { [self] in
            stopInternal()

            self.connection = conn
            self.callback = callback
            self._bytesReceived = 0
            self._recordedBytes = 0

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.readHeader()
                case .failed, .cancelled:
                    self.callback?(.disconnected)
                    self.stopInternal()
                default:
                    break
                }
            }

            conn.start(queue: self.queue)
        }
    }

    func stop() {
        queue.sync { stopInternal() }
    }

    private func stopInternal() {
        connection?.cancel()
        connection = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        format = nil
        callback = nil
        _levelLeft = 0
        _levelRight = 0
        pendingBuffers = 0
    }

    // MARK: - Read Loop (runs on audioQueue)

    private func readHeader() {
        connection?.receive(minimumIncompleteLength: headerSize, maximumLength: headerSize) { [weak self] data, _, _, error in
            guard let self, let data, data.count == self.headerSize else {
                self?.callback?(.error("Header read failed"))
                return
            }

            let m = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
            guard m == self.magic else {
                self.callback?(.error("Bad magic: 0x\(String(format: "%08X", m))"))
                return
            }

            let sr = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
            let ch = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt16.self).littleEndian }
            let bps = data.withUnsafeBytes { $0.load(fromByteOffset: 10, as: UInt16.self).littleEndian }

            self.setupEngine(sampleRate: Double(sr), channels: Int(ch))
            self.callback?(.headerParsed(sampleRate: sr, channels: ch, bitsPerSample: bps))
            self.readFrameSize()
        }
    }

    private func readFrameSize() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, let data, data.count == 4 else { return }
            let frameSize = Int(data.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
            guard frameSize > 0 && frameSize < 1_048_576 else {
                self.readFrameSize()
                return
            }
            self.readFrameData(size: frameSize)
        }
    }

    private func readFrameData(size: Int) {
        receiveExact(size: size) { [weak self] data in
            guard let self, let data else { return }
            self.processAudio(data)
            self.readFrameSize()
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

    private func setupEngine(sampleRate: Double, channels: Int) {
        player?.stop()
        engine?.stop()

        let eng = AVAudioEngine()
        let plr = AVAudioPlayerNode()

        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else { return }

        eng.attach(plr)
        eng.connect(plr, to: eng.mainMixerNode, format: fmt)

        do { try eng.start() } catch { return }
        plr.play()

        engine = eng
        player = plr
        format = fmt
        channelCount = channels
        pendingBuffers = 0
    }

    private func processAudio(_ data: Data) {
        guard let format, let player else { return }

        _bytesReceived += data.count

        let bytesPerFrame = Int(format.streamDescription.pointee.mBitsPerChannel / 8) * Int(format.channelCount)
        let frameCount = AVAudioFrameCount(data.count / bytesPerFrame)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

        buffer.frameLength = frameCount
        data.withUnsafeBytes { src in
            if let srcBase = src.baseAddress, let dst = buffer.int16ChannelData?[0] {
                memcpy(dst, srcBase, data.count)
            }
        }

        // Drop frame if too many pending — prevents latency buildup
        guard pendingBuffers < maxPending else { return }

        pendingBuffers += 1
        player.scheduleBuffer(buffer) { [weak self] in
            self?.pendingBuffers -= 1
        }

        // Record
        if let fh = recordingFileHandle {
            fh.write(data)
            _recordedBytes += UInt32(data.count)
        }

        // Throttled level meters (~50ms)
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastLevelTime > 50_000_000 else { return }
        lastLevelTime = now

        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let count = samples.count
            guard count > 0 else { return }

            var sumL: Float = 0
            var sumR: Float = 0
            let ch = max(1, channelCount)
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

            _levelLeft = max(0, min(1, 1 + (20 * log10(max(rmsL, 0.0001))) / 60))
            _levelRight = max(0, min(1, 1 + (20 * log10(max(rmsR, 0.0001))) / 60))
        }
    }
}
