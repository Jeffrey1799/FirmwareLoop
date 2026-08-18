/*
 * spi_flash.c - Modelled SPI NOR flash driver.
 *
 * The JEDEC read (0x9F) of the virtual flash returns a fixed 3-byte ID.
 * This module is the intentional target for the closed-loop repair demo:
 * introduce a defect here, run the HIL harness, then let the AI agent
 * fix it and re-verify.
 */
#include "firmware.h"

#include <string.h>

static const uint8_t s_jedec_id[SPI_FLASH_JEDEC_LEN] = { 0xEF, 0x40, 0x18 }; /* Winbond W25Q128JV */

static uint32_t s_capacity = 16u * 1024u * 1024u; /* 16 MiB */

uint8_t spi_flash_read_jedec_id(uint8_t *out, uint8_t capacity)
{
    if (out == NULL || capacity < SPI_FLASH_JEDEC_LEN)
        return 0; /* buffer too small -> 0 bytes read */
    memcpy(out, s_jedec_id, SPI_FLASH_JEDEC_LEN);
    return SPI_FLASH_JEDEC_LEN;
}

uint32_t spi_flash_capacity(void)
{
    return s_capacity;
}