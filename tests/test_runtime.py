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
    var binary_script = load("res://addons/blendkit/client_binary.gd")
    var connection_script = load("res://addons/blendkit/client_connection.gd")
    assert(binary_script.is_compatible_client("1.13.13", "1.13.13"))
    assert(binary_script.is_compatible_client("1.13.23", "1.13.13"))
    assert(not binary_script.is_compatible_client("1.13.9", "1.13.13"))
    assert(not binary_script.is_compatible_client("1.14.0", "1.13.13"))
    assert(not binary_script.is_compatible_client("2.13.0", "1.13.13"))
    assert(not binary_script.is_compatible_client("", "1.13.13"))
    assert(not binary_script.is_valid_client_version("1.13.13/../bad"))
    var report = {"tasks": [{"task_type": "login", "result": {"access_token": "a", "refresh_token": "r", "expires_in": 5}}]}
    var redacted = JSON.stringify(connection_script.redact(report))
    assert(not redacted.contains('"a"') and not redacted.contains('"r"') and redacted.contains("expires_in"))
    assert(report.tasks[0].result.access_token == "a")
    var base = %s
    var binary = binary_script.get_client_binary_name()
    assert(binary.begins_with("bk_client-"))
    for version in ["v1.13.9", "v1.13.13", "v1.14.0", "v1.13.999", "vgarbage"]:
        var directory = base.path_join(version)
        DirAccess.make_dir_recursive_absolute(directory)
        if version != "v1.13.999":
            var file = FileAccess.open(directory.path_join(binary), FileAccess.WRITE)
            file.store_string("test")
            file.close()
    var versions = binary_script.list_client_versions(base)
    assert(versions.size() == 2)
    assert(binary_script.pick_highest_version(versions) == "1.13.13")
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
