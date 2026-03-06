# AudioTap

Capture iPhone app/game audio via ReplayKit and stream it in real-time over TCP to a Mac. Built for mobile esports setups where USB Internet Sharing is used and USB audio (IDAM) is unavailable.

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   iPhone                         │
│                                                  │
│  ┌──────────────┐     ┌───────────────────────┐ │
│  │  AudioTap    │     │  Broadcast Extension  │ │
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
│  │  audio_receiver.py                          │  │
│  │                                             │  │
│  │  • TCP server on port 7654                  │  │
│  │  • Reads AUDP header (format negotiation)   │  │
│  │  • Receives size-prefixed PCM frames        │  │
│  │  • PyAudio real-time playback               │  │
│  │  • Optional WAV file recording              │  │
│  └────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

### How It Works

1. The **main app** (AudioTapApp) provides a UI to configure the Mac's IP address and port, and hosts a `RPSystemBroadcastPickerView` to start screen broadcasting.

2. When the user starts a broadcast, iOS launches the **Broadcast Upload Extension** (AudioTapBroadcast) as a separate process. The extension receives `processSampleBuffer` callbacks with `.audioApp` sample buffers containing the audio from whatever app is in the foreground.

3. The **SampleHandler** in the extension:
   - Opens a TCP connection to the Mac receiver
   - Reads the audio format from the `CMSampleBuffer`'s `AudioStreamBasicDescription`
   - Sends a 12-byte AUDP header with sample rate, channels, and bit depth
   - Extracts audio via the `AudioBufferList` API
   - Converts to interleaved little-endian signed 16-bit PCM (handling big-endian, float32, and non-interleaved formats from ReplayKit)
   - Sends size-prefixed PCM frames over TCP

4. The **Python receiver** on the Mac:
   - Listens for TCP connections on port 7654
   - Reads the 12-byte AUDP header to configure playback
   - Receives and plays PCM audio in real-time via PyAudio
   - Optionally saves to a WAV file

### Audio Format Handling

ReplayKit delivers audio in various formats depending on the device. Common formats observed:

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
- Python 3.10+ on Mac
- [PortAudio](http://www.portaudio.com/) + [PyAudio](https://pypi.org/project/PyAudio/) for real-time playback

## Quick Start

### 1. Build & Install the iOS App

```bash
# Generate the Xcode project
cd AudioTap
xcodegen generate

# Build for device (replace DEVELOPMENT_TEAM with your team ID)
xcodebuild -project AudioTap.xcodeproj \
  -scheme AudioTapApp \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  build

# Install on connected iPhone
xcrun devicectl device install app \
  --device <DEVICE_ID> \
  ~/Library/Developer/Xcode/DerivedData/AudioTap-*/Build/Products/Debug-iphoneos/AudioTapApp.app
```

Or open `AudioTap.xcodeproj` in Xcode, select your team in both targets, and hit `Cmd+R`.

**First-time setup on iPhone:**
- Trust the developer profile: **Settings → General → VPN & Device Management**
- Enable Developer Mode: **Settings → Privacy & Security → Developer Mode**

### 2. Set Up USB Internet Sharing

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

### 3. Start the Mac Receiver

```bash
# Install dependencies (one-time)
brew install portaudio
pip3 install pyaudio

# Run the receiver
python3 mac-receiver/audio_receiver.py
```

### 4. Stream Audio

1. Open **AudioTap** on iPhone
2. Set the Mac IP (e.g. `192.168.2.1`) and port (`7654`), tap **Save Settings**
3. Tap the red **Start Broadcast** button and confirm
4. Switch to your game or app — audio streams to Mac in real-time

## Receiver Options

```
python3 audio_receiver.py                        # Play through default speakers
python3 audio_receiver.py -o recording.wav       # Play + save to WAV
python3 audio_receiver.py --no-play -o out.wav   # Save only (no PyAudio needed)
python3 audio_receiver.py --list-devices          # List audio output devices
python3 audio_receiver.py -d 2                   # Use specific output device
python3 audio_receiver.py -p 8000                # Custom port
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
AudioTap/
├── project.yml                     # XcodeGen project spec
├── AudioTapApp/                    # Main iOS app target
│   ├── AudioTapApp.swift           # @main SwiftUI entry point
│   ├── ContentView.swift           # Settings UI + broadcast picker
│   ├── AudioTapApp.entitlements    # App Groups entitlement
│   └── Info.plist
├── AudioTapBroadcast/              # Broadcast Upload Extension
│   ├── SampleHandler.swift         # Audio capture, conversion, TCP streaming
│   ├── AudioTapBroadcast.entitlements
│   └── Info.plist
├── Shared/                         # Code shared by both targets
│   └── AudioStreamProtocol.swift   # AUDP header + frame wire format
├── mac-receiver/
│   └── audio_receiver.py           # Python TCP receiver + player
└── README.md
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| No connection | Check Mac firewall allows port 7654. Test: `nc -l 7654` |
| Port in use | `kill $(lsof -ti :7654)` |
| White noise | Endianness mismatch — see [White Noise Debugging](docs/white-noise-debugging.md). The SampleHandler handles big-endian → little-endian conversion. If you modify the code, ensure byte-swap is preserved. |
| No audio data | Some apps block audio capture (AVPlayer, Safari, Music). Most games work. |
| Extension crashes | ReplayKit extensions have a ~50 MB memory limit. Avoid buffering. |
| App expires | Free developer accounts have 7-day provisioning. Use a paid account. |
| "Connecting..." stuck | Receiver not running, wrong IP, or firewall blocking. |
| PyAudio not found | `brew install portaudio && pip3 install pyaudio` |

## License

MIT
