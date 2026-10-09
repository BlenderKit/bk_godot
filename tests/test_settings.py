"""Tests for the Blendkit settings stored in project and editor settings."""

import os
import re
import shutil
import subprocess

from .conftest import PROJECT_DIR, unsubscribe_client
from pathlib import Path

ROOT = Path(PROJECT_DIR)


SETTINGS_PROBE = r"""@tool
extends EditorPlugin

func _enter_tree():
    check.call_deferred()

func plugin():
    for child in EditorInterface.get_editor_main_screen().get_children():
        if child.name == "BlendkitGallery":
            return child.plugin
    return null

func check():
    var bk = plugin()
    print("VALUES=%s|%s|%s|%s|%s|%s" % [bk.download_dir, bk.model_format, bk.resolution, bk.preferred_port, bk.log_level, bk.client_enabled])
    if OS.get_environment("BK_SETTINGS_RUN") == "1":
        bk.set_model_format("blend")
        bk.set_resolution("resolution_2K")
        bk.set_preferred_port("65425")
        bk.set_log_level(bk.LogLevel.VERBOSE)
        bk.set_client_enabled(false)
        # Like an edit in Project Settings.
        ProjectSettings.set_setting(bk.SETTING_DOWNLOAD_DIR, "res://assets/bk")
        await get_tree().process_frame
        await get_tree().process_frame
        print("APPLIED=%s" % bk.download_dir)
    else:
        var dialog = bk.gallery.find_children("*", "AcceptDialog", true, false).filter(func(d): return d.title == "Blendkit Settings")[0]
        dialog.popup_centered()
        dialog._browse_download_dir()
        dialog._on_download_dir_selected("res://picked")
        print("PICKED=%s %s" % [dialog._download_dir_dialog.visible, bk.download_dir])
    get_tree().quit()
"""


def run_editor(godot_executable, project, env):
    with subprocess.Popen(
        [godot_executable, "--headless", "--editor", "--path", str(project)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    ) as proc:
        try:
            stdout, stderr = proc.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            raise
    m = re.search(r"Connected to Client(?: v[\d.]+)? on port (\d+)", stdout)
    if m:
        unsubscribe_client(m.group(1), proc.pid)
    return stdout, stderr


def test_settings_persist(godot_executable, tmp_path):
    """Settings migrate from the old keys and survive an editor restart."""
    project = tmp_path / "project"
    shutil.copytree(
        ROOT / "addons" / "blendkit",
        project / "addons" / "blendkit",
        ignore=shutil.ignore_patterns("client"),
    )
    probe = project / "addons" / "probe"
    probe.mkdir()
    (probe / "plugin.cfg").write_text(
        '[plugin]\nname="probe"\ndescription=""\nauthor=""\nversion="0"\nscript="probe.gd"\n'
    )
    (probe / "probe.gd").write_text(SETTINGS_PROBE)
    (project / "project.godot").write_text(
        "config_version=5\n\n[application]\n\nconfig/name=\"Settings test\"\n\n"
        '[blendkit]\n\nmodel_format="gltf_godot"\nresolution=""\n\n'
        "[editor_plugins]\n\nenabled=PackedStringArray("
        '"res://addons/blendkit/plugin.cfg", "res://addons/probe/plugin.cfg")\n'
    )
    # Keep the editor settings away from the user's own.
    home = tmp_path / "home"
    env = dict(os.environ)
    env.update(
        XDG_CONFIG_HOME=str(home / "config"),
        XDG_DATA_HOME=str(home / "data"),
        XDG_CACHE_HOME=str(home / "cache"),
        APPDATA=str(home / "appdata"),
        BK_SETTINGS_RUN="1",
    )

    stdout, stderr = run_editor(godot_executable, project, env)
    output = stdout + stderr
    assert "VALUES=res://bk_assets/|gltf_godot||62485|2|true" in stdout, output
    assert "APPLIED=res://assets/bk" in stdout, output
    assert "SCRIPT ERROR" not in stderr, output
    config = (project / "project.godot").read_text()
    assert "\nmodel_format=" not in config, config
    assert 'downloads/model_format="blend"' not in config, "default kept out"
    assert 'downloads/resolution="resolution_2K"' in config, config
    assert 'downloads/directory="res://assets/bk"' in config, config

    env["BK_SETTINGS_RUN"] = "2"
    stdout, stderr = run_editor(godot_executable, project, env)
    output = stdout + stderr
    assert "VALUES=res://assets/bk|blend|resolution_2K|65425|3|false" in stdout, output
    assert "Searching for running Client" not in stdout, output
    assert "PICKED=true res://picked" in stdout, output
    assert "SCRIPT ERROR" not in stderr, output
