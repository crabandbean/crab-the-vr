#!/usr/bin/env python3
"""Crab the VR test stream.

Answers the phone's discovery broadcasts and hello packets, prints the head
poses it receives, and — if ffmpeg is installed — streams a moving stereo test
picture in the format the app decodes.

    python tools/test_stream.py
    python tools/test_stream.py --width 2560 --height 1280 --fps 60 --no-video
"""

import argparse
import os
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time

MAGIC_POSE = b"JVR1"
MAGIC_VIDEO = b"JVV1"
MAGIC_REPLY = b"JVRP"
MAGIC_DISCOVER = b"JVRQ"
MAGIC_DISCOVER_REPLY = b"JVRE"

PROTOCOL_VERSION = 1
STREAM_PORT = 8930
DISCOVERY_PORT = 8931
PACKET_POSE = 1
PACKET_HELLO = 2
PACKET_BYE = 3
PACKET_PING = 4
PACKET_BITRATE = 5
PACKET_PROFILE = 6
REPLY_ACK = 1
REPLY_PONG = 3

HEADER_SIZE = 32
POSE_SIZE = 72
CONTROLLER_RECORD_SIZE = 20
HAND_RECORD_SIZE = 192
VIDEO_HEADER_SIZE = 24

CONTROLLER_ROLES = {0: "Left hand", 1: "Right hand", 2: "Gamepad"}


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.target = None          # (ip, port)
        self.frames = 0
        self.last_pose = None
        self.controllers = ""
        self.stream = (2560, 1280, 60, 60000)


STATE = State()


def local_name():
    try:
        return socket.gethostname()[:60] or "Crab the VR PC"
    except OSError:
        return "Crab the VR PC"


def yaw_pitch_roll(q):
    """Quaternion (x, y, z, w) to degrees, for the console output."""
    x, y, z, w = q
    # Forward vector is -Z in the OpenVR convention.
    fx = -2.0 * (x * z + w * y)
    fy = -2.0 * (y * z - w * x)
    fz = -(1.0 - 2.0 * (x * x + y * y))
    yaw = __import__("math").degrees(__import__("math").atan2(fx, -fz))
    pitch = __import__("math").degrees(__import__("math").asin(max(-1.0, min(1.0, fy))))
    roll = __import__("math").degrees(__import__("math").atan2(2.0 * (w * z + x * y),
                                                               1.0 - 2.0 * (y * y + z * z)))
    return yaw, pitch, roll


def controller_summary(data):
    """One line describing the controller and hand records that follow the pose."""
    count = min(data[21], 4)
    hand_count = min(data[22], 2)
    if count == 0 and hand_count == 0:
        return ""

    parts = []
    if len(data) >= POSE_SIZE + count * CONTROLLER_RECORD_SIZE:
        for index in range(count):
            offset = POSE_SIZE + index * CONTROLLER_RECORD_SIZE
            slot = data[offset]
            role = data[offset + 1]
            buttons = struct.unpack_from("<H", data, offset + 2)[0]
            pressed = sum(1 for bit in range(16) if buttons & (1 << bit))
            parts.append(f"{CONTROLLER_ROLES.get(role, '?')} #{slot} {pressed} btn")

    base = POSE_SIZE + data[21] * CONTROLLER_RECORD_SIZE
    if hand_count and len(data) >= base + hand_count * HAND_RECORD_SIZE:
        for index in range(hand_count):
            record = base + index * HAND_RECORD_SIZE
            hand = "Left hand" if data[record] == 0 else "Right hand"
            tracked = (data[record + 1] & 1) != 0
            pinch = struct.unpack_from("<H", data, record + 4)[0] / 65535.0
            parts.append(f"{hand}{'' if tracked else ' (lost)'} pinch {pinch:.0%}")

    return ", ".join(parts)


def handle_pose(data, address):
    if len(data) < POSE_SIZE:
        return
    q = struct.unpack_from("<4f", data, 32)
    with STATE.lock:
        STATE.target = address
        STATE.last_pose = (q, time.time())
        STATE.controllers = controller_summary(data)


def handle_hello(data, address):
    if len(data) < 41:
        return
    width, height, fps, bitrate = struct.unpack_from("<4H", data, 32)
    with STATE.lock:
        STATE.target = address
        STATE.stream = (width, height, fps, bitrate)
    print(f"hello from {address[0]}:{address[1]} → {width}×{height} @ {fps} Hz, {bitrate} kbps")
    return width, height, fps, bitrate


def reply(sock, address, packet):
    try:
        sock.sendto(packet, address)
    except OSError as error:
        print(f"reply failed: {error}")


def ack_packet():
    name = local_name().encode("utf-8")[:200]
    return (MAGIC_REPLY
            + struct.pack("<HHQ", PROTOCOL_VERSION, REPLY_ACK, int(time.time() * 1_000_000))
            + bytes([len(name)]) + name
            + struct.pack("<HH", 0, 0))


def pong_packet(client_time_us):
    return (MAGIC_REPLY
            + struct.pack("<HHQ", PROTOCOL_VERSION, REPLY_PONG, client_time_us)
            + bytes([0])
            + struct.pack("<HH", 0, 0))


def discovery_packet():
    name = local_name().encode("utf-8")[:120]
    return (b"JVRE"
            + struct.pack("<HH", 1, STREAM_PORT)
            + bytes([1])
            + bytes([len(name)]) + name)


def serve(stream_sock, discovery_sock, stop):
    while not stop.is_set():
        for sock in (stream_port_socket(stream_sock),):
            pass
        ready, _, _ = select.select([stream_sock, discovery_sock], [], [], 0.2)
        for sock in ready:
            try:
                data, address = sock.recvfrom(2048)
            except OSError:
                continue

            if sock is discovery_sock:
                if data.startswith(MAGIC_DISCOVER):
                    reply(discovery_sock, address, discovery_packet())
                continue

            if len(data) < HEADER_SIZE or not data.startswith(MAGIC_POSE):
                continue
            packet_type = struct.unpack_from("<H", data, 6)[0]
            if packet_type == PACKET_POSE:
                handle_pose(data, address)
            elif packet_type == PACKET_HELLO:
                handle_hello(data, address)
                reply(stream_sock, address, ack_packet())
            elif packet_type == PACKET_PING:
                if len(data) >= 40:
                    client_time = struct.unpack_from("<Q", data, 32)[0]
                    reply(stream_sock, address, pong_packet(client_time))
            elif packet_type == PACKET_BITRATE:
                if len(data) >= 34:
                    kbps = struct.unpack_from("<H", data, 32)[0]
                    print(f"bitrate → {kbps} kbps")
            elif packet_type == PACKET_PROFILE:
                if len(data) >= 64:
                    width, height = struct.unpack_from("<2H", data, 32)
                    k1, k2, ipd, supersampling = struct.unpack_from("<4f", data, 36)
                    refresh = struct.unpack_from("<H", data, 52)[0]
                    fov_crop, vignette = struct.unpack_from("<2f", data, 56)
                    print(f"profile → {width}×{height}, IPD {ipd * 1000:.0f} mm, "
                          f"{refresh} Hz, k1 {k1:.2f}, SS {supersampling:.2f}, "
                          f"crop {fov_crop:.2f}, vignette {vignette:.2f}")


def stream_port_socket(sock):
    return sock


def report_poses(stop):
    last = 0.0
    while not stop.is_set():
        time.sleep(1.0)
        with STATE.lock:
            pose = STATE.last_pose
            target = STATE.target
            controllers = STATE.controllers
        if pose is None or target is None:
            if last == 0.0:
                print("waiting for the phone…")
                last = 1.0
            continue
        if time.time() - pose[1] > 2.0:
            continue
        yaw, pitch, roll = yaw_pitch_roll(pose[0])
        print(f"pose  yaw {yaw:7.1f}°  pitch {pitch:6.1f}°  roll {roll:6.1f}°   "
              f"({target[0]}:{target[1]})")
        if controllers:
            print(f"pads  {controllers}")


def video_sender(video_sock, width, height, fps, bitrate_kbps, stop):
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        print("ffmpeg not found — link only, no picture")
        return

    gop = max(1, fps)
    command = [
        ffmpeg, "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", f"testsrc2=size={width}x{height}:rate={fps}",
        "-vf", f"drawbox=x={width // 2}:y=0:w=2:h={height}:color=white@0.9:t=fill",
        "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-b:v", f"{bitrate_kbps}k", "-g", str(gop),
        "-x264-params", f"aud=1:keyint={gop}:scenecut=0",
        "-f", "h264", "pipe:1",
    ]

    print("starting ffmpeg test pattern")
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, bufsize=0)
    except OSError as error:
        print(f"could not start ffmpeg: {error}")
        return

    frame_id = 0
    buffer = b""
    print("streaming — put the phone in the box")

    try:
        while not stop.is_set():
            chunk = process.stdout.read(65536)
            if not chunk:
                break
            buffer += chunk
            # Access unit delimiters (NAL type 9) split frames because x264 was
            # asked to write aud=1.
            units = split_access_units(buffer)
            if units:
                buffer = units.pop()
                for unit in units:
                    with STATE.lock:
                        target = STATE.target
                    if target is None:
                        continue
                    frame_id += 1
                    send_frame(video_sock, target, frame_id, unit)
    finally:
        process.kill()


def split_access_units(data):
    """Returns complete access units plus the unterminated remainder."""
    starts = []
    index = 0
    while index + 3 < len(data):
        if data[index] == 0 and data[index + 1] == 0 and data[index + 2] == 1:
            starts.append(index)
            index += 3
        else:
            index += 1
    if not starts:
        return []

    units = []
    begin = None
    for position in starts:
        nal_type = data[position + 3] & 0x1F if position + 3 < len(data) else 0
        if nal_type == 9:  # access unit delimiter starts a new picture
            if begin is not None:
                units.append(data[begin:position])
            begin = position
    if begin is not None:
        units.append(data[begin:])
    else:
        units = []
    remainder = units.pop() if units else data
    return units + [remainder]


def send_frame(sock, target, frame_id, payload):
    total = len(payload)
    fragment_count = max(1, (total + 1199) // 1200)
    keyframe = 1 if b"\x00\x00\x01\x65" in payload or b"\x00\x00\x01\x25" in payload else 0

    for index in range(fragment_count):
        offset = index * 1200
        piece = payload[offset:offset + 1200]
        header = (MAGIC_VIDEO
                  + struct.pack("<HHQHHI", PROTOCOL_VERSION, keyframe, frame_id,
                                index, fragment_count, total))
        try:
            sock.sendto(header + piece, target)
        except OSError:
            return


def main():
    parser = argparse.ArgumentParser(description="Crab the VR test stream")
    parser.add_argument("--width", type=int, default=2560)
    parser.add_argument("--height", type=int, default=1280)
    parser.add_argument("--fps", type=int, default=60)
    parser.add_argument("--bitrate", type=int, default=60000, help="kilobits per second")
    parser.add_argument("--no-video", action="store_true")
    arguments = parser.parse_args()

    stream_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    stream_sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    stream_sock.bind(("0.0.0.0", STREAM_PORT))

    discovery_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    discovery_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    discovery_sock.bind(("0.0.0.0", DISCOVERY_PORT))

    video_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    video_sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
    video_sock.bind(("0.0.0.0", 0))

    print(f"Crab the VR test server '{local_name()}'")
    print(f"discovery on {DISCOVERY_PORT}, poses on {STREAM_PORT}")
    print("open the app, tap Find my PC, then Connect")

    stop = threading.Event()
    threads = [
        threading.Thread(target=serve, args=(stream_sock, discovery_sock, stop), daemon=True),
        threading.Thread(target=report_poses, args=(stop,), daemon=True),
    ]
    if not arguments.no_video:
        threads.append(threading.Thread(
            target=video_sender,
            args=(video_sock, arguments.width, arguments.height, arguments.fps,
                  arguments.bitrate, stop),
            daemon=True))

    for thread in threads:
        thread.start()

    try:
        while True:
            time.sleep(0.5)
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        stop.set()
        stream_sock.close()
        discovery_sock.close()
        video_sock.close()


if __name__ == "__main__":
    main()
