"""Power tests (Spec §18 test_idle_current). Simulated PSU by default; a
VISA backend in lab config switches these to real hardware measurements."""


def test_idle_current(psu):
    current = psu.measure_current()
    assert current < 0.050  # A


def test_supply_voltage(psu):
    voltage = psu.measure_voltage()
    assert 3.0 <= voltage <= 3.6  # V