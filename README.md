# GameCapture

Capture iPhone app/game audio via ReplayKit and stream it in real-time over TCP to a Mac. Built for mobile esports setups where USB Internet Sharing is used and USB audio (IDAM) is unavailable.

## Download

- **iOS (TestFlight)**: https://testflight.apple.com/join/FcGC3Up3
- **macOS (TestFlight)**: https://testflight.apple.com/join/bWZxFbtM
- **Testing Guide (PDF)**: [GameCapture-Testing-Guide.pdf](docs/GameCapture-Testing-Guide.pdf)

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   iPhone                         │
│                                                  │
│  ┌──────────────┐     ┌───────────────────────┐ │
│  │ GameCapture  │     │  Broadcast Extension  │ │
│  │  (main app)  │     │  (SampleHandler)      │ │
│  │              │     │                       │ │
│  │ • IP/Port UI │     │ • ReplayKit capture   │ │
│  │ • Status     │────▶│ • Audio conversion    │ │
│  │ • Broadcast  │ App │ • TCP streaming       │ │
│  │   picker     │Group│                       │ │
│  └──────────────┘     └───────────┬───────────┘ │
│                                   │ TCP          │
└───────────────────────────────────┼──────────────┘
                                    │ USB Internet
                                    │ Sharing
┌───────────────────────────────────┼──────────────┐
│                Mac                │               │
│                                   ▼               │
│  ┌────────────────────────────────────────────┐  │
│  │  GameCapture Receiver (native macOS app)    │  │
│  │                                             │  │
│  │  • TCP server on port 7654                  │  │
│  │  • Reads AUDP header (format negotiation)   │  │
│  │  • Receives size-prefixed PCM frames        │  │
│  │  • AVAudioEngine real-time playback         │  │
│  │  • L/R level meters                         │  │
│  │  • WAV recording to Desktop                 │  │
│  └────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

### How It Works

1. The **iOS app** (GameCapture) provides a UI to configure the Mac's IP address and port, and hosts a `RPSystemBroadcastPickerView` to start screen broadcasting. A "Keep Screen On" toggle prevents auto-lock (locking the screen stops the broadcast — iOS limitation).

2. When the user starts a broadcast, iOS launches the **Broadcast Upload Extension** as a separate process. The extension receives `processSampleBuffer` callbacks with `.audioApp` sample buffers containing the audio from whatever app is in the foreground.

3. The **SampleHandler** in the extension:
   - Opens a TCP connection to the Mac receiver
   - Reads the audio format from the `CMSampleBuffer`'s `AudioStreamBasicDescription`
   - Sends a 12-byte AUDP header with sample rate, channels, and bit depth
   - Extracts audio via the `AudioBufferList` API
   - Converts to interleaved little-endian signed 16-bit PCM (handling big-endian, float32, and non-interleaved formats from ReplayKit)
   - Sends size-prefixed PCM frames over TCP

4. The **Mac receiver app** (GameCapture Receiver):
   - Auto-starts a TCP listener on port 7654
   - Reads the 12-byte AUDP header to configure playback
   - Plays audio in real-time via AVAudioEngine
   - Shows L/R level meters, connection status, and audio format
   - Optionally records to WAV on Desktop

### Audio Format Handling

ReplayKit delivers audio in various formats depending on the device:

| Device | Format | Flags | Notes |
|--------|--------|-------|-------|
| iPhone Air | 44100Hz 2ch 16-bit | `0xE` (big-endian, signed, packed) | Requires byte-swap |
| Other devices | 48000Hz 2ch 32-bit float | `0x29` (float, non-interleaved) | Requires float→int16 + interleaving |

The SampleHandler handles all combinations:
- **Float32 non-interleaved** → interleave channels + convert to int16
- **Float32 interleaved** → convert to int16
- **Int16 non-interleaved** → interleave channels (+ byte-swap if big-endian)
- **Int16 interleaved** → passthrough (+ byte-swap if big-endian)

### Communication Between App and Extension

The main app and broadcast extension are separate processes. They communicate via **App Groups** (`group.audiotap.shared`) shared `UserDefaults`:

| Key | Direction | Purpose |
|-----|-----------|---------|
| `receiverHost` | App → Extension | Mac IP address |
| `receiverPort` | App → Extension | TCP port |
| `broadcastStatus` | Extension → App | Status: connecting/streaming/failed/stopped |
| `broadcastStatusTime` | Extension → App | Timestamp for stale status detection |
| `debugAudio` | Extension → App | Audio format diagnostic info |

## Prerequisites

- Mac with macOS 13+ and Xcode 15+
- iPhone with iOS 16+
- Apple Developer account (paid recommended; free accounts expire after 7 days)
- USB cable (Lightning or USB-C)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Quick Start

### 1. Build & Install the iOS App

```bash
cd GameCapture
xcodegen generate

xcodebuild -project GameCapture.xcodeproj \
  -scheme AudioTapApp \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  build

# Install on connected iPhone
xcrun devicectl device install app \
  --device <DEVICE_ID> \
  ~/Library/Developer/Xcode/DerivedData/GameCapture-*/Build/Products/Debug-iphoneos/AudioTapApp.app
```

Or open `GameCapture.xcodeproj` in Xcode, select your team in all targets, and hit `Cmd+R`.

**First-time setup on iPhone:**
- Trust the developer profile: **Settings → General → VPN & Device Management**
- Enable Developer Mode: **Settings → Privacy & Security → Developer Mode**

### 2. Build & Run the Mac Receiver

```bash
xcodebuild -project GameCapture.xcodeproj \
  -scheme GameCaptureReceiver \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates \
  build

# Launch it
open ~/Library/Developer/Xcode/DerivedData/GameCapture-*/Build/Products/Debug/GameCaptureReceiver.app
```

Or select the `GameCaptureReceiver` scheme in Xcode and hit `Cmd+R`.

The receiver auto-starts listening on port 7654. Features:
- Real-time audio playback via AVAudioEngine
- L/R level meters
- Connection status and audio format display
- Record to WAV (saves to Desktop)

### 3. Set Up USB Internet Sharing

1. Connect iPhone to Mac via USB
2. **System Settings → General → Sharing → Internet Sharing**
3. Share from: **Ethernet** (or Wi-Fi) → To: **iPhone USB**
4. Toggle Internet Sharing **ON**
5. On iPhone, disable Wi-Fi to force traffic over USB

Find the Mac's USB bridge IP:
```bash
ifconfig bridge100 | grep inet
# Typically 192.168.2.1
```

### 4. Stream Audio

1. Open **GameCapture** on iPhone
2. Set the Mac IP (e.g. `192.168.2.1`) and port (`7654`)
3. Tap the red **Start Broadcast** button and confirm
4. Switch to your game — audio streams to Mac in real-time
5. Monitor levels and record from the Mac receiver app

### Alternative: Python Receiver

A lightweight Python receiver is also included for headless/scripted use:

```bash
brew install portaudio && pip3 install pyaudio

python3 mac-receiver/audio_receiver.py                        # Play through speakers
python3 mac-receiver/audio_receiver.py -o recording.wav       # Play + save to WAV
python3 mac-receiver/audio_receiver.py --no-play -o out.wav   # Save only
python3 mac-receiver/audio_receiver.py --list-devices          # List audio devices
python3 mac-receiver/audio_receiver.py -d 2 -p 8000           # Custom device + port
```

## Wire Protocol

Binary, little-endian, over TCP.

**Header** (12 bytes, sent once per connection):

| Offset | Size | Type   | Value                          |
|--------|------|--------|--------------------------------|
| 0      | 4    | UInt32 | Magic: `0x41554450` ("AUDP")   |
| 4      | 4    | UInt32 | Sample rate (e.g. 44100)       |
| 8      | 2    | UInt16 | Channels (1 or 2)              |
| 10     | 2    | UInt16 | Bits per sample (16)           |

**Data frames** (repeated):

| Offset | Size | Type   | Value                          |
|--------|------|--------|--------------------------------|
| 0      | 4    | UInt32 | Frame size in bytes (N)        |
| 4      | N    | bytes  | Interleaved little-endian PCM  |

Typical bandwidth: 44100Hz × 2ch × 16-bit = ~176 KB/s = 1.4 Mbps. Trivial for USB.

## Project Structure

```
GameCapture/
├── project.yml                       # XcodeGen project spec (3 targets)
├── AudioTapApp/                      # iOS app target (GameCapture)
│   ├── AudioTapApp.swift             # @main SwiftUI entry point
│   ├── ContentView.swift             # Settings UI + broadcast picker
│   ├── Assets.xcassets/              # App icon + IXG logo
│   ├── AudioTapApp.entitlements      # App Groups
│   └── Info.plist
├── AudioTapBroadcast/                # Broadcast Extension (GameCapture)
│   ├── SampleHandler.swift           # Audio capture, conversion, TCP streaming
│   ├── AudioTapBroadcast.entitlements
│   └── Info.plist
├── Shared/                           # Code shared by iOS targets
│   └── AudioStreamProtocol.swift     # AUDP header + frame wire format
├── MacReceiver/                      # macOS receiver app target
│   ├── MacReceiverApp.swift          # @main SwiftUI entry point
│   ├── ReceiverView.swift            # Receiver UI + level meters
│   ├── AudioServer.swift             # TCP server + AVAudioEngine playback
│   ├── Assets.xcassets/              # App icon + IXG logo
│   ├── MacReceiver.entitlements
│   └── Info.plist
├── mac-receiver/                     # Alternative Python receiver
│   ├── audio_receiver.py
│   └── requirements.txt
└── docs/
    ├── GameCapture-Testing-Guide.pdf  # Testing guide for Intercom dev team
    └── white-noise-debugging.md      # Post-mortem: big-endian byte-swap fix
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| No connection | Check Mac firewall allows port 7654. Test: `nc -l 7654` |
| Port in use | `kill $(lsof -ti :7654)` — or quit the Mac receiver app |
| White noise | Endianness mismatch — see [White Noise Debugging](docs/white-noise-debugging.md) |
| No audio data | Some apps block audio capture (AVPlayer, Safari, Music). Most games work. |
| Broadcast stops on lock | iOS limitation. Enable "Keep Screen On" in the app. Dim brightness to save battery. |
| Extension crashes | ReplayKit extensions have a ~50 MB memory limit. Avoid buffering. |
| App expires | Free developer accounts have 7-day provisioning. Use a paid account. |
| "Connecting..." stuck | Receiver not running, wrong IP, or firewall blocking. |

## License

MIT
