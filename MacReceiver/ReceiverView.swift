import SwiftUI
import Darwin

struct ReceiverView: View {
    @StateObject private var server = AudioServer()
    @State private var portText = "7654"
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            VStack(spacing: 8) {
                Image("IXGLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 36)

                Text("GameCapture")
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Text("Mac Receiver")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().padding(.horizontal)

            // MARK: - Status
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(server.statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }

                if !server.formatText.isEmpty {
                    HStack {
                        Image(systemName: "waveform")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(server.formatText)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                if server.isConnected {
                    HStack(spacing: 16) {
                        Label(formatDuration(server.elapsed), systemImage: "clock")
                        Label(formatBytes(server.totalBytes), systemImage: "arrow.down.circle")
                        Spacer()
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color(.controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // MARK: - Listen Address
            if server.isListening {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LISTEN ADDRESS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(localAddresses, id: \.self) { addr in
                        HStack(spacing: 8) {
                            Image(systemName: addr.contains("bridge") ? "cable.connector" : "wifi")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 14)

                            Text(addr)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)

                            Spacer()

                            Button {
                                let ip = addr.components(separatedBy: " ").first ?? addr
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ip, forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                            } label: {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.borderless)
                            .help("Copy IP to clipboard")
                        }
                    }
                }
                .padding(12)
                .background(Color(.controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            // MARK: - Level Meters
            if server.isConnected {
                VStack(spacing: 6) {
                    LevelMeterView(label: "L", level: server.levelLeft)
                    LevelMeterView(label: "R", level: server.levelRight)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .animation(.linear(duration: 0.1), value: server.levelLeft)
                .animation(.linear(duration: 0.1), value: server.levelRight)
            }

            Spacer()

            // MARK: - Controls
            VStack(spacing: 12) {
                // Port
                HStack(spacing: 8) {
                    Text("PORT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("7654", text: $portText)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Spacer()

                    // Record button
                    if server.isConnected {
                        Button {
                            if server.isRecording {
                                server.stopRecording()
                            } else {
                                server.startRecording()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(server.isRecording ? .red : .secondary)
                                    .frame(width: 8, height: 8)
                                Text(server.isRecording ? "Stop Rec" : "Record")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // Start/Stop
                Button {
                    if server.isListening {
                        server.stop()
                    } else {
                        let port = UInt16(portText) ?? 7654
                        server.start(port: port)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: server.isListening ? "stop.fill" : "play.fill")
                            .font(.system(size: 12))
                        Text(server.isListening ? "Stop Listening" : "Start Listening")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(server.isListening ? .red : .green)
            }
            .padding(16)
        }
        .frame(width: 400, height: 560)
        .onAppear {
            let port = UInt16(portText) ?? 7654
            server.start(port: port)
        }
    }

    private var statusColor: Color {
        if server.isConnected { return .green }
        if server.isListening { return .orange }
        return .secondary
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private var localAddresses: [String] {
        var addrs: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let sa = ptr.pointee.ifa_addr.pointee
            guard sa.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            // Skip loopback and link-local
            guard name != "lo0" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.sa_len),
                        &hostname, socklen_t(hostname.count),
                        nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)
            guard !ip.isEmpty, !ip.hasPrefix("169.254") else { continue }

            let label: String
            if name.hasPrefix("bridge") {
                label = "\(ip):\(portText) (bridge — USB)"
            } else if name.hasPrefix("en") {
                label = "\(ip):\(portText) (\(name))"
            } else {
                label = "\(ip):\(portText) (\(name))"
            }
            addrs.append(label)
        }
        return addrs
    }
}

// MARK: - Level Meter

struct LevelMeterView: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(.separatorColor))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(meterGradient)
                        .frame(width: max(0, geo.size.width * CGFloat(level)))
                }
            }
            .frame(height: 8)
        }
    }

    private var meterGradient: LinearGradient {
        LinearGradient(
            colors: [.green, .green, .yellow, .red],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
