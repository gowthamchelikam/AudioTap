# Debugging the White Noise Issue

This document captures the investigation and fix for a persistent white noise bug where GameCapture streamed audio that played as pure noise on the Mac receiver despite correct bitrates and connection.

## Symptoms

- TCP connection established successfully
- Data flowing at the correct bitrate (~1411 kbps for 44100Hz stereo 16-bit)
- Receiver reported correct format: 44100Hz, 2ch, 16-bit
- Audio played as **white noise** — no recognizable sound
- WAV recordings confirmed noise: autocorrelation near 0, L==R channels always identical

## Investigation Timeline

### Attempt 1: AudioBufferList API
**Hypothesis:** `CMBlockBufferGetDataPointer` returns a flat buffer that doesn't properly separate non-interleaved channels.
**Fix:** Switched to `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` for proper channel handling.
**Result:** Still white noise.

### Attempt 2: Float32 Passthrough
**Hypothesis:** The float-to-int16 conversion was wrong.
**Fix:** Sent raw float32 bytes directly without conversion.
**Result:** Still noise (and format mismatch with receiver expecting int16).

### Attempt 3: TCP Write Loop
**Hypothesis:** `OutputStream.write` was doing partial writes, corrupting frame boundaries.
**Fix:** Added a `writeAll` loop that retries until all bytes are sent.
**Result:** Still white noise.

### Attempt 4: Remove Framing
**Hypothesis:** The 4-byte size prefix framing was misaligning data.
**Fix:** Switched to raw frameless PCM streaming (no size prefix).
**Result:** Still white noise.

### Attempt 5: POSIX Sockets
**Hypothesis:** Foundation's `OutputStream` had buffering or encoding issues.
**Fix:** Replaced with raw POSIX `socket()` / `connect()` / `send()`.
**Result:** Still white noise.

### Attempt 6: On-Device Diagnostic
**Hypothesis:** We don't actually know what format ReplayKit is delivering.
**Fix:** Added diagnostic code to capture the `AudioStreamBasicDescription` format flags and first 64 raw bytes, writing them to shared `UserDefaults` for display in the main app.

**Diagnostic output:**
```
rate=44100 ch=2 bpc=16 flags=0xE float=false ni=false be=true
len=4096 hex=0000000000000000... (all zeros — first frame before game audio starts)
```

This was the breakthrough.

## Root Cause

**`flags=0xE`** (decimal 14, binary `0b1110`):

| Bit | Flag | Value |
|-----|------|-------|
| 0 (`0x1`) | `kAudioFormatFlagIsFloat` | **false** |
| 1 (`0x2`) | `kAudioFormatFlagIsBigEndian` | **true** |
| 2 (`0x4`) | `kAudioFormatFlagIsSignedInteger` | **true** |
| 3 (`0x8`) | `kAudioFormatFlagIsPacked` | **true** |
| 5 (`0x20`) | `kAudioFormatFlagIsNonInterleaved` | **false** |

ReplayKit on this device (iPhone Air, iOS 18) delivers audio as **big-endian signed 16-bit integer, packed, interleaved**.

The code correctly identified `isFloat=false` and `isNonInterleaved=false`, so it took the passthrough path — copying raw bytes directly to TCP. But those bytes were **big-endian** int16, while the receiver and WAV format expect **little-endian** int16.

### Why It Sounds Like White Noise

When you byte-swap a 16-bit audio sample:
- A quiet sample like `0x0012` (18) becomes `0x1200` (4608) — massive amplification
- A loud sample like `0x7F00` (32512) becomes `0x007F` (127) — massive attenuation
- The relationship between consecutive samples is destroyed
- The result has the statistical properties of random noise

This explains why:
- Autocorrelation was near 0 (byte-swapped audio has no temporal correlation)
- L==R (both channels byte-swapped the same way)
- Bitrate was correct (same number of bytes, just swapped)
- Max amplitude was near 32768 (full range, as expected from scrambled samples)

## The Fix

Added a big-endian detection flag and byte-swap before sending:

```swift
let isBigEndian = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
```

In the int16 interleaved passthrough path:
```swift
if isBigEndian {
    return swapInt16Endianness(data, byteCount: byteCount)
}
return Data(bytes: data, count: byteCount)
```

The swap function uses Swift's built-in `Int16.byteSwapped`:
```swift
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
```

## Key Lessons

1. **Never assume endianness.** ReplayKit's audio format varies by device. Always check `kAudioFormatFlagIsBigEndian`.

2. **Add on-device diagnostics early.** The format flags were only discoverable by reading the `AudioStreamBasicDescription` at runtime on the actual device. No amount of code review or documentation reading would have revealed that this particular device outputs big-endian audio.

3. **Byte-swapped audio looks like valid data.** The bitrate, frame sizes, and data flow were all correct. Only the content was wrong. Standard debugging (connection checks, bitrate monitoring) couldn't catch this.

4. **Check format flags as a bitmask, not just named booleans.** The code checked `isFloat` and `isNonInterleaved` but missed `isBigEndian` — a flag that's rarely set but critical when it is.

5. **First audio frame may be silence.** The diagnostic captured all zeros because it ran on the very first `processSampleBuffer` call, before the user switched to the game. Don't rely on first-frame data for content verification.
