#!/usr/bin/env python3
"""AudioTap Mac Receiver — receives PCM audio from iPhone over TCP."""

import argparse
import socket
import struct
import sys
import time
import wave

MAGIC = 0x41554450  # "AUDP"
MAX_FRAME_SIZE = 1_048_576  # 1 MB sanity limit


def recv_exact(conn, size):
    """Receive exactly size bytes, handling partial TCP reads."""
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def list_devices():
    """List available audio output devices."""
    try:
        import pyaudio
    except ImportError:
        print("pyaudio not installed. Run: brew install portaudio && pip3 install pyaudio")
        sys.exit(1)

    pa = pyaudio.PyAudio()
    print("Audio output devices:")
    for i in range(pa.get_device_count()):
        info = pa.get_device_info_by_index(i)
        if info["maxOutputChannels"] > 0:
            print(f"  [{i}] {info['name']} ({info['maxOutputChannels']}ch)")
    pa.terminate()


def handle_connection(conn, pa, args):
    """Handle a single TCP connection from AudioTap iOS app."""
    pa_stream = None
    wav_file = None

    try:
        # Read 12-byte header
        header = recv_exact(conn, 12)
        if not header:
            print("Connection closed before header received.")
            return

        magic, sample_rate, channels, bits_per_sample = struct.unpack("<IIHH", header)

        if magic != MAGIC:
            print(f"Bad magic: 0x{magic:08X} (expected 0x{MAGIC:08X})")
            return

        sample_width = bits_per_sample // 8
        print(f"Audio: {sample_rate}Hz, {channels}ch, {bits_per_sample}-bit")

        # Open PyAudio output stream
        if pa and not args.no_play:
            import pyaudio

            fmt = {1: pyaudio.paInt8, 2: pyaudio.paInt16, 4: pyaudio.paInt32}.get(
                sample_width, pyaudio.paInt16
            )
            kwargs = dict(
                format=fmt,
                channels=channels,
                rate=sample_rate,
                output=True,
                frames_per_buffer=1024,
            )
            if args.device is not None:
                kwargs["output_device_index"] = args.device
            pa_stream = pa.open(**kwargs)

        # Open WAV file for recording
        if args.output:
            wav_file = wave.open(args.output, "wb")
            wav_file.setnchannels(channels)
            wav_file.setsampwidth(sample_width)
            wav_file.setframerate(sample_rate)

        # Receive loop
        total_bytes = 0
        start_time = time.time()
        last_stats = start_time

        while True:
            size_data = recv_exact(conn, 4)
            if not size_data:
                break

            frame_size = struct.unpack("<I", size_data)[0]
            if frame_size == 0 or frame_size > MAX_FRAME_SIZE:
                continue

            pcm_data = recv_exact(conn, frame_size)
            if not pcm_data:
                break

            if pa_stream:
                pa_stream.write(pcm_data)
            if wav_file:
                wav_file.writeframes(pcm_data)

            total_bytes += frame_size

            now = time.time()
            if now - last_stats >= 5.0:
                elapsed = now - start_time
                mb = total_bytes / (1024 * 1024)
                bitrate = (total_bytes * 8) / elapsed / 1000
                print(f"  {elapsed:.0f}s | {mb:.1f} MB | {bitrate:.0f} kbps")
                last_stats = now

    except (ConnectionResetError, BrokenPipeError):
        print("Connection lost.")
    finally:
        if pa_stream:
            pa_stream.stop_stream()
            pa_stream.close()
        if wav_file:
            wav_file.close()
            print(f"Saved recording: {args.output}")


def main():
    parser = argparse.ArgumentParser(description="AudioTap Mac Receiver")
    parser.add_argument("-p", "--port", type=int, default=7654,
                        help="Listen port (default: 7654)")
    parser.add_argument("-o", "--output", help="Save to WAV file")
    parser.add_argument("--no-play", action="store_true",
                        help="Don't play audio (save only)")
    parser.add_argument("--list-devices", action="store_true",
                        help="List audio output devices")
    parser.add_argument("-d", "--device", type=int,
                        help="Output device ID")
    args = parser.parse_args()

    if args.list_devices:
        list_devices()
        return

    # Try to import pyaudio for playback
    pa = None
    if not args.no_play:
        try:
            import pyaudio
            pa = pyaudio.PyAudio()
        except ImportError:
            if not args.output:
                print("Error: pyaudio not installed and no output file specified.")
                print("  Install: brew install portaudio && pip3 install pyaudio")
                print("  Or use:  --no-play -o recording.wav")
                sys.exit(1)
            print("Warning: pyaudio not available -- saving to file only.")
            args.no_play = True

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", args.port))
    sock.listen(1)
    print(f"Listening on port {args.port}... Waiting for iPhone to connect...")

    try:
        while True:
            conn, addr = sock.accept()
            print(f"\nConnected: {addr[0]}:{addr[1]}")
            handle_connection(conn, pa, args)
            print("Disconnected. Waiting for next connection...")
    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        if pa:
            pa.terminate()
        sock.close()


if __name__ == "__main__":
    main()
