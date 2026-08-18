/*
 * firmware.h - FirmwareLoop demo firmware (host-compiled).
 *
 * This is a *simulated* MCU firmware: it models boot banner, UART echo,
 * SPI-flash JEDEC ID read and a 20 kHz PWM generator on the host, so the
 * build pipeline and HIL harness can be exercised without real silicon.
 * Replace this tree with the real firmware source when integrating.
 */
#ifndef FIRMWARE_H
#define FIRMWARE_H

#include <stdint.h>
#include <stddef.h>

#define FW_BANNER_BOOTLOADER      "Bootloader v1.0"
#define FW_BANNER_APP_STARTED     "Application started"

/* ---------- UART (modelled on stdout) ---------- */
void     uart_init(void);
int      uart_putchar(char c);
size_t   uart_write(const char *buf, size_t len);
/* Non-blocking trace: returns number of pending chars, -1 if overrun. */
int      uart_rx_available(void);

/* ---------- SPI flash (modelled) ---------- */
/* JEDEC id of the (virtual) SPI NOR: 3 bytes. */
#define SPI_FLASH_JEDEC_LEN 3u
/* Returns number of ID bytes actually read; 0 on failure. */
uint8_t  spi_flash_read_jedec_id(uint8_t *out, uint8_t capacity);
/* Total modelled flash size in bytes (for drive tests). */
uint32_t spi_flash_capacity(void);

/* ---------- PWM (modelled) ---------- */
#define PWM_TARGET_FREQ_HZ 20000u
uint32_t pwm_get_frequency_hz(void);
int      pwm_init(void);

/* ---------- CLI dispatcher (used by tests over "UART") ---------- */
int  fw_run_command(const char *cmd, char *reply, size_t reply_cap);

#endif /* FIRMWARE_H */