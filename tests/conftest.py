"""Pytest configuration and fixtures for Blendkit Godot plugin tests."""

import os
import re
import shutil
import subprocess
import threading
from dataclasses import dataclass, field

import pytest


# Project root (where project.godot lives) - tests/ sits directly under it.
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Logged by plugin.gd when the addon connects to the Blendkit Client.
CLIENT_CONNECTED_RE = re.compile(
    r"Connected to Client(?: v(?P<version>[\d.]+))? on port (?P<port>\d+)"
)


def find_godot_executable() -> str:
    """Find the Godot executable in PATH."""
    # Try common names for Godot 4.x
    for name in ["godot", "godot4", "Godot", "Godot4"]:
        path = shutil.which(name)
        if path:
            return path
    raise RuntimeError(
        "Godot executable not found in PATH. "
        "Install Godot 4.x and ensure it's available as 'godot' or 'godot4'."
    )


@pytest.fixture(scope="session")
def godot_executable() -> str:
    """Return path to Godot executable."""
    return find_godot_executable()


@pytest.fixture
def run_godot_editor(godot_executable):
    """Factory fixture to run Godot editor with given arguments."""

    def _run(
        *extra_args: str,
        timeout: int = 40,
        quit_after: int = 2000,
    ) -> subprocess.CompletedProcess:
        """Run Godot editor in headless mode."""
        cmd = [
            godot_executable,
            "--headless",
            "--editor",
            "--quit-after", str(quit_after),
            *extra_args,
        ]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)

    return _run


@dataclass
class RunningGodot:
    """A live, headless Godot editor with the plugin connected to the Client."""

    process: subprocess.Popen
    port: str
    client_version: str
    lines: list = field(default_factory=list)

    @property
    def output(self) -> str:
        return "".join(self.lines)


@pytest.fixture
def running_godot(godot_executable):
    """Launch a headless Godot editor and wait until the plugin connects to the Client.

    Unlike ``run_godot_editor`` (which runs Godot to completion), this keeps the
    editor running for the duration of the test so an external browser can reach
    the Client it spawned. The connected Client port is exposed on the yielded
    ``RunningGodot``. The editor is terminated on teardown.
    """
    proc = subprocess.Popen(
        [
            godot_executable,
            "--headless",
            "--editor",
            "--path", PROJECT_DIR,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    lines: list = []
    connected = threading.Event()
    info: dict = {}

    def _reader():
        for line in proc.stdout:
            lines.append(line)
            if not connected.is_set():
                m = CLIENT_CONNECTED_RE.search(line)
                if m:
                    info["port"] = m.group("port")
                    info["version"] = m.group("version") or ""
                    connected.set()

    reader = threading.Thread(target=_reader, daemon=True)
    reader.start()

    try:
        if not connected.wait(timeout=60):
            raise AssertionError(
                "Godot did not connect to the Client within 60s.\n"
                "Godot output:\n" + "".join(lines)
            )
        yield RunningGodot(
            process=proc,
            port=info["port"],
            client_version=info["version"],
            lines=lines,
        )
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
        reader.join(timeout=5)
