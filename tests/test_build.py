"""Standalone client packaging checks, without downloads or Go compilation."""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import zipfile

import pytest

SPEC = importlib.util.spec_from_file_location(
    "dev", Path(__file__).parents[1] / "dev.py"
)
dev = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dev)


@pytest.fixture
def workspace(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    plugin = tmp_path / "addons/blendkit"
    plugin.mkdir(parents=True)
    (plugin / "plugin.gd").write_text('const CLIENT_API_VERSION = "v1.12"\n')
    (plugin / "plugin.cfg").write_text('[plugin]\nversion="1.0.0"\n')
    (tmp_path / "LICENSE").write_text("License\n")
    return plugin


def bundle_bytes(
    version="1.12.13", missing=None, corrupt=None, manifest_version=None, only=None
):
    files = {
        name: (name + version).encode()
        for name in dev.CLIENT_BINARIES
        if name != missing and (only is None or name == only)
    }
    manifest = {
        "name": "bk_client",
        "version": manifest_version or version,
        "binaries": [
            {
                "filename": name,
                "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
            for name, data in files.items()
        ],
    }
    if corrupt:
        files[corrupt] = b"corrupt"
    files.update(
        {
            "VERSION": version.encode(),
            "manifest.json": json.dumps(manifest).encode(),
            "../escape": b"do not extract",
            "tools/test.py": b"embedded",
        }
    )
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as zf:
        for name, data in files.items():
            zf.writestr(name, data)
    return output.getvalue()


def write_bundle(tmp_path, **kwargs):
    path = tmp_path / "bk_client.zip"
    path.write_bytes(bundle_bytes(**kwargs))
    return path


def test_bundle_install_and_archive(workspace, tmp_path):
    dev.build(client_bundle=write_bundle(tmp_path))
    root = workspace / "client"
    assert (root / "RESOLVED_VERSION").read_text() == "v1.12.13\n"
    assert {p.name for p in root.iterdir()} == {"RESOLVED_VERSION", "v1.12.13"}
    assert not (root / "escape").exists()
    assert not (root / "v1.12.13/tools").exists()
    with zipfile.ZipFile("out/blendkit-godot_v1.0.0.zip") as zf:
        for name in dev.CLIENT_BINARIES:
            info = zf.getinfo(f"addons/blendkit/client/v1.12.13/{name}")
            if os.name != "nt":
                assert info.external_attr >> 16 & 0o111


@pytest.mark.parametrize(
    "bad",
    [
        {"missing": "bk_client-linux-arm64"},
        {"corrupt": "bk_client-linux-x86_64"},
        {"manifest_version": "1.12.14"},
        {"version": "1.13.0"},
    ],
)
def test_invalid_bundle_preserves_install(workspace, tmp_path, bad):
    path = write_bundle(tmp_path)
    dev.install_client_bundle(path)
    old = {
        str(p.relative_to(workspace)): p.read_bytes()
        for p in workspace.rglob("*")
        if p.is_file()
    }
    path.write_bytes(bundle_bytes(**bad))
    with pytest.raises(ValueError):
        dev.install_client_bundle(path)
    assert old == {
        str(p.relative_to(workspace)): p.read_bytes()
        for p in workspace.rglob("*")
        if p.is_file()
    }


def test_empty_manifest_and_release_mismatch(workspace, tmp_path):
    path = write_bundle(tmp_path)
    with pytest.raises(ValueError, match="does not match"):
        dev.install_client_bundle(path, expected_version="v1.12.14")
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("VERSION", "1.12.13")
        zf.writestr(
            "manifest.json",
            json.dumps({"name": "bk_client", "version": "1.12.13", "binaries": []}),
        )
    with pytest.raises(ValueError, match="Missing client binaries"):
        dev.install_client_bundle(path)
    assert not (workspace / "client").exists()


def test_archive_revalidates_binaries(workspace, tmp_path):
    dev.install_client_bundle(write_bundle(tmp_path))
    (workspace / "client/v1.12.13/bk_client-linux-arm64").write_bytes(b"changed")
    with pytest.raises(ValueError, match="checksum"):
        dev.build_archive()


def test_cache_isolated_by_tag(workspace, monkeypatch):
    downloads = []
    monkeypatch.setattr(
        dev,
        "fetch_release_meta",
        lambda tag: {
            "tag_name": tag,
            "assets": [{"name": "bk_client.zip", "browser_download_url": tag}],
        },
    )

    def download(tag, destination):
        downloads.append(tag)
        Path(destination).write_bytes(bundle_bytes(version=tag[1:]))

    monkeypatch.setattr(dev, "download_file", download)
    for tag in ["v1.12.9", "v1.12.13", "v1.12.9"]:
        dev.get_client_release(tag)
        assert (workspace / "client/RESOLVED_VERSION").read_text().strip() == tag
    assert downloads == ["v1.12.9", "v1.12.13"]


def test_release_selection_numeric_stable_series(workspace, monkeypatch):
    releases = [
        {"tag_name": "v1.12.9"},
        {"tag_name": "v1.12.13"},
        {"tag_name": "v1.13.0"},
        {"tag_name": "v1.12.15", "draft": True},
        {"tag_name": "v1.12.16", "prerelease": True},
        {"tag_name": "ci-test-99"},
    ]
    monkeypatch.setattr(
        dev.urllib.request,
        "urlopen",
        lambda *a, **k: io.BytesIO(json.dumps(releases).encode()),
    )
    assert dev.fetch_release_meta()["tag_name"] == "v1.12.13"


def test_local_source_uses_exact_version_bundle(workspace, tmp_path, monkeypatch):
    source = tmp_path / "source checkout"
    (source / "client").mkdir(parents=True)
    (source / "client/VERSION").write_text("1.12.13")

    def compile_client(command, cwd, check):
        assert command[1:] == ["dev.py", "build"]
        assert cwd == str(source) and check
        output = source / "out/v1.12.13"
        output.mkdir(parents=True)
        (output / "bk_client.zip").write_bytes(
            bundle_bytes(only=dev.host_client_binary())
        )

    monkeypatch.setattr(dev.subprocess, "run", compile_client)
    dev.build(from_source=True, client_dir=str(source))
    assert (workspace / "client/RESOLVED_VERSION").read_text() == "v1.12.13\n"
    assert list(Path("out").glob("*_local-*.zip"))
    with pytest.raises(ValueError, match="Missing client binaries"):
        dev.build_archive()


def test_failed_replace_rolls_back(workspace, tmp_path, monkeypatch):
    path = write_bundle(tmp_path)
    dev.install_client_bundle(path)
    path.write_bytes(bundle_bytes(version="1.12.14"))
    replace = dev.os.replace

    def fail_install(src, dst):
        if Path(src).name == "client":
            raise OSError("installation failed")
        return replace(src, dst)

    monkeypatch.setattr(dev.os, "replace", fail_install)
    with pytest.raises(OSError, match="installation failed"):
        dev.install_client_bundle(path)
    assert (workspace / "client/RESOLVED_VERSION").read_text() == "v1.12.13\n"
