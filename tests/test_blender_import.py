"""Tests for the Blender Import dialog and finding Blender."""

import platform

import pytest

from .conftest import make_probe_project, run_editor_probe, run_godot_script


BLENDER_IMPORT_CHECKS = r"""extends SceneTree

const B = preload("res://addons/blendkit/blender_import.gd")

var failures := 0

func check(ok: bool, what: String) -> void:
    if not ok:
        failures += 1
        print("CHECK FAILED: " + what)

func _initialize():
    check(B.parse_version("Blender 4.5.1 LTS\n\tbuild date: 2025") == "4.5.1", "lts")
    check(B.parse_version("Read prefs\nBlender 5.0\n") == "5.0", "later line")
    check(B.parse_version("blender") == "", "no version")
    check(not B.is_supported(null), "checking")
    check(not B.is_supported(""), "not blender")
    check(not B.is_supported("2.93.1"), "too old")
    check(B.is_supported("3.0.0"), "minimum")
    check(B.compare_versions("4.10.0", "4.9.1"), "numeric")
    check(not B.compare_versions("4.2", "4.2.1"), "missing part is 0")
    check(B.real_path("/no/such/blender") == "/no/such/blender", "missing path kept")

    if failures == 0:
        print("BLENDER_IMPORT_CHECKS_PASSED")
    quit(failures)
"""


def test_blender_import_helpers(godot_executable, tmp_path):
    result = run_godot_script(godot_executable, tmp_path, BLENDER_IMPORT_CHECKS)
    output = result.stdout + result.stderr
    assert "BLENDER_IMPORT_CHECKS_PASSED" in result.stdout, output


BLENDER_IMPORT_PROBE = r"""
func check():
    var bk = find_gallery().plugin
    var menu = bk.gallery.find_children("*", "Button", true, false).filter(func(b): return b.has_method("status_color"))[0]
    var dialog = menu._settings._blender_import_dialog
    var apply = dialog.get_ok_button()
    dialog.popup_centered()
    await get_tree().process_frame
    print("LOADED=%s intro=%s apply=%s" % [dialog._selected(), dialog._intro.visible, not apply.disabled])
    if OS.get_environment("BK_BLENDER_IMPORT_RUN") == "1":
        print("NO_BLENDER=apply=%s %s" % [not apply.disabled, dialog._blender_note.text])
        dialog._set_path(OS.get_environment("BK_FAKE_BLENDER"))
        await wait_until(func(): return dialog._tasks.is_empty(), 20)
        print("BLENDER=apply=%s restart=%s %s" % [not apply.disabled, dialog._restart.visible, dialog._blender_note.text])
        apply.pressed.emit()
        await get_tree().process_frame
        print("APPLIED=%s %s" % [bk.BlenderImport.blend_import_enabled(), bk.BlenderImport.blender_path() == OS.get_environment("BK_FAKE_BLENDER")])
        dialog.popup_centered()
        await get_tree().process_frame
        print("REOPENED=%s" % dialog._selected())
        dialog._choices[dialog.Choice.DONT_IMPORT].button_pressed = true
        apply.pressed.emit()
        await get_tree().process_frame
        print("DONT=%s" % bk.BlenderImport.blend_import_enabled())
    else:
        dialog._choices[dialog.Choice.NATIVE].button_pressed = true
        await wait_until(func(): return dialog._tasks.is_empty(), 20)
        apply.pressed.emit()
        await get_tree().process_frame
        print("NATIVE=%s" % bk.BlenderImport.blend_import_enabled())
"""


@pytest.mark.skipif(platform.system() == "Windows", reason="fake Blender is a shell script")
def test_blender_import_dialog(godot_executable, tmp_path):
    """Native import needs a working Blender; Apply writes Godot's settings."""
    project = make_probe_project(tmp_path / "project", BLENDER_IMPORT_PROBE)
    fake = tmp_path / "bin" / "blender"
    fake.parent.mkdir()
    fake.write_text("#!/bin/sh\necho 'Blender 4.2.3 LTS'\necho '\tbuild date: x'\n")
    fake.chmod(0o755)
    home = tmp_path / "home"
    env = dict(
        XDG_CONFIG_HOME=str(home / "config"),
        XDG_DATA_HOME=str(home / "data"),
        APPDATA=str(home / "appdata"),
        BK_FAKE_BLENDER=str(fake),
        BK_BLENDER_IMPORT_RUN="1",
    )

    stdout, stderr = run_editor_probe(godot_executable, project, env)
    output = stdout + stderr
    assert "LOADED=1 intro=true apply=false" in stdout, output
    assert "NO_BLENDER=apply=false Not set." in stdout, output
    assert "BLENDER=apply=true restart=true Blender 4.2.3" in stdout, output
    assert "APPLIED=true true" in stdout, output
    assert "REOPENED=1" in stdout, output
    assert "DONT=false" in stdout, output
    assert "SCRIPT ERROR" not in stderr, output
    config = (project / "project.godot").read_text()
    assert "import/blender/enabled=false" in config, config

    env["BK_BLENDER_IMPORT_RUN"] = "2"
    stdout, stderr = run_editor_probe(godot_executable, project, env)
    output = stdout + stderr
    assert "LOADED=0 intro=false apply=true" in stdout, output
    assert "NATIVE=true" in stdout, output
    assert "SCRIPT ERROR" not in stderr, output
    config = (project / "project.godot").read_text()
    assert "import/blender/enabled" not in config, "default kept out"
