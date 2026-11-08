# joyvr — Nintendo pads on Linux

A small kernel module plus a daemon that turns a Wii U Pro Controller (or a
Switch pad through the same kind of serial adapter) into a normal evdev gamepad
that Steam and every other game can use.

This is the Linux side of the project. It is independent of the iPhone app: the
module is a plain input driver, useful on its own.

## Pieces

- `joyvr.c` — the kernel module. One character device, `/dev/joyvr`.
- `joyvr.h` — the ABI both sides share. Do not change one without the other.
- `joyvr-daemon.c` — reads the serial adapter, translates reports, asks the
  module to publish pad state, and plays rumble back to the pad.
- `joyvr.service`, `99-joyvr.rules`, `dkms.conf` — packaging.

## How it works

The daemon is the only thing that talks to the adapter. It hands the tty to the
module once:

    ioctl(JOYVR_IOCTL_BIND, { .player = 0, .tty_fd = fd })

From then on:

- `ioctl(JOYVR_IOCTL_SUBMIT, &struct joyvr_output)` publishes one frame of
  buttons and sticks; the module reflects it into an evdev gamepad called
  **JoyVR Gamepad**.
- The game's rumble effects arrive as `struct joyvr_input` through `read()`, or
  straight from the shared page with `mmap()`, which is what makes feedback
  feel instant.
- `write()` sends raw reports to the pad (rumble, lights).

## Build

    sudo apt install build-essential linux-headers-$(uname -r)
    make
    make daemon
    sudo make install

Or with DKMS so it survives kernel updates:

    sudo cp -r . /usr/src/joyvr-1.0
    sudo dkms add -m joyvr -v 1.0
    sudo dkms build -m joyvr -v 1.0
    sudo dkms install -m joyvr -v 1.0

## Run

    sudo joyvr-daemon --tty /dev/ttyUSB0 --player 0

The pad appears immediately:

    ls /dev/input/by-id/
    evtest /dev/input/eventX

`--dump` prints the raw bytes from the adapter. If your adapter's byte layout is
different from the default Wii U Pro layout in `translate()`, that output is what
you need to adjust the offsets and the button table.

## Gap to close

The report layout and the rumble output report are the two things that vary
between adapters. The defaults here follow the Wii U Pro Controller's own layout;
a Mayflash-style adapter in DInput mode may need the offsets shifted, which
`--dump` makes quick to work out.
