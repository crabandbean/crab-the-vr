// SPDX-License-Identifier: BSD-3-Clause
/*
 * joyvr.c — a Wii U Pro / Switch pad bridge for Linux
 *
 * The module owns one character device, /dev/joyvr. A user space daemon opens
 * the serial port the adapter is on, then hands the tty to the module with
 * JOYVR_IOCTL_BIND. From then on:
 *
 *   write()    raw HID reports the pad should receive (rumble, LEDs)
 *   JOYVR_IOCTL_SUBMIT  one frame of pad state, reflected into an evdev gamepad
 *   read()     one frame of host state (rumble) the pad should play
 *   mmap()     the same host state, shared and lock free
 *
 * The gamepad appears to Steam as "JoyVR Gamepad" with the Nintendo video game
 * product id, so Steam Input picks a sensible default configuration.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/mm.h>
#include <linux/poll.h>
#include <linux/kfifo.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/ktime.h>
#include <linux/input.h>
#include <linux/tty.h>
#include <linux/device.h>

#include "joyvr.h"

#define JOYVR_MAX_REPORT 128
#define JOYVR_INPUT_FIFO 16

struct joyvr_player {
	struct input_dev *input;
	struct joyvr_output state;
	struct joyvr_input host;
	struct page *page;
	void *page_virt;
	spinlock_t lock;          /* protects state/host and the fifo */
	struct kfifo input_fifo;
	bool bound;
};

struct joyvr_handle {
	unsigned int id;
	struct tty_struct *tty;
	struct joyvr_player *player;
	struct kfifo input_fifo;
	wait_queue_head_t readq;
	spinlock_t fifo_lock;
	bool bound;
};

static unsigned int joyvr_count = JOYVR_MAX_PLAYERS;
module_param(joyvr_count, uint, 0444);
MODULE_PARM_DESC(joyvr_count, "Number of virtual players to expose (1-4)");

static struct joyvr_player *joyvr_players;
static DEFINE_MUTEX(joyvr_lock);
static atomic_t joyvr_open_count = ATOMIC_INIT(0);

static struct joyvr_handle *joyvr_handle(struct file *file)
{
	return file->private_data;
}

/* ------------------------------------------------------------------------- */
/* Evdev gamepad                                                             */
/* ------------------------------------------------------------------------- */

static int joyvr_play_effect(struct input_dev *dev, void *data,
			     struct ff_effect *effect)
{
	struct joyvr_player *player = input_get_drvdata(dev);
	struct joyvr_input host;
	unsigned long flags;

	if (!player || !effect)
		return 0;

	memset(&host, 0, sizeof(host));
	host.timestamp = ktime_get_ns();
	host.player = 0;

	if (effect->type == FF_RUMBLE) {
		host.rumble_left = effect->u.rumble.strong_magnitude;
		host.rumble_right = effect->u.rumble.weak_magnitude;
	}

	spin_lock_irqsave(&player->lock, flags);
	kfifo_in(&player->input_fifo, &host, 1);
	player->host = host;
	spin_unlock_irqrestore(&player->lock, flags);

	wake_up_interruptible(&player->bound ? &player->input->poll : NULL);

	return 0;
}

static void joyvr_report_state(struct joyvr_player *player,
			       const struct joyvr_output *state)
{
	struct input_dev *input = player->input;

	input_report_key(input, BTN_SOUTH, !!(state->buttons & JOYVR_BTN_B));
	input_report_key(input, BTN_EAST, !!(state->buttons & JOYVR_BTN_A));
	input_report_key(input, BTN_NORTH, !!(state->buttons & JOYVR_BTN_Y));
	input_report_key(input, BTN_WEST, !!(state->buttons & JOYVR_BTN_X));
	input_report_key(input, BTN_TL, !!(state->buttons & JOYVR_BTN_L));
	input_report_key(input, BTN_TR, !!(state->buttons & JOYVR_BTN_R));
	input_report_key(input, BTN_TL2, !!(state->buttons & JOYVR_BTN_ZL));
	input_report_key(input, BTN_TR2, !!(state->buttons & JOYVR_BTN_ZR));
	input_report_key(input, BTN_START, !!(state->buttons & JOYVR_BTN_PLUS));
	input_report_key(input, BTN_SELECT, !!(state->buttons & JOYVR_BTN_MINUS));
	input_report_key(input, BTN_MODE, !!(state->buttons & JOYVR_BTN_HOME));
	input_report_key(input, BTN_THUMBL, !!(state->buttons & JOYVR_BTN_L3));
	input_report_key(input, BTN_THUMBR, !!(state->buttons & JOYVR_BTN_R3));

	input_report_abs(input, ABS_HAT0X,
			 !!(state->buttons & JOYVR_BTN_DRIGHT) -
			 !!(state->buttons & JOYVR_BTN_DLEFT));
	input_report_abs(input, ABS_HAT0Y,
			 !!(state->buttons & JOYVR_BTN_DDOWN) -
			 !!(state->buttons & JOYVR_BTN_DUP));

	input_report_abs(input, ABS_X, state->lx);
	input_report_abs(input, ABS_Y, state->ly);
	input_report_abs(input, ABS_RX, state->rx);
	input_report_abs(input, ABS_RY, state->ry);

	input_sync(input);
}

static int joyvr_input_create(struct joyvr_player *player, unsigned int index)
{
	struct input_dev *input;
	int error;

	input = input_allocate_device();
	if (!input)
		return -ENOMEM;

	input->name = "JoyVR Gamepad";
	input->phys = "joyvr/input0";
	input->id.bustype = BUS_VIRTUAL;
	input->id.vendor = JOYVR_VENDOR_NINTENDO;
	input->id.product = JOYVR_PRODUCT_WIIU_PRO;
	input->id.version = 0x0110;

	input_set_drvdata(input, player);

	set_bit(EV_KEY, input->evbit);
	set_bit(EV_ABS, input->evbit);
	set_bit(EV_FF, input->evbit);

	input_set_capability(input, EV_KEY, BTN_SOUTH);
	input_set_capability(input, EV_KEY, BTN_EAST);
	input_set_capability(input, EV_KEY, BTN_NORTH);
	input_set_capability(input, EV_KEY, BTN_WEST);
	input_set_capability(input, EV_KEY, BTN_TL);
	input_set_capability(input, EV_KEY, BTN_TR);
	input_set_capability(input, EV_KEY, BTN_TL2);
	input_set_capability(input, EV_KEY, BTN_TR2);
	input_set_capability(input, EV_KEY, BTN_START);
	input_set_capability(input, EV_KEY, BTN_SELECT);
	input_set_capability(input, EV_KEY, BTN_MODE);
	input_set_capability(input, EV_KEY, BTN_THUMBL);
	input_set_capability(input, EV_KEY, BTN_THUMBR);

	input_set_abs_params(input, ABS_X, -32768, 32767, 16, 128);
	input_set_abs_params(input, ABS_Y, -32768, 32767, 16, 128);
	input_set_abs_params(input, ABS_RX, -32768, 32767, 16, 128);
	input_set_abs_params(input, ABS_RY, -32768, 32767, 16, 128);
	input_set_abs_params(input, ABS_HAT0X, -1, 1, 0, 0);
	input_set_abs_params(input, ABS_HAT0Y, -1, 1, 0, 0);

	error = input_ff_create_memless(input, NULL, joyvr_play_effect);
	if (error) {
		input_free_device(input);
		return error;
	}

	error = input_register_device(input);
	if (error) {
		input_free_device(input);
		return error;
	}

	player->input = input;
	return 0;
}

static void joyvr_input_destroy(struct joyvr_player *player)
{
	if (player->input) {
		input_unregister_device(player->input);
		player->input = NULL;
	}
}

/* ------------------------------------------------------------------------- */
/* Serial side                                                               */
/* ------------------------------------------------------------------------- */

static int joyvr_tty_write(struct tty_struct *tty, const unsigned char *buffer,
			   unsigned int count)
{
	int written = 0;

	if (!tty || !tty->ops || !tty->ops->write)
		return -EIO;

	while (written < (int)count) {
		int chunk = tty->ops->write(tty, buffer + written, count - written);

		if (chunk < 0)
			return chunk;
		if (chunk == 0)
			return written ? written : -EAGAIN;
		written += chunk;
	}

	return written;
}

/* ------------------------------------------------------------------------- */
/* File operations                                                           */
/* ------------------------------------------------------------------------- */

static int joyvr_open(struct inode *inode, struct file *file)
{
	struct joyvr_handle *handle;
	int error;

	handle = kzalloc(sizeof(*handle), GFP_KERNEL);
	if (!handle)
		return -ENOMEM;

	handle->id = atomic_fetch_inc(&joyvr_open_count);
	init_waitqueue_head(&handle->readq);
	spin_lock_init(&handle->fifo_lock);

	error = kfifo_alloc(&handle->input_fifo, JOYVR_INPUT_FIFO,
			    GFP_KERNEL);
	if (error) {
		kfree(handle);
		return error;
	}

	file->private_data = handle;
	return 0;
}

static void joyvr_unbind(struct joyvr_handle *handle)
{
	struct joyvr_player *player = handle->player;

	if (!handle->bound || !player)
		return;

	mutex_lock(&joyvr_lock);
	joyvr_input_destroy(player);
	player->bound = false;
	handle->player = NULL;
	handle->bound = false;
	mutex_unlock(&joyvr_lock);

	if (handle->tty) {
		tty_kref_put(handle->tty);
		handle->tty = NULL;
	}
}

static int joyvr_release(struct inode *inode, struct file *file)
{
	struct joyvr_handle *handle = joyvr_handle(file);

	joyvr_unbind(handle);
	kfifo_free(&handle->input_fifo);
	kfree(handle);
	file->private_data = NULL;
	return 0;
}

static ssize_t joyvr_read(struct file *file, char __user *buffer, size_t count,
			  loff_t *offset)
{
	struct joyvr_handle *handle = joyvr_handle(file);
	struct joyvr_input host;
	unsigned long flags;
	unsigned int copied = 0;

	if (count < sizeof(handle->player ? sizeof(struct joyvr_input) : 0))
		;
	if (count < sizeof(struct joyvr_input))
		return -EINVAL;

	if (kfifo_is_empty(&handle->input_fifo)) {
		if (file->f_flags & O_NONBLOCK)
			return -EAGAIN;
		if (wait_event_interruptible(handle->readq,
					     !kfifo_is_empty(&handle->input_fifo)))
			return -ERESTARTSYS;
	}

	spin_lock_irqsave(&handle->fifo_lock, flags);
	kfifo_out(&handle->input_fifo, &host, 1);
	spin_unlock_irqrestore(&handle->fifo_lock, flags);
	copied = sizeof(host);

	if (copy_to_user(buffer, &host, copied))
		return -EFAULT;

	return copied;
}

static __poll_t joyvr_poll(struct file *file, poll_table *wait)
{
	struct joyvr_handle *handle = joyvr_handle(file);
	__poll_t mask = 0;

	poll_wait(file, &handle->readq, wait);
	if (!kfifo_is_empty(&handle->input_fifo))
		mask |= EPOLLIN | EPOLLRDNORM;
	mask |= EPOLLOUT | EPOLLWRNORM;

	return mask;
}

static ssize_t joyvr_write(struct file *file, const char __user *buffer,
			   size_t count, loff_t *offset)
{
	struct joyvr_handle *handle = joyvr_handle(file);
	unsigned char report[JOYVR_MAX_REPORT];
	int written;

	if (!handle->bound || !handle->tty)
		return -ENODEV;
	if (count == 0 || count > JOYVR_MAX_REPORT)
		return -EINVAL;

	if (copy_from_user(report, buffer, count))
		return -EFAULT;

	written = joyvr_tty_write(handle->tty, report, count);
	if (written < 0)
		return written;

	return count;
}

static int joyvr_mmap(struct file *file, struct vm_area_struct *vma)
{
	struct joyvr_handle *handle = joyvr_handle(file);
	struct joyvr_player *player = handle->player;
	unsigned long size = vma->vm_end - vma->vm_start;

	if (!player || !player->page)
		return -ENODEV;
	if (vma->vm_pgoff != 0 || size != PAGE_SIZE)
		return -EINVAL;

	vma->vm_flags |= VM_DONTEXPAND | VM_DONTDUMP;

	return remap_pfn_range(vma, vma->vm_start,
			       page_to_pfn(player->page), size,
			       vma->vm_page_prot);
}

static long joyvr_bind(struct joyvr_handle *handle,
		       const struct joyvr_binding *binding)
{
	struct joyvr_player *player;
	struct file *tty_file;
	struct tty_struct *tty;
	unsigned int player_index;
	int error;

	if (handle->bound)
		return -EBUSY;

	player_index = binding->player;
	if (player_index >= joyvr_count)
		return -EINVAL;

	tty_file = fget(binding->tty_fd);
	if (!tty_file)
		return -EBADF;

	tty = tty_file->private_data;
	if (!tty || tty->magic != TTY_MAGIC || !tty->ops || !tty->ops->write) {
		fput(tty_file);
		return -EINVAL;
	}

	mutex_lock(&joyvr_lock);

	player = &joyvr_players[player_index];
	if (player->bound) {
		mutex_unlock(&joyvr_lock);
		fput(tty_file);
		return -EBUSY;
	}

	error = joyvr_input_create(player, player_index);
	if (error) {
		mutex_unlock(&joyvr_lock);
		fput(tty_file);
		return error;
	}

	handle->tty = tty_kref_get(tty);
	handle->player = player;
	handle->bound = true;
	player->bound = true;

	mutex_unlock(&joyvr_lock);

	/* The daemon keeps this descriptor open for as long as it is bound. */
	fput(tty_file);

	return 0;
}

static long joyvr_ioctl(struct file *file, unsigned int cmd,
			unsigned long arg)
{
	struct joyvr_handle *handle = joyvr_handle(file);

	switch (cmd) {
	case JOYVR_IOCTL_BIND: {
		struct joyvr_binding binding;

		if (copy_from_user(&binding, (void __user *)arg, sizeof(binding)))
			return -EFAULT;
		if (binding.flags != 0)
			return -EINVAL;
		return joyvr_bind(handle, &binding);
	}
	case JOYVR_IOCTL_UNBIND:
		joyvr_unbind(handle);
		return 0;

	case JOYVR_IOCTL_SUBMIT: {
		struct joyvr_output state;
		struct joyvr_player *player = handle->player;

		if (!player || !player->bound)
			return -ENODEV;
		if (copy_from_user(&state, (void __user *)arg, sizeof(state)))
			return -EFAULT;

		spin_lock(&player->lock);
		player->state = state;
		spin_unlock(&player->lock);

		joyvr_report_state(player, &state);
		return 0;
	}

	case JOYVR_IOCTL_RESET: {
		struct joyvr_player *player = handle->player;

		if (!player)
			return -ENODEV;

		spin_lock(&player->lock);
		memset(&player->state, 0, sizeof(player->state));
		kfifo_reset(&player->input_fifo);
		spin_unlock(&player->lock);
		kfifo_reset(&handle->input_fifo);
		return 0;
	}

	case JOYVR_IOCTL_GET_INFO: {
		struct joyvr_info info = {
			.version_major = JOYVR_VERSION_MAJOR,
			.version_minor = JOYVR_VERSION_MINOR,
			.max_players = joyvr_count,
			.reserved = 0,
		};

		if (copy_to_user((void __user *)arg, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}

	default:
		return -ENOTTY;
	}
}

static const struct file_operations joyvr_fops = {
	.owner = THIS_MODULE,
	.open = joyvr_open,
	.release = joyvr_release,
	.read = joyvr_read,
	.write = joyvr_write,
	.poll = joyvr_poll,
	.unlocked_ioctl = joyvr_ioctl,
	.compat_ioctl = joyvr_ioctl,
	.mmap = joyvr_mmap,
	.llseek = no_llseek,
};

static struct miscdevice joyvr_misc = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = JOYVR_DEVICE_NAME,
	.fops = &joyvr_fops,
	.mode = 0660,
};

/* ------------------------------------------------------------------------- */
/* Module                                                                    */
/* ------------------------------------------------------------------------- */

static int __init joyvr_init(void)
{
	unsigned int index;
	int error;

	if (joyvr_count < 1 || joyvr_count > JOYVR_MAX_PLAYERS)
		joyvr_count = JOYVR_MAX_PLAYERS;

	joyvr_players = kcalloc(joyvr_count, sizeof(*joyvr_players), GFP_KERNEL);
	if (!joyvr_players)
		return -ENOMEM;

	for (index = 0; index < joyvr_count; index++) {
		struct joyvr_player *player = &joyvr_players[index];

		spin_lock_init(&player->lock);
		error = kfifo_alloc(&player->input_fifo, JOYVR_INPUT_FIFO,
				    GFP_KERNEL);
		if (error)
			goto fail_fifo;

		player->page = alloc_pages(GFP_KERNEL | __GFP_ZERO, 0);
		if (!player->page) {
			error = -ENOMEM;
			goto fail_fifo;
		}
		player->page_virt = page_address(player->page);
		player->bound = false;
	}

	error = misc_register(&joyvr_misc);
	if (error)
		goto fail_fifo;

	pr_info("joyvr: %u player(s) ready on /dev/%s\n", joyvr_count,
		JOYVR_DEVICE_NAME);
	return 0;

fail_fifo:
	while (index--) {
		kfifo_free(&joyvr_players[index].input_fifo);
		if (joyvr_players[index].page)
			__free_pages(joyvr_players[index].page, 0);
	}
	kfree(joyvr_players);
	joyvr_players = NULL;
	return error;
}

static void __exit joyvr_exit(void)
{
	unsigned int index;

	misc_deregister(&joyvr_misc);

	for (index = 0; index < joyvr_count; index++) {
		joyvr_input_destroy(&joyvr_players[index]);
		kfifo_free(&joyvr_players[index].input_fifo);
		if (joyvr_players[index].page)
			__free_pages(joyvr_players[index].page, 0);
	}

	kfree(joyvr_players);
	joyvr_players = NULL;

	pr_info("joyvr: unloaded\n");
}

module_init(joyvr_init);
module_exit(joyvr_exit);

MODULE_AUTHOR("JoyVR");
MODULE_DESCRIPTION("Wii U Pro / Switch controller bridge with a shared host state page");
MODULE_LICENSE("Dual BSD/GPL");
MODULE_VERSION("1.0");
