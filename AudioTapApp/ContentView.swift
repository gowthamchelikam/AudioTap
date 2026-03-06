import SwiftUI
import UIKit
import ReplayKit

struct ContentView: View {
    @AppStorage("receiverHost", store: UserDefaults(suiteName: "group.audiotap.shared"))
    private var host = "192.168.2.1"

    @AppStorage("receiverPort", store: UserDefaults(suiteName: "group.audiotap.shared"))
    private var port = "7654"

    @State private var status = ""
    @State private var statusTimer: Timer?
    @State private var screenLockDisabled = false

    private var isStreaming: Bool { status == "streaming" }
    private var isConnecting: Bool { status == "connecting" }
    private var isActive: Bool { isStreaming || isConnecting }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // MARK: - Header
            VStack(spacing: 16) {
                Image("IXGLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 48)

                Text("GameCapture")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                if !status.isEmpty {
                    statusPill
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: status)

            Spacer().frame(height: 32)

            // MARK: - Connection Settings
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("HOST")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        TextField("192.168.2.1", text: $host)
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .keyboardType(.decimalPad)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("PORT")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        TextField("7654", text: $port)
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .keyboardType(.numberPad)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .frame(width: 90)
                }
            }
            .padding(16)
            .background(Color(.systemGray6).opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)

            Spacer().frame(height: 20)

            // MARK: - Broadcast Button
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        isStreaming
                            ? LinearGradient(colors: [.green, .green.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [.red, .red.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(height: 56)
                    .shadow(color: (isStreaming ? Color.green : Color.red).opacity(0.3), radius: 12, y: 4)
                    .allowsHitTesting(false)

                HStack(spacing: 10) {
                    Image(systemName: isStreaming ? "stop.circle.fill" : "record.circle")
                        .font(.title3)
                        .foregroundStyle(.white)
                    Text(isStreaming ? "Stop Broadcast" : "Start Broadcast")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .allowsHitTesting(false)

                BroadcastPickerView()
                    .frame(maxWidth: .infinity, maxHeight: 56)
            }
            .frame(height: 56)
            .padding(.horizontal, 20)

            Spacer().frame(height: 24)

            // MARK: - Keep Screen On
            HStack {
                Image(systemName: screenLockDisabled ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(screenLockDisabled ? .green : .secondary)
                    .frame(width: 20)

                Text("Keep Screen On")
                    .font(.system(size: 15, weight: .medium))

                Spacer()

                Toggle("", isOn: $screenLockDisabled)
                    .labelsHidden()
                    .onChange(of: screenLockDisabled) { newValue in
                        UIApplication.shared.isIdleTimerDisabled = newValue
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemGray6).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)

            Spacer().frame(height: 12)

            Text("Screen lock ends the broadcast (iOS limitation)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary.opacity(0.7))

            Spacer()
        }
        .onAppear { startPolling() }
        .onDisappear { statusTimer?.invalidate() }
    }

    // MARK: - Polling

    private func startPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let defaults = UserDefaults(suiteName: "group.audiotap.shared")
            let raw = defaults?.string(forKey: "broadcastStatus") ?? ""
            let ts = defaults?.double(forKey: "broadcastStatusTime") ?? 0
            let age = Date().timeIntervalSince1970 - ts

            if age > 10 && (raw == "stopped" || raw == "failed" || raw == "disconnected") {
                status = ""
            } else {
                status = raw
            }

            // Auto-enable keep-screen-on when streaming
            if status == "streaming" && !screenLockDisabled {
                screenLockDisabled = true
                UIApplication.shared.isIdleTimerDisabled = true
            } else if status == "stopped" && screenLockDisabled {
                screenLockDisabled = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    // MARK: - Status Pill

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .fill(statusColor.opacity(0.4))
                        .frame(width: 16, height: 16)
                        .opacity(isStreaming ? 1 : 0)
                        .scaleEffect(isStreaming ? 1.5 : 1)
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: isStreaming)
                )
            Text(statusLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(statusColor.opacity(0.1), in: Capsule())
    }

    private var statusColor: Color {
        switch status {
        case "streaming": .green
        case "connecting": .orange
        case "failed", "disconnected": .red
        case "stopped": .secondary
        default: .secondary
        }
    }

    private var statusLabel: String {
        switch status {
        case "streaming": "Streaming to Mac"
        case "connecting": "Connecting…"
        case "failed": "Connection failed"
        case "disconnected": "Disconnected"
        case "stopped": "Broadcast ended"
        default: status
        }
    }
}

// MARK: - Broadcast Picker

struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = "com.audiotap.app.broadcast"
        picker.showsMicrophoneButton = false
        picker.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: container.topAnchor),
            picker.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            picker.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Hide the default icon — keep tappable
        picker.tintColor = .clear
        // Stretch internal button to fill
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    button.topAnchor.constraint(equalTo: picker.topAnchor),
                    button.leadingAnchor.constraint(equalTo: picker.leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: picker.trailingAnchor),
                    button.bottomAnchor.constraint(equalTo: picker.bottomAnchor),
                ])
                // Remove the default image completely
                button.setImage(nil, for: .normal)
            }
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
