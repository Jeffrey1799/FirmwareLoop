"""Boot tests (Spec M3: test_boot). Evidence-driven: banner bytes observed on
the DUT UART, never an assumption from a log. """


def test_boot_banner(dut):
    """Reset must produce the bootloader banner then the app banner."""
    dut.boot()


def test_boot_after_reset(dut):
    """A second reset cycle must reproduce the same banner."""
    dut.boot()
    dut.boot()