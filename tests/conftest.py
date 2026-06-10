"""Pytest configuration and fixtures for Blendkit Godot plugin tests."""

import shutil
import subprocess

import pytest


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
