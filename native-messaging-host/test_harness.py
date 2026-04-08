#!/usr/bin/env python3
"""
Test harness for the HDR Upscaler native messaging host.

Simulates the Firefox extension by sending length-prefixed JSON messages
to the Swift app's stdin and reading responses from stdout.

Usage:
  1. Build the Swift app:  cd native-app && swift build
  2. Run this script:      python3 native-messaging-host/test_harness.py

The script pipes messages to the native host binary and prints responses.
Press Ctrl+C to stop.
"""

import json
import struct
import subprocess
import sys
import time
import threading
import os

BINARY = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "native-app", ".build", "debug", "HDRUpscaler"
)

def encode_message(msg: dict) -> bytes:
    """Encode a message using the native messaging protocol (4-byte length prefix + JSON)."""
    payload = json.dumps(msg).encode("utf-8")
    return struct.pack("<I", len(payload)) + payload

def decode_message(pipe) -> dict | None:
    """Read one length-prefixed JSON message from a pipe."""
    raw_length = pipe.read(4)
    if len(raw_length) < 4:
        return None
    length = struct.unpack("<I", raw_length)[0]
    payload = pipe.read(length)
    if len(payload) < length:
        return None
    return json.loads(payload)

def read_responses(pipe):
    """Background thread: read and print responses from the native host."""
    while True:
        msg = decode_message(pipe)
        if msg is None:
            print("[harness] Native host stdout closed")
            break
        print(f"[harness] ← Response: {json.dumps(msg, indent=2)}")

def main():
    if not os.path.exists(BINARY):
        print(f"Error: Binary not found at {BINARY}")
        print("Build first:  cd native-app && swift build")
        sys.exit(1)

    print(f"[harness] Starting native host: {BINARY}")
    print("[harness] Press Enter to send a video_rect message, 'q' to quit, 'l' to send video_lost")
    print()

    proc = subprocess.Popen(
        [BINARY],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,  # Pass stderr through so we see logs
    )

    # Read responses in background
    reader = threading.Thread(target=read_responses, args=(proc.stdout,), daemon=True)
    reader.start()

    # Give the app a moment to start
    time.sleep(1)

    # Example video rect (simulating a 1280x720 video on YouTube)
    video_rect_msg = {
        "type": "video_rect",
        "rect": {"x": 0, "y": 56, "width": 1280, "height": 720},
        "viewport": {"width": 1440, "height": 900},
        "devicePixelRatio": 2.0,
        "isFullscreen": False,
        "paused": False,
        "videoNaturalWidth": 1920,
        "videoNaturalHeight": 1080,
        "url": "https://www.youtube.com/watch?v=test",
        "tabId": 1,
        "windowId": 1
    }

    video_lost_msg = {
        "type": "video_lost"
    }

    try:
        while True:
            cmd = input("[harness] > ").strip().lower()
            if cmd == "q":
                break
            elif cmd == "l":
                print("[harness] → Sending video_lost")
                proc.stdin.write(encode_message(video_lost_msg))
                proc.stdin.flush()
            else:
                # Slightly randomize rect to simulate scrolling
                msg = video_rect_msg.copy()
                msg["rect"] = dict(video_rect_msg["rect"])
                print(f"[harness] → Sending video_rect: {msg['rect']}")
                proc.stdin.write(encode_message(msg))
                proc.stdin.flush()
    except (KeyboardInterrupt, EOFError):
        pass

    print("\n[harness] Closing stdin...")
    proc.stdin.close()
    proc.wait(timeout=5)
    print(f"[harness] Native host exited with code {proc.returncode}")

if __name__ == "__main__":
    main()
