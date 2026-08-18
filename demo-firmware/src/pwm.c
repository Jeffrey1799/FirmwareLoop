/*
 * pwm.c - Modelled 20 kHz PWM generator.
 */
#include "firmware.h"

static uint32_t s_freq = PWM_TARGET_FREQ_HZ;

int pwm_init(void)
{
    s_freq = PWM_TARGET_FREQ_HZ;
    return 0;
}

uint32_t pwm_get_frequency_hz(void)
{
    return s_freq;
}