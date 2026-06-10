"""Integration tests for Blendkit Godot plugin."""

import re


def assert_output(result, pattern: str, stream: str = "stdout"):
    """Assert that pattern matches in the specified output stream."""
    output = getattr(result, stream)
    assert re.search(pattern, output), (
        f"Expected pattern not found in Godot Output:\n{pattern}\nstdout:\n{result.stdout}\n\nstderr:\n{result.stderr}"
    )


class TestPluginLoads:
    """Test that the plugin loads correctly in Godot editor."""

    def test_plugin_enables(self, run_godot_editor):
        """Plugin should enable and log its initialization."""
        r = run_godot_editor()

        assert_output(r, r"Blendkit: Plugin enabled")
        assert_output(r, r"Blendkit: Searching for running Client\.\.\.")
        assert_output(r, r"Blendkit: Connected to Client v[.0-9]+ on port \d+")
        assert_output(r, r"Blendkit: Plugin exited")
