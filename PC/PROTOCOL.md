# Crab the VR wire protocol, version 1

Everything is UDP and little endian. Four byte ASCII markers begin every packet.
The phone always initiates: the PC answers whatever address and port the phone's
packets come from, so the phone can find the PC without any configuration.

Ports

- `8931` discovery, broadcast by the phone
- `8930` poses, hello and bye from the phone; replies from the PC
- Video leaves the PC from `8930` towards the source port of the phone's last packet, so no second socket is needed.

## Phone to PC

Every packet starts with a fixed 32 byte header.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `"JVR1"` |
| 4 | 2 | protocol version (1) |
| 6 | 2 | packet type: 1 pose, 2 hello, 3 bye, 4 ping, 5 bitrate, 6 profile |
| 8 | 8 | client time, microseconds, monotonic |
| 16 | 4 | sequence number |
| 20 | 1 | flags, bit 0 = 6DOF position is valid |
| 21 | 1 | controller count |
| 22 | 1 | hand count |
| 23 | 1 | reserved |
| 24 | 4 | IPD in metres (float32) |
| 28 | 2 | phone screen width in pixels |
| 30 | 2 | phone screen height in pixels |

Type 1, pose, appends 40 bytes:

| Offset | Size | Field |
| --- | --- | --- |
| 32 | 16 | head orientation quaternion, x y z w (float32 each) |
| 48 | 12 | head position in metres, x y z |
| 60 | 12 | angular velocity in radians per second, x y z |

The quaternion is in OpenVR's convention: right handed, +Y up, the head looks
down -Z. At the moment the user taps Recenter the yaw is zero.

### Controller records

When the header's controller count is above zero, that many records follow the
40 byte pose, 20 bytes each. A phone with no controllers paired sends count 0
and appends nothing, so the packet stays 72 bytes.

| Offset in record | Size | Field |
| --- | --- | --- |
| 0 | 1 | slot, 0..3, stable while the controller stays connected |
| 1 | 1 | role: 0 left hand, 1 right hand, 2 gamepad |
| 2 | 2 | buttons, bit field below |
| 4 | 2 | left stick x, int16, -32767..32767 |
| 6 | 2 | left stick y, int16, up positive |
| 8 | 2 | right stick x, int16 |
| 10 | 2 | right stick y, int16, up positive |
| 12 | 1 | left trigger, 0..255 |
| 13 | 1 | right trigger, 0..255 |
| 14 | 1 | battery, 0..100, 255 unknown |
| 15 | 1 | flags, reserved, 0 |
| 16 | 4 | reserved, 0 |

Buttons, bit 0 first: A, B, X, Y, L, R, ZL, ZR, Plus, Minus, Home, Capture,
D-pad up, D-pad down, D-pad left, D-pad right.

Controllers whose role is Ignore are left out of the packet entirely. The PC
companion only needs the record count and role to create the right hand; the
button and stick values go straight into a virtual tracked controller so Steam
Input and VR games see them as normal buttons and axes.

Controller slots are 0 to 3. Hand records use slots 4 (left) and 5 (right).

### Hand records

When the header's hand count is above zero, that many hand records follow the
controller records, 192 bytes each. Hands and controllers are sent together, so
a Joy-Con and a hand can both be in the same packet.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | hand: 0 left, 1 right |
| 1 | 1 | flags: bit 0 tracked, bit 1 depth came from the depth sensor |
| 2 | 1 | confidence, 0..255 |
| 3 | 1 | reserved |
| 4 | 2 | pinch, 0..65535 (thumb tip to index tip) |
| 6 | 2 | reserved |
| 8 | 12 | grip position, x y z float32, metres in the head's frame |
| 20 | 16 | grip orientation, x y z w float32 |
| 36 | 12 | aim position, x y z float32, metres in the head's frame |
| 48 | 16 | aim orientation, x y z w float32 |
| 64 | 126 | 21 joints, int16 millimetres, x y z each, in the head's frame |
| 190 | 2 | reserved |

The joints are, in order: wrist, thumb CMC/MP/IP/tip, then the index, middle,
ring and little finger with MCP, PIP, DIP and tip each. Positions are in the
head's own frame (right handed, +Y up, looking down -Z), so the PC rotates them
by the HMD pose to place them in the world. The PC companion computes pinch
from the thumb and index tips as well, which is what drives grab and trigger.

Type 2, hello, appends:

| Offset | Size | Field |
| --- | --- | --- |
| 32 | 2 | requested total stream width |
| 34 | 2 | requested stream height |
| 36 | 2 | requested frames per second |
| 38 | 2 | requested bitrate, kilobits per second |
| 40 | 1 | name length |
| 41 | n | device name, UTF-8 |

Type 3, bye, is just the header.

Type 4, ping, appends an 8 byte client timestamp in microseconds. The PC answers
with a pong that echoes it, which is how the phone measures round trip.

Type 5, bitrate, appends the new encoder bitrate in kilobits per second (u16)
and 2 reserved bytes. There is no acknowledgement; the encoder restarts at the
new rate. The phone sends this when its adaptive bitrate steps down or back up.

Type 6, profile, appends 32 bytes: the lens and comfort profile the PC should
render with.

| Offset | Size | Field |
| --- | --- | --- |
| 32 | 2 | total stream width in pixels |
| 34 | 2 | stream height in pixels |
| 36 | 4 | distortion k1 (float32) |
| 40 | 4 | distortion k2 (float32) |
| 44 | 4 | IPD in metres |
| 48 | 4 | supersampling scale (0.5..2.0) |
| 52 | 2 | refresh rate in Hz (60, 90 or 120) |
| 54 | 2 | reserved |
| 56 | 4 | FOV crop, 0..0.6 |
| 60 | 4 | vignette, 0..1 |

It is sent when a profile is applied and once after the hello is acknowledged,
so the PC always renders with the same projection and eye offset the phone
expects.

## PC to phone

### Reply

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `"JVRP"` |
| 4 | 2 | protocol version |
| 6 | 2 | type: 1 hello acknowledged, 2 stats, 3 pong |
| 8 | 8 | server time, microseconds |
| 16 | 1 | name length |
| 17 | n | server name, UTF-8 |
| 17+n | 2 | ack: 0; stats: encoder frames per second |
| 19+n | 2 | ack: 0; stats: bitrate in kilobits per second |

The phone stops retrying its hello as soon as it sees a type 1. A type 3 pong
puts the ping's timestamp in the server time field, so the phone can subtract it
from its own clock.

### Discovery

The phone broadcasts `"JVRQ"` to `255.255.255.255:8931`:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `"JVRQ"` |
| 4 | 2 | protocol version |
| 6 | 1 | name length |
| 7 | n | phone name, UTF-8 |

The PC answers the sender:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `"JVRE"` |
| 4 | 2 | protocol version |
| 6 | 2 | pose/video port, normally 8930 |
| 8 | 1 | flags, bit 0 = SteamVR is running |
| 9 | 1 | name length |
| 10 | n | PC name, UTF-8 |

### Video

Each datagram carries one fragment of one frame.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `"JVV1"` |
| 4 | 2 | protocol version |
| 6 | 2 | flags, bit 0 = this frame is a keyframe |
| 8 | 8 | frame id, increasing |
| 16 | 2 | fragment index, from 0 |
| 18 | 2 | fragment count |
| 20 | 4 | total bytes of the frame |
| 24 | n | payload |

The payload is Annex-B H.264 with start codes, one access unit per frame id.
Keep payloads at or below 1200 bytes so no fragment is ever fragmented by IP.
The phone drops any frame older than the newest completed one and reassembles
the rest in fragment index order.
