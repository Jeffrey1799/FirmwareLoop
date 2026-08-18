"""
test_mcp_server.py - Unit tests for FirmwareLoop Workflow MCP Server (v0.0.4).
"""

import json
import os
import sys
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, REPO_ROOT)

from tools import fw_mcp_server


def test_mcp_initialize():
    req = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "test-client", "version": "1.0.0"}
        }
    }
    res = fw_mcp_server.process_request(req)
    assert res is not None
    assert res["id"] == 1
    assert res["result"]["serverInfo"]["name"] == "firmwareloop"
    assert res["result"]["serverInfo"]["version"] == "0.0.4"
    assert "tools" in res["result"]["capabilities"]


def test_mcp_tools_list():
    req = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list",
        "params": {}
    }
    res = fw_mcp_server.process_request(req)
    assert res is not None
    assert res["id"] == 2
    tools = res["result"]["tools"]
    tool_names = [t["name"] for t in tools]

    expected_tools = [
        "fw_doctor",
        "fw_configure_lab",
        "fw_scan_hardware",
        "fw_build",
        "fw_flash",
        "fw_reset",
        "fw_run_hil_test",
        "fw_acceptance_scenario",
        "fw_measure",
        "fw_logic_capture",
        "fw_logic_decode",
        "fw_get_evidence",
    ]
    for exp in expected_tools:
        assert exp in tool_names, f"Expected tool {exp} in tools/list"


def test_mcp_call_unknown_tool():
    req = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": "non_existent_tool",
            "arguments": {}
        }
    }
    res = fw_mcp_server.process_request(req)
    assert res is not None
    assert "error" in res
    assert res["error"]["code"] == -32601


def test_mcp_call_fw_measure_simulator():
    req = {
        "jsonrpc": "2.0",
        "id": 4,
        "method": "tools/call",
        "params": {
            "name": "fw_measure",
            "arguments": {
                "instrument_type": "scope",
                "command": "measure-frequency",
                "instrument_name": "scope1",
                "backend": "simulator"
            }
        }
    }
    res = fw_mcp_server.process_request(req)
    assert res is not None
    assert "result" in res
    content = res["result"]["content"]
    assert len(content) > 0
    data = json.loads(content[0]["text"])
    assert data.get("ok") is True
    assert data.get("measurement") == "frequency"
    assert data.get("value") == 20000.0
    assert data.get("unit") == "Hz"
    assert data.get("simulated") is True


def test_mcp_call_fw_build_dry_run():
    req = {
        "jsonrpc": "2.0",
        "id": 5,
        "method": "tools/call",
        "params": {
            "name": "fw_build",
            "arguments": {
                "backend": "cmake",
                "dry_run": True
            }
        }
    }
    res = fw_mcp_server.process_request(req)
    assert res is not None
    assert "result" in res
    content = res["result"]["content"]
    data = json.loads(content[0]["text"])
    assert data.get("ok") is True
    assert data.get("dry_run") is True
    assert "command" in data


def test_mcp_call_fw_configure_lab():
    req = {
        "jsonrpc": "2.0",
        "id": 6,
        "method": "tools/call",
        "params": {
            "name": "fw_configure_lab",
            "arguments": {
                "project_name": "Test_STM32_Project",
                "build_backend": "keil",
                "target_chip": "STM32F103C8",
                "uart_port": "COM5",
                "uart_baudrate": 115200
            }
        }
    }
    res = fw_mcp_server.process_request(req)
    assert res is not None
    assert "result" in res
    content = res["result"]["content"]
    data = json.loads(content[0]["text"])
    assert data.get("ok") is True
    assert "project.build_backend" in data.get("updated_fields", [])
    assert data.get("config", {}).get("project", {}).get("build_backend") == "keil"
    assert data.get("config", {}).get("project", {}).get("target_chip") == "STM32F103C8"


def test_mcp_call_fw_scan_hardware():
    req = {
        "jsonrpc": "2.0",
        "id": 7,
        "method": "tools/call",
        "params": {
            "name": "fw_scan_hardware",
            "arguments": {
                "adopt": False
            }
        }
    }
    res = fw_mcp_server.process_request(req)
    assert res is not None
    assert "result" in res
    content = res["result"]["content"]
    data = json.loads(content[0]["text"])
    assert data.get("ok") is True
    assert "probes" in data
    assert "com_ports" in data


def test_mcp_call_fw_flash_and_reset_simulator():
    # Flash
    flash_req = {
        "jsonrpc": "2.0",
        "id": 8,
        "method": "tools/call",
        "params": {
            "name": "fw_flash",
            "arguments": {
                "backend": "simulator",
                "artifact_path": "artifacts/build/firmware.elf"
            }
        }
    }
    flash_res = fw_mcp_server.process_request(flash_req)
    assert flash_res is not None
    flash_data = json.loads(flash_res["result"]["content"][0]["text"])
    assert flash_data.get("ok") is True

    # Reset
    reset_req = {
        "jsonrpc": "2.0",
        "id": 9,
        "method": "tools/call",
        "params": {
            "name": "fw_reset",
            "arguments": {
                "backend": "simulator"
            }
        }
    }
    reset_res = fw_mcp_server.process_request(reset_req)
    assert reset_res is not None
    reset_data = json.loads(reset_res["result"]["content"][0]["text"])
    assert reset_data.get("ok") is True
