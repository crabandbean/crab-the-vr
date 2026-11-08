obj-m += joyvr.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f joyvr-daemon

install: all
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	install -D -m 755 joyvr-daemon /usr/local/bin/joyvr-daemon
	install -D -m 644 99-joyvr.rules /etc/udev/rules.d/99-joyvr.rules
	install -m 644 joyvr.service /etc/systemd/system/joyvr.service
	depmod -a

daemon: joyvr-daemon.c joyvr.h
	$(CC) -O2 -Wall -Wextra -o joyvr-daemon joyvr-daemon.c

.PHONY: all clean install daemon
