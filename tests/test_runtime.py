"""Exercise runtime version discovery with Godot's actual GDScript engine."""

import json
from pathlib import Path
import subprocess


def test_client_compatibility_and_discovery(godot_executable, tmp_path):
    root = Path(__file__).parents[1]
    script = tmp_path / "client_checks.gd"
    script.write_text(
        """extends SceneTree

func _initialize():
    var plugin = load("res://addons/blendkit/plugin.gd")
    assert(plugin.is_compatible_client("1.12.13", "1.12.13"))
    assert(plugin.is_compatible_client("1.12.23", "1.12.13"))
    assert(not plugin.is_compatible_client("1.12.9", "1.12.13"))
    assert(not plugin.is_compatible_client("1.13.0", "1.12.13"))
    assert(not plugin.is_compatible_client("2.12.0", "1.12.13"))
    assert(not plugin.is_compatible_client("", "1.12.13"))
    assert(not plugin.is_valid_client_version("1.12.13/../bad"))
    var base = %s
    var binary = plugin.get_client_binary_name()
    assert(binary.begins_with("bk_client-"))
    for version in ["v1.12.9", "v1.12.13", "v1.13.0", "v1.12.999", "vgarbage"]:
        var directory = base.path_join(version)
        DirAccess.make_dir_recursive_absolute(directory)
        if version != "v1.12.999":
            var file = FileAccess.open(directory.path_join(binary), FileAccess.WRITE)
            file.store_string("test")
            file.close()
    var versions = plugin.list_client_versions(base)
    assert(versions.size() == 2)
    assert(plugin.pick_highest_version(versions) == "1.12.13")
    print("CLIENT_RUNTIME_CHECKS_PASSED")
    quit()
"""
        % json.dumps(str(tmp_path / "client folders"))
    )
    result = subprocess.run(
        [
            godot_executable,
            "--headless",
            "--log-file",
            str(tmp_path / "godot.log"),
            "--path",
            str(root),
            "--script",
            str(script),
        ],
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "CLIENT_RUNTIME_CHECKS_PASSED" in result.stdout, (
        result.stdout + result.stderr
    )
    assert "SCRIPT ERROR" not in result.stderr
