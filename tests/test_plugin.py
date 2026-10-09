"""Integration tests for Blendkit Godot plugin."""

import re

from .conftest import make_probe_project, run_editor_probe

# Quits once connected instead of after a fixed time.
CONNECT_PROBE = r"""
func check():
    var connection = find_gallery().plugin.connection
    if not connection.is_client_connected():
        await connection.connected
"""


def test_plugin_enables(godot_executable, tmp_path):
    """Plugin should enable, start or find the Client, and exit cleanly."""
    project = make_probe_project(tmp_path / "project", CONNECT_PROBE, with_client=True)
    stdout, stderr = run_editor_probe(godot_executable, project)
    output = stdout + stderr
    for pattern in (
        r"Blendkit: Plugin enabled",
        r"Blendkit: Searching for running Client\.\.\.",
        r"Blendkit: Connected to Client v[.0-9]+ on port \d+",
        r"Blendkit: Plugin exited",
    ):
        assert re.search(pattern, stdout), f"{pattern!r} not in output:\n{output}"
    assert "SCRIPT ERROR" not in stderr, output
