# AudioTap

Capture iPhone app/game audio via ReplayKit and stream it over TCP to a Mac receiver. Designed for USB Internet Sharing setups where USB audio (IDAM) can't coexist with USB networking.

**How it works:** A Broadcast Upload Extension on the iPhone captures internal app audio, converts it to 16-bit PCM, and streams it over TCP to a Python receiver on the Mac. The USB cable stays in networking mode, so internet + audio + charging all work on one cable.

## Prerequisites

- Mac with macOS 13+ and Xcode 15+
- iPhone with iOS 16+
- Paid Apple Developer account
- USB cable (Lightning or USB-C)
- Mac connected to internet via Ethernet
- Python 3.10+ on Mac

## Build & Install iOS App

1. Open `AudioTap.xcodeproj` in Xcode
2. Select your Development Team in **both** targets (AudioTapApp + AudioTapBroadcast)
3. Update bundle IDs if needed (must be unique to your dev account)
4. Enable **App Groups** capability on both targets, group: `group.audiotap.shared`
5. Connect iPhone via USB, select it as build destination
6. Build & Run (`Cmd+R`)
7. Trust the developer profile on iPhone: **Settings > General > VPN & Device Management**

## Set Up Mac Receiver

```bash
# Install PortAudio (required by PyAudio)
brew install portaudio

# Install PyAudio
pip3 install pyaudio

# Run the receiver
python3 mac-receiver/audio_receiver.py
```

### Receiver options

```
python3 audio_receiver.py                        # Play through speakers
python3 audio_receiver.py -o recording.wav       # Play + save to WAV
python3 audio_receiver.py --no-play -o out.wav   # Save only (no pyaudio needed)
python3 audio_receiver.py --list-devices          # List audio output devices
python3 audio_receiver.py -d 2                   # Use specific output device
python3 audio_receiver.py -p 8000                # Custom port
```

## Set Up USB Internet Sharing

1. Connect iPhone to Mac via USB
2. **System Settings > General > Sharing > Internet Sharing**
3. Share: **Ethernet** to: **iPhone USB** > toggle ON
4. On iPhone, disable Wi-Fi and Cellular to force USB network

### Verify the USB network IP

The Mac's IP on the USB subnet is typically `172.20.10.1`:

```bash
ifconfig | grep -A5 "bridge"
# Look for inet address on bridge100
```

## Usage

1. Start the receiver on Mac: `python3 mac-receiver/audio_receiver.py`
2. Open **AudioTap** on iPhone
3. Verify IP is `172.20.10.1` and port is `7654`, tap **Save Settings**
4. Tap the broadcast button and confirm the system prompt
5. Switch to your game or app
6. Audio streams to Mac in real-time

## Wire Protocol

Binary, little-endian, over TCP.

**Header** (12 bytes, sent once):
| Offset | Size | Type   | Description                    |
|--------|------|--------|--------------------------------|
| 0      | 4    | UInt32 | Magic: `0x41554450` ("AUDP")   |
| 4      | 4    | UInt32 | Sample rate (e.g. 48000)       |
| 8      | 2    | UInt16 | Channels (1 or 2)              |
| 10     | 2    | UInt16 | Bits per sample (16)           |

**Data frames** (continuous):
| Offset | Size | Type   | Description                    |
|--------|------|--------|--------------------------------|
| 0      | 4    | UInt32 | Frame size in bytes            |
| 4      | N    | bytes  | Raw interleaved PCM samples    |

48kHz stereo 16-bit = ~192 KB/s = 1.5 Mbps. Trivial for USB networking.

## Troubleshooting

- **No connection**: Check Mac firewall allows port 7654. Test with `nc -l 7654`.
- **No audio**: Some apps (AVPlayer, Safari, Music) are blocked by Apple. Most games work.
- **Extension crashes**: Memory limit (~50 MB). Ensure no buffering in SampleHandler.
- **App expires after 7 days**: Only with free dev accounts. Paid accounts don't expire.

## Project Structure

```
AudioTap/
├── AudioTap.xcodeproj/
├── AudioTapApp/                    # Main app target
│   ├── AudioTapApp.swift           # @main SwiftUI entry point
│   ├── ContentView.swift           # Settings UI + broadcast picker
│   ├── AudioTapApp.entitlements    # App Groups
│   └── Info.plist
├── AudioTapBroadcast/              # Broadcast Upload Extension
│   ├── SampleHandler.swift         # Audio capture + TCP streaming
│   ├── AudioTapBroadcast.entitlements
│   └── Info.plist
├── Shared/                         # Both targets
│   └── AudioStreamProtocol.swift   # Wire protocol definitions
├── mac-receiver/
│   └── audio_receiver.py           # Python TCP receiver
└── README.md
```
