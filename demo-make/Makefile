CC ?= gcc
CFLAGS := -g -Wall -Iinclude

app.elf: src/main.c
	$(CC) $(CFLAGS) -o $@ src/main.c

clean:
	rm -f app.elf

.PHONY: clean