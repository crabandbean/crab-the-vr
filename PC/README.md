# Crab the VR on the PC

This folder is the other half of the app: the part that makes SteamVR see the
iPhone as a headset and sends the picture to it. There are two ways to use it.

**Option A — SteamVR driver (the real thing).** `driver/` builds a Windows DLL
that SteamVR loads as a headset. SteamVR renders, the driver grabs each frame,
encodes it as H.264 and streams it to the phone, while the phone streams head
poses back.

**Option B — test stream (no build needed).** `tools/test_stream.py` answers the
phone's discovery and sends it a moving test picture. Use this first: if the app
shows the picture and reports your head moving, the phone side is working and any
remaining problem is in the driver.

## The easy way

Double-click **`Setup Crab the VR.cmd`** in this folder.

It checks for the free Visual Studio C++ build tools, Git and CMake, and offers
to install whatever is missing with winget. Then it downloads the OpenVR headers,
builds `driver_joyvr.dll`, and copies the driver and its manifest into your
SteamVR folder. Restart SteamVR afterwards and the headset appears as **Crab the
VR**.

The first run can take a while: the C++ build tools are a large download. Nothing
outside this folder is changed except the installed driver in SteamVR.

If setup stops with compiler errors, the messages above it say what failed — send
them over and the driver can be fixed.

## Building the SteamVR driver by hand

You need Visual Studio 2022 with the "Desktop development with C++" workload,
CMake, and Git.

```bash
cd PC
git clone https://github.com/ValveSoftware/openvr third_party/openvr
cmake -S driver -B build -A x64
cmake --build build --config Release
```

That produces `build\Release\driver_joyvr.dll`. Install it:

```
SteamVR/drivers/joyvr/
    driver.vrdrivermanifest
    bin/win64/driver_joyvr.dll
```

`SteamVR` here is wherever Steam installed it, for example
`C:\Program Files (x86)\Steam\steamapps\common\SteamVR`. Restart SteamVR
afterwards; the headset appears as **Crab the VR**.

Ports 8930 (poses, video) and 8931 (discovery) must be allowed through Windows
Firewall for the driver.

## Running the test stream

Needs Python 3.8+ and, for the moving picture, `ffmpeg` on your PATH.

```bash
python tools/test_stream.py --width 2560 --height 1280 --fps 60
```

It prints each hello it answers, the head poses it receives (yaw, pitch and roll
in degrees) and, when ffmpeg is present, streams a stereo test picture. Press
Ctrl+C to stop.

Without ffmpeg it still answers discovery and hello, so the phone shows
"Connected" and the calibration pattern; that alone proves the link and the
head tracking.

## What is verified and what is not

The phone app builds and runs. The driver in `driver/` is written against the
OpenVR driver API (the interfaces in `openvr_driver.h`, checked against the
current header) but it has never been compiled on a Windows machine from here,
so expect to spend one sitting getting it to build and then to tune it:

- The frame path assumes the compositor hands over a D3D11 shared texture through
  `IVRVirtualDisplay::Present`. That is the interface wireless drivers use, and
  it is implemented here, but the exact texture format must match your GPU.
- The BGRA to NV12 conversion is done on the CPU. It is correct but expensive at
  high resolution; if frame rate suffers, lower the phone's quality setting.
- Controller buttons, sticks and triggers are packed into every pose packet and
  presented to SteamVR as Vive-style tracked controllers, so Steam Input and VR
  games see them without a custom profile. `steam_input/` holds a starting
  binding for Job Simulator-style games; controller roles (left hand, right hand,
  gamepad, ignore) are chosen in the app's Controllers tab.
- Camera hands are sent alongside the controllers: each hand carries a grip and
  an aim pose plus 21 finger joints, and the driver presents it as a tracked
  controller for that hand. Turn it on in Settings; only a box whose camera
  window is clear can see hands.

## Files

- `PROTOCOL.md` — the exact byte layout of everything that crosses the network.
- `driver/driver.cpp` — OpenVR driver: discovery, poses, tracked controllers,
  display geometry, frame hand-off.
- `driver/frame_encoder.cpp` — shared texture to H.264, fragmented into UDP.
- `driver/CMakeLists.txt` — build.
- `steam_input/` — action manifest and binding template for SteamVR/Steam Input.
- `tools/test_stream.py` — the test stream.
