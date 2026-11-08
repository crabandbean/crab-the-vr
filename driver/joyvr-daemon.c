// SPDX-License-Identifier: GPL-2.0
/*
 * joyvr-daemon — feeds the joyvr kernel module from a Wii U Pro Controller
 * connected through a USB serial adapter.
 *
 *   sudo joyvr-daemon --tty /dev/ttyUSB0 --player 0
 *   sudo joyvr-daemon --tty /dev/ttyUSB0 --dump      # hex dump raw reports
 *
 * The heavy lifting (evdev gamepad, rumble queue, shared state page) lives in
 * the kernel module. This program only has to read reports, translate them and
 * write rumble back.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include <sys/ioctl.h>

#include "joyvr.h"

static volatile sig_atomic_t keep_running = 1;

static void on_signal(int signal_number)
{
	(void)signal_number;
	keep_running = 0;
}

static int configure_tty(int fd)
{
	struct termios tio;

	if (tcgetattr(fd, &tio) < 0)
		return -1;

	cfmakeraw(&tio);
	cfsetispeed(&tio, B115200);
	cfsetospeed(&tio, B115200);
	tio.c_cflag |= (CLOCAL | CREAD);
	tio.c_cflag &= ~CRTSCTS;
	tio.c_cc[VMIN] = 0;
	tio.c_cc[VTIME] = 0;

	return tcsetattr(fd, TCSANOW, &tio);
}

/* ------------------------------------------------------------------------- */
/* Report translation                                                        */
/* ------------------------------------------------------------------------- */

/*
 * Wii U Pro Controller buttons, 16 bit little endian. This is the layout the
 * pad itself uses; if a particular adapter differs, run with --dump and adjust
 * the table below.
 */
#define WIIU_LEFT   (1u << 0)
#define WIIU_DOWN   (1u << 1)
#define WIIU_UP     (1u << 2)
#define WIIU_RIGHT  (1u << 3)
#define WIIU_START  (1u << 4)
#define WIIU_SELECT (1u << 5)
#define WIIU_HOME   (1u << 6)
#define WIIU_X      (1u << 7)
#define WIIU_Y      (1u << 8)
#define WIIU_A      (1u << 9)
#define WIIU_B      (1u << 10)
#define WIIU_L      (1u << 11)
#define WIIU_R      (1u << 12)
#define WIIU_ZL     (1u << 13)
#define WIIU_ZR     (1u << 14)

static int16_t axis_from_byte(uint8_t value)
{
	if (value == 128)
		return 0;

	return (int16_t)(((int)value - 128) * 257);
}

/*
 * Translates one Wii U Pro report into the module's state structure.
 *
 * Bluetooth style reports start with 0xA1 and carry the buttons at offset 2.
 * A USB adapter that already strips the report header gives us the same fields
 * eight bytes earlier, which is what the fallback below handles.
 */
static void translate(const uint8_t *report, size_t length,
		      struct joyvr_output *state)
{
	unsigned int offset;
	uint16_t buttons;
	unsigned int index;

	if (length < 9) {
		state->connected = 0;
		return;
	}

	if (report[0] == 0xA1) {
		offset = 2;
	} else {
		offset = 0;
	}

	if (length < offset + 7) {
		state->connected = 0;
		return;
	}

	buttons = (uint16_t)(report[offset]) | ((uint16_t)(report[offset + 1]) << 8);

	state->buttons = 0;
	if (buttons & WIIU_A) state->buttons |= JOYVR_BTN_A;
	if (buttons & WIIU_B) state->buttons |= JOYVR_BTN_B;
	if (buttons & WIIU_X) state->buttons |= JOYVR_BTN_X;
	if (buttons & WIIU_Y) state->buttons |= JOYVR_BTN_Y;
	if (buttons & WIIU_L) state->buttons |= JOYVR_BTN_L;
	if (buttons & WIIU_R) state->buttons |= JOYVR_BTN_R;
	if (buttons & WIIU_ZL) state->buttons |= JOYVR_BTN_ZL;
	if (buttons & WIIU_ZR) state->buttons |= JOYVR_BTN_ZR;
	if (buttons & WIIU_START) state->buttons |= JOYVR_BTN_PLUS;
	if (buttons & WIIU_SELECT) state->buttons |= JOYVR_BTN_MINUS;
	if (buttons & WIIU_HOME) state->buttons |= JOYVR_BTN_HOME;
	if (buttons & WIIU_UP) state->buttons |= JOYVR_BTN_DUP;
	if (buttons & WIIU_DOWN) state->buttons |= JOYVR_BTN_DDOWN;
	if (buttons & WIIU_LEFT) state->buttons |= JOYVR_BTN_DLEFT;
	if (buttons & WIIU_RIGHT) state->buttons |= JOYVR_BTN_DRIGHT;

	state->lx = axis_from_byte(report[offset + 2]);
	state->ly = axis_from_byte(report[offset + 3]);
	state->rx = axis_from_byte(report[offset + 4]);
	state->ry = axis_from_byte(report[offset + 5]);

	state->vendor = JOYVR_VENDOR_NINTENDO;
	state->product = JOYVR_PRODUCT_WIIU_PRO;
	state->connected = 1;
}

/*
 * Rumble output report. Adapters differ here; this is the Wii U Pro "rumble
 * only" style report and is the part to adjust if your adapter stays silent.
 */
static size_t build_rumble_report(const struct joyvr_input *host,
				  uint8_t *buffer, size_t size)
{
	if (size < 3)
		return 0;

	buffer[0] = 0xA2;
	buffer[1] = 0x11;
	buffer[2] = (uint8_t)((host->rumble_left * 255) / 65535);

	return 3;
}

/* ------------------------------------------------------------------------- */

static void usage(const char *name)
{
	fprintf(stderr,
		"usage: %s --tty /dev/ttyUSB0 [--player N] [--dump]\n"
		"  --tty PATH    serial port the adapter is on\n"
		"  --player N    player slot 0-3 (default 0)\n"
		"  --dump        print raw reports instead of translating them\n",
		name);
}

int main(int argc, char **argv)
{
	const char *tty_path = NULL;
	unsigned int player = 0;
	int dump = 0;
	int tty_fd;
	int control_fd;
	struct joyvr_binding binding;
	struct joyvr_output state;
	struct pollfd fds[2];
	int exit_code = EXIT_SUCCESS;
	int index;

	for (index = 1; index < argc; index++) {
		if (!strcmp(argv[index], "--tty") && index + 1 < argc)
			tty_path = argv[++index];
		else if (!strcmp(argv[index], "--player") && index + 1 < argc)
			player = (unsigned int)strtoul(argv[++index], NULL, 10);
		else if (!strcmp(argv[index], "--dump"))
			dump = 1;
		else {
			usage(argv[0]);
			return EXIT_FAILURE;
		}
	}

	if (!tty_path) {
		usage(argv[0]);
		return EXIT_FAILURE;
	}

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	tty_fd = open(tty_path, O_RDWR | O_NOCTTY | O_NONBLOCK);
	if (tty_fd < 0) {
		fprintf(stderr, "joyvr: cannot open %s: %s\n", tty_path, strerror(errno));
		return EXIT_FAILURE;
	}

	if (configure_tty(tty_fd) < 0)
		fprintf(stderr, "joyvr: warning, could not configure %s: %s\n",
			tty_path, strerror(errno));

	control_fd = open("/dev/joyvr", O_RDWR | O_NONBLOCK);
	if (control_fd < 0) {
		fprintf(stderr, "joyvr: cannot open /dev/joyvr: %s\n", strerror(errno));
		close(tty_fd);
		return EXIT_FAILURE;
	}

	memset(&binding, 0, sizeof(binding));
	binding.player = player;
	binding.tty_fd = tty_fd;

	if (ioctl(control_fd, JOYVR_IOCTL_BIND, &binding) < 0) {
		fprintf(stderr, "joyvr: bind failed: %s\n", strerror(errno));
		close(control_fd);
		close(tty_fd);
		return EXIT_FAILURE;
	}

	fprintf(stderr, "joyvr: bound player %u to %s\n", player, tty_path);

	memset(&state, 0, sizeof(state));

	fds[0].fd = tty_fd;
	fds[0].events = POLLIN;
	fds[1].fd = control_fd;
	fds[1].events = POLLIN;

	while (keep_running) {
		int ready = poll(fds, 2, 500);

		if (ready < 0) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "joyvr: poll failed: %s\n", strerror(errno));
			exit_code = EXIT_FAILURE;
			break;
		}

		if (ready == 0) {
			/* Nothing to do; the pad repeats its report by itself. */
			continue;
		}

		if (fds[0].revents & POLLIN) {
			uint8_t buffer[64];
			ssize_t length = read(tty_fd, buffer, sizeof(buffer));

			if (dump && length > 0) {
				ssize_t byte;
				fprintf(stderr, "report:");
				for (byte = 0; byte < length; byte++)
					fprintf(stderr, " %02x", buffer[byte]);
				fprintf(stderr, "\n");
			}

			if (length > 0) {
				memset(&state, 0, sizeof(state));
				translate((const uint8_t *)buffer, (size_t)length, &state);

				if (ioctl(control_fd, JOYVR_IOCTL_SUBMIT, &state) < 0 &&
				    errno != EAGAIN && errno != ENODEV)
					fprintf(stderr, "joyvr: submit failed: %s\n",
						strerror(errno));
			}
		}

		if (fds[1].fd >= 0 && (fds[1].revents & POLLIN)) {
			struct joyvr_input host;
			ssize_t got = read(control_fd, &host, sizeof(host));

			if (got == (ssize_t)sizeof(host)) {
				uint8_t report[8];
				size_t length = build_rumble_report(&host, report, sizeof(report));

				if (length > 0)
					write(tty_fd, report, length);
			}
		}

		if (fds[0].revents & (POLLHUP | POLLERR))
			break;
	}

	ioctl(control_fd, JOYVR_IOCTL_UNBIND);
	close(control_fd);
	close(tty_fd);

	fprintf(stderr, "joyvr: stopped\n");
	return exit_code;
}
