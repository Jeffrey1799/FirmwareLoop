/*
 * uart.c - Modelled UART on stdio. Trace through stderr (kept out of
 * RTT/serial capture paths), CLI replies through stdout.
 */
#include "firmware.h"

#include <stdio.h>
#include <string.h>

static char s_rx_buf[64];
static size_t s_rx_len = 0;
static int s_overrun = 0;

static int s_echo_back = 1;

void uart_init(void)
{
    s_rx_len = 0;
    s_overrun = 0;
    /* Unbuffered stdout: banner and CLI replies must arrive promptly when
       "UART" is a pipe (simulated DUT) just like a real trace port. */
    (void)setvbuf(stdout, NULL, _IONBF, 0);
    (void)setvbuf(stderr, NULL, _IONBF, 0);
}

int uart_putchar(char c)
{
    (void)uart_write(&c, 1);
    return (int)(unsigned char)c;
}

size_t uart_write(const char *buf, size_t len)
{
    if (buf == NULL || len == 0)
        return 0;
    /* CLI replies go to stdout = "serial out". */
    return fwrite(buf, 1, len, stdout);
}

int uart_rx_available(void)
{
    return s_overrun ? -1 : (int)s_rx_len;
}

/* Allow the harness to inject received characters when not fed from stdin. */
void uart_rx_inject(const char *data, size_t len)
{
    size_t i;
    for (i = 0; i < len; i++) {
        if (s_rx_len < sizeof(s_rx_buf)) {
            s_rx_buf[s_rx_len++] = data[i];
        } else {
            s_overrun = 1;
        }
    }
    if (s_echo_back)
        (void)fwrite(data, 1, len, stdout);
}