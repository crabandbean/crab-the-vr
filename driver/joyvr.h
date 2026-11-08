/*
 * joyvr.h — shared ABI between the JoyVR kernel module and its user space daemon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * This header is the single source of truth for the structures that cross the
 * kernel boundary. The kernel module and the daemon both include it, so there
 * is no chance of them disagreeing about layout.
 */

#ifndef _JOYVR_H
#define _JOYVR_H

#include <linux/types.h>
#include <linux/ioctl.h>

#define JOYVR_VERSION_MAJOR 1
#define JOYVR_VERSION_MINOR 0

#define JOYVR_DEVICE_NAME "joyvr"
#define JOYVR_MAX_PLAYERS 4

#define JOYVR_VENDOR_NINTENDO 0x057e
#define JOYVR_PRODUCT_WIIU_PRO 0x0330
#define JOYVR_PRODUCT_JOYCON_L 0x2006
#define JOYVR_PRODUCT_JOYCON_R 0x2007
#define JOYVR_PRODUCT_SWITCH_PRO 0x2009

/* Buttons, in the Nintendo layout the pad actually has. */
#define JOYVR_BTN_A       (1u << 0)
#define JOYVR_BTN_B       (1u << 1)
#define JOYVR_BTN_X       (1u << 2)
#define JOYVR_BTN_Y       (1u << 3)
#define JOYVR_BTN_L       (1u << 4)
#define JOYVR_BTN_R       (1u << 5)
#define JOYVR_BTN_ZL      (1u << 6)
#define JOYVR_BTN_ZR      (1u << 7)
#define JOYVR_BTN_PLUS    (1u << 8)
#define JOYVR_BTN_MINUS   (1u << 9)
#define JOYVR_BTN_HOME    (1u << 10)
#define JOYVR_BTN_CAPTURE (1u << 11)
#define JOYVR_BTN_DUP     (1u << 12)
#define JOYVR_BTN_DDOWN   (1u << 13)
#define JOYVR_BTN_DLEFT   (1u << 14)
#define JOYVR_BTN_DRIGHT  (1u << 15)
#define JOYVR_BTN_L3      (1u << 16)
#define JOYVR_BTN_R3      (1u << 17)

/* One frame of controller state, written by the daemon. */
struct joyvr_output {
	__u32 buttons;      /* JOYVR_BTN_* */
	__s16 lx;           /* left stick, -32768..32767 */
	__s16 ly;
	__s16 rx;
	__s16 ry;
	__u16 vendor;
	__u16 product;
	__u8  connected;
	__u8  battery;      /* 0..100, 255 when unknown */
	__u16 _pad;
};

/* One frame of host to controller state, read by the daemon. */
struct joyvr_input {
	__u16 rumble_left;   /* 0..65535 */
	__u16 rumble_right;
	__u8  player;        /* 0..3, LED/player slot */
	__u8  lightbar[3];
	__u8  _pad;
	__u64 timestamp;     /* ktime, nanoseconds */
};

/* What the daemon passes to JOYVR_IOCTL_BIND. */
struct joyvr_binding {
	__u32 player;    /* 0..JOYVR_MAX_PLAYERS-1 */
	__s32 tty_fd;    /* an open tty the reports should go to */
	__u32 flags;     /* reserved, must be 0 */
};

struct joyvr_info {
	__u32 version_major;
	__u32 version_minor;
	__u32 max_players;
	__u32 reserved;
};

#define JOYVR_IOC_MAGIC 'J'

#define JOYVR_IOCTL_BIND        _IOW(JOYVR_IOC_MAGIC, 0x10, struct joyvr_binding)
#define JOYVR_IOCTL_UNBIND      _IO(JOYVR_IOC_MAGIC, 0x11)
#define JOYVR_IOCTL_SUBMIT      _IOW(JOYVR_IOC_MAGIC, 0x12, struct joyvr_output)
#define JOYVR_IOCTL_RESET       _IO(JOYVR_IOC_MAGIC, 0x13)
#define JOYVR_IOCTL_GET_INFO    _IOR(JOYVR_IOC_MAGIC, 0x14, struct joyvr_info)

#endif /* _JOYVR_H */
