"""Pytest configuration and helpers for Blendkit Godot plugin tests."""

import json
import os
import platform
import re
import shutil
import subprocess
import threading
import time
import urllib.request
from pathlib import Path

import pytest


# Project root (where project.godot lives) - tests/ sits directly under it.
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = Path(PROJECT_DIR)
ADDON_DIR = ROOT / "addons" / "blendkit"

# Logged by client_connection.gd when the addon connects to the Blendkit Client.
CLIENT_CONNECTED_RE = re.compile(
    r"Connected to Client(?: v(?P<version>[\d.]+))? on port (?P<port>\d+)"
)


def client_log(output: str, lines: int = 80) -> str:
    """The end of the logs of the Client the editor connected to and the one
    started before it, e.g. one that crashed, for failures."""
    m = CLIENT_CONNECTED_RE.search(output)
    if not m:
        return ""
    # Like ClientConnection.get_client_log_path() and ClientBinary.previous_log_path().
    name = "default" if m.group("port") == "62485" else m.group("port")
    logs = ""
    for file in (f"{name}.previous.log", f"{name}.log"):
        path = Path.home() / "blenderkit_data" / "client" / file
        if not path.exists():
            continue
        try:
            tail = path.read_text(errors="replace").splitlines()[-lines:]
        except OSError as e:
            logs += f"\nClient log {path}: {e}"
            continue
        logs += f"\nClient log {path}:\n" + "\n".join(tail)
    return logs


def unsubscribe_client(port: str, app_id: int) -> None:
    """Remove only the test editor's subscription; other plugins may share it."""
    if not port:
        return
    try:
        urllib.request.urlopen(
            f"http://127.0.0.1:{port}/addons/unsubscribe",
            data=json.dumps({"app_id": app_id}).encode(),
            timeout=5,
        ).close()
    except OSError:
        pass


def find_godot_executable() -> str:
    """Find the Godot executable."""
    # Prefer explicit env vars (e.g. set by chickensoft-games/setup-godot).
    # On Windows the action symlinks the binary without a `.exe` extension,
    # so shutil.which() can't find it - but it exports these paths.
    for env in ["GODOT4", "GODOT"]:
        path = os.environ.get(env)
        if path and os.path.isfile(path):
            return path
    # Try common names for Godot 4.x
    for name in ["godot", "godot4", "Godot", "Godot4"]:
        path = shutil.which(name)
        if path:
            return path
    raise RuntimeError(
        "Godot executable not found. "
        "Install Godot 4.x and ensure it's available as 'godot' or 'godot4' "
        "(or set the GODOT/GODOT4 environment variable)."
    )


@pytest.fixture(scope="session")
def godot_executable() -> str:
    """Return path to Godot executable."""
    return find_godot_executable()


def run_godot_script(godot_executable, tmp_path, source, env=None, timeout=30):
    """Run a SceneTree script in this project, without the editor."""
    script = tmp_path / "checks.gd"
    script.write_text(source)
    return subprocess.run(
        [
            godot_executable,
            "--headless",
            "--log-file",
            str(tmp_path / "godot.log"),
            "--path",
            PROJECT_DIR,
            "--script",
            str(script),
        ],
        capture_output=True,
        text=True,
        timeout=timeout,
        env={**os.environ, **(env or {})},
    )


# MARK: editor probes

# A probe is a second editor plugin that drives the Blendkit plugin and prints
# KEY=value lines for the test to check. It defines check(), which runs once
# the editor is up; the editor quits when it returns.
PROBE_HEADER = r"""@tool
extends EditorPlugin

func _enter_tree():
    _run.call_deferred()

func _run():
    await check()
    get_tree().quit()

func find_gallery():
    for child in EditorInterface.get_editor_main_screen().get_children():
        if child.name == "BlendkitGallery":
            return child

## Wait until [param condition] holds; false on timeout.
func wait_until(condition: Callable, timeout_s: float) -> bool:
    var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
    while not condition.call():
        if Time.get_ticks_msec() > deadline:
            return false
        await get_tree().process_frame
    return true

"""


def _client_binary_name() -> str:
    """Like ClientBinary.get_client_binary_name() for this machine."""
    system = {"Windows": "windows", "Darwin": "macos"}.get(platform.system(), "linux")
    machine = platform.machine().lower()
    arch = "arm64" if machine in ("arm64", "aarch64") else "x86_64"
    return f"bk_client-{system}-{arch}" + (".exe" if system == "windows" else "")


def _copy_client(target: Path) -> None:
    """Copy the bundled Client for this machine only (all platforms are ~60MB)."""
    source = ADDON_DIR / "client"
    if not source.is_dir():
        pytest.skip("No bundled Client; run ./dev.py build first")
    binary = _client_binary_name()
    shutil.copytree(
        source,
        target,
        ignore=lambda _dir, names: [
            n for n in names if n.startswith("bk_client-") and n != binary
        ],
    )


def make_probe_project(
    path: Path, probe_source: str, settings: str = "", with_client: bool = False
) -> Path:
    """A project with the Blendkit plugin and a probe plugin enabled.

    [param probe_source] is appended to PROBE_HEADER, [param settings] to
    project.godot. Without the Client, the plugin can't start one.
    """
    shutil.copytree(
        ADDON_DIR, path / "addons" / "blendkit", ignore=shutil.ignore_patterns("client")
    )
    if with_client:
        _copy_client(path / "addons" / "blendkit" / "client")
    probe = path / "addons" / "probe"
    probe.mkdir()
    (probe / "plugin.cfg").write_text(
        '[plugin]\nname="probe"\ndescription=""\nauthor=""\nversion="0"\nscript="probe.gd"\n'
    )
    (probe / "probe.gd").write_text(PROBE_HEADER + probe_source)
    (path / "project.godot").write_text(
        'config_version=5\n\n[application]\n\nconfig/name="Blendkit test"\n\n'
        "[editor_plugins]\n\nenabled=PackedStringArray("
        '"res://addons/blendkit/plugin.cfg", "res://addons/probe/plugin.cfg")\n\n'
        + settings
    )
    return path


class GodotEditor:
    """A headless editor whose output is collected while it runs."""

    def __init__(self, godot_executable, project: Path, env=None):
        self.process = subprocess.Popen(
            [godot_executable, "--headless", "--editor", "--path", str(project)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env={**os.environ, **(env or {})},
        )
        self.stdout_lines: list = []
        self.stderr_lines: list = []
        self._readers = [
            threading.Thread(target=self._read, args=(s, lines), daemon=True)
            for s, lines in (
                (self.process.stdout, self.stdout_lines),
                (self.process.stderr, self.stderr_lines),
            )
        ]
        for reader in self._readers:
            reader.start()

    @staticmethod
    def _read(stream, lines):
        for line in stream:
            lines.append(line)

    @property
    def stdout(self) -> str:
        return "".join(self.stdout_lines)

    @property
    def stderr(self) -> str:
        return "".join(self.stderr_lines)

    @property
    def output(self) -> str:
        return self.stdout + self.stderr

    def wait_for(self, pattern: str, timeout: float) -> re.Match:
        """Wait for a stdout line matching [param pattern]."""
        regex = re.compile(pattern)
        deadline = time.time() + timeout
        seen = 0
        while time.time() < deadline:
            lines = self.stdout_lines[seen:]
            for line in lines:
                m = regex.search(line)
                if m:
                    return m
            seen += len(lines)
            if self.process.poll() is not None and seen == len(self.stdout_lines):
                break
            time.sleep(0.1)
        raise AssertionError(
            f"No output matching {pattern!r} within {timeout}s.\n{self.output}"
        )

    def wait(self, timeout: float) -> None:
        """Wait for the editor to quit, killing it on timeout."""
        try:
            self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.close()
            raise AssertionError(f"Editor still ran after {timeout}s.\n{self.output}")
        for reader in self._readers:
            reader.join(timeout=5)

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        for reader in self._readers:
            reader.join(timeout=5)
        # Remove this editor without terminating a shared Client.
        m = CLIENT_CONNECTED_RE.search(self.stdout)
        if m:
            unsubscribe_client(m.group("port"), self.process.pid)

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()


def run_editor_probe(godot_executable, project: Path, env=None, timeout=60):
    """Run the probe project's editor until the probe quits it.

    Returns stdout and stderr.
    """
    with GodotEditor(godot_executable, project, env) as editor:
        editor.wait(timeout)
    return editor.stdout, editor.stderr
