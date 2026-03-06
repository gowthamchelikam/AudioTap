import SwiftUI
import ReplayKit

struct ContentView: View {
    @AppStorage("receiverHost", store: UserDefaults(suiteName: "group.audiotap.shared"))
    private var host = "192.168.2.1"

    @AppStorage("receiverPort", store: UserDefaults(suiteName: "group.audiotap.shared"))
    private var port = "7654"

    @State private var saved = false
    @State private var status = ""
    @State private var debugAudio = ""
    @State private var statusTimer: Timer?

    var body: some View {
        VStack(spacing: 24) {
            Text("AudioTap")
                .font(.largeTitle.bold())

            Text("Capture app audio and stream to Mac")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !status.isEmpty {
                statusPill
            }

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac Receiver IP")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("192.168.2.1", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Port")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("7654", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                }
            }
            .padding(.horizontal)

            Button {
                saved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
            } label: {
                Text(saved ? "Saved!" : "Save Settings")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.red)
                    .frame(height: 56)
                    .allowsHitTesting(false)

                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .font(.title2)
                        .foregroundStyle(.white)
                    Text("Start Broadcast")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .allowsHitTesting(false)

                BroadcastPickerView()
                    .frame(maxWidth: .infinity, maxHeight: 56)
            }
            .frame(height: 56)
            .padding(.horizontal)

            Text("Tap the red button, then switch to your game or app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if !debugAudio.isEmpty {
                Text(debugAudio)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(8)
                    .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
            }
        }
        .padding()
        .onAppear { startPolling() }
        .onDisappear { statusTimer?.invalidate() }
    }

    private func startPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let defaults = UserDefaults(suiteName: "group.audiotap.shared")
            let raw = defaults?.string(forKey: "broadcastStatus") ?? ""
            let ts = defaults?.double(forKey: "broadcastStatusTime") ?? 0
            let age = Date().timeIntervalSince1970 - ts
            // Clear stale status after 10 seconds of no update
            if age > 10 && (raw == "stopped" || raw == "failed" || raw == "disconnected") {
                status = ""
            } else {
                status = raw
            }
            debugAudio = defaults?.string(forKey: "debugAudio") ?? ""
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusLabel)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(statusColor.opacity(0.12), in: Capsule())
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
        case "connecting": "Connecting..."
        case "failed": "Connection failed"
        case "disconnected": "Disconnected"
        case "stopped": "Broadcast ended"
        default: status
        }
    }
}

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
        // Hide the default icon but keep the button tappable
        picker.tintColor = .clear
        // Stretch the internal button to fill the entire area
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    button.topAnchor.constraint(equalTo: picker.topAnchor),
                    button.leadingAnchor.constraint(equalTo: picker.leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: picker.trailingAnchor),
                    button.bottomAnchor.constraint(equalTo: picker.bottomAnchor),
                ])
            }
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
