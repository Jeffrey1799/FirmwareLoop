"""Signal / scope measurements (Spec M5: frequency, Vpp)."""


def test_pwm_frequency(scope):
    freq = scope.measure_frequency("CH1")
    assert 19900 <= freq <= 20100  # Hz


def test_pwm_vpp(scope):
    vpp = scope.measure_vpp("CH1")
    assert 0 < vpp <= 3.6  # V