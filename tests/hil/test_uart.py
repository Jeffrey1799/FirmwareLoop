"""UART tests (Spec M3: test_basic_uart)."""


def test_basic_uart_echo(dut):
    """Write 'echo <token>' and expect the token back (round-trip)."""
    dut.reset()
    reply = dut.command("echo hello-hil")
    assert reply == "hello-hil"


def test_uart_unknown_command_returns_err(dut):
    """Unknown CLI commands must produce a structured ERR reply, not silence."""
    dut.reset()
    reply = dut.command("no-such-command")
    assert reply == "ERR"