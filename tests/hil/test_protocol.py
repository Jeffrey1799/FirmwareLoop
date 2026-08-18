"""Protocol tests - SPI flash JEDEC ID (Spec §19 example).

This is the primary defect carrier for the closed-loop repair demo: when the
driver is broken the reply is 'JEDEC FAIL n=...' or a short ID and this test
fails with structured expected/actual evidence.
"""


def test_spi_jedec(dut):
    dut.reset()
    reply = dut.command("jedec")
    assert reply is not None, "no reply to JEDEC command"
    parts = reply.split()
    assert parts[0] == "JEDEC", f"unexpected reply: {reply}"
    assert len(parts) - 1 == 3, f"expected JEDEC ID length == 3, actual {len(parts) - 1}: {reply}"