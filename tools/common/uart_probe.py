#!/usr/bin/env python3
"""uart_probe.py - minimal DUT UART probe over a subprocess (simulator DUT).

Spawns the compiled firmware artifact, waits for the boot banner, sends one
CLI command and prints the observed reply line as JSON:

    {"ok": true, "banner": [...], "command": "jedec", "reply": "JEDEC EF 40 18"}

Used by tools/acceptance-scenario.ps1 for the offline (simulator) leg of the
final acceptance scenario. Real-serial probing goes through Agentic HIL.
"""

import json
import subprocess
import sys
import time

REPLY_TOKENS = ("JEDEC", "PWM", "ERR")


def main() -> int:
    exe = sys.argv[1]
    command = sys.argv[2] if len(sys.argv) > 2 else "jedec"
    timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 8.0

    try:
        proc = subprocess.Popen(
            [exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", bufsize=1,
        )
    except OSError as exc:
        print(json.dumps({"ok": False, "error_class": "PROBE_NOT_FOUND",
                          "error": f"cannot spawn artifact: {exc}"}))
        return 2

    banner: list[str] = []
    deadline = time.monotonic() + timeout
    reply = None

    # read banner until it becomes quiet or the prompt command lands
    while time.monotonic() < deadline:
        try:
            line = proc.stdout.readline()
        except Exception:  # noqa: BLE001
            break
        if not line:
            break
        line = line.rstrip("\r\n")
        if not line:
            continue
        banner.append(line)
        if line.startswith("Application started"):
            break

    try:
        proc.stdin.write(command + "\n")
        proc.stdin.flush()
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"ok": False, "error_class": "UART_TIMEOUT",
                          "error": f"cannot write command: {exc}", "banner": banner}))
        proc.kill()
        return 1

    deadline = time.monotonic() + timeout
    collected: list[str] = []
    while time.monotonic() < deadline:
        try:
            line = proc.stdout.readline()
        except Exception:  # noqa: BLE001
            break
        if not line:
            break
        line = line.rstrip("\r\n")
        if not line:
            continue
        if line.startswith(("Bootloader ", "Application ")):
            continue
        collected.append(line)
        if line.startswith(REPLY_TOKENS):
            reply = line
            break

    proc.kill()
    try:
        proc.wait(timeout=3)
    except Exception:  # noqa: BLE001
        pass

    if reply is None:
        print(json.dumps({"ok": False, "error_class": "UART_TIMEOUT", "error": "no reply",
                          "banner": banner, "collected": collected}))
        return 1

    print(json.dumps({"ok": True, "banner": banner, "command": command,
                      "reply": reply, "collected": collected}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())