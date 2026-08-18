/*
 * main.c - Demo firmware entry point (host-simulated MCU).
 * Prints boot banner, then serves a tiny CLI over the modelled UART.
 */
#include "firmware.h"

#include <stdio.h>
#include <string.h>

static int handle_line(const char *line)
{
    char reply[128];
    int rc = fw_run_command(line, reply, sizeof(reply));
    if (rc == 0) {
        uart_write(reply, strlen(reply));
        uart_write("\r\n", 2);
    } else {
        uart_write("ERR\r\n", 5);
    }
    return rc;
}

int fw_run_command(const char *cmd, char *reply, size_t reply_cap)
{
    char tmp[128];
    if (strcmp(cmd, "jedec") == 0) {
        uint8_t id[SPI_FLASH_JEDEC_LEN];
        uint8_t n = spi_flash_read_jedec_id(id, sizeof(id));
        if (n == SPI_FLASH_JEDEC_LEN) {
            snprintf(tmp, sizeof(tmp), "JEDEC %02X %02X %02X", id[0], id[1], id[2]);
        } else {
            snprintf(tmp, sizeof(tmp), "JEDEC FAIL n=%u", (unsigned)n);
        }
    } else if (strcmp(cmd, "pwm") == 0) {
        snprintf(tmp, sizeof(tmp), "PWM %lu Hz", (unsigned long)pwm_get_frequency_hz());
    } else if (strncmp(cmd, "echo ", 5) == 0) {
        snprintf(tmp, sizeof(tmp), "%s", cmd + 5);
    } else {
        return -1;
    }
    if (reply_cap > 0) {
        strncpy(reply, tmp, reply_cap - 1);
        reply[reply_cap - 1] = '\0';
    }
    return 0;
}

int main(void)
{
    char line[128];
    size_t n = 0;

    uart_init();

    printf("%s\r\n", FW_BANNER_BOOTLOADER);
    printf("%s\r\n", FW_BANNER_APP_STARTED);

    for (;;) {
        int ch = fgetc(stdin);
        if (ch == EOF || ch == '\n') {
            if (n > 0) {
                line[n] = '\0';
                handle_line(line);
                n = 0;
            }
            if (ch == EOF)
                break;
        } else if (ch == '\r') {
            /* ignore */
        } else if (n < sizeof(line) - 1) {
            line[n++] = (char)ch;
        }
    }
    return 0;
}