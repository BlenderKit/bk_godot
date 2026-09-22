#!/usr/bin/env python3
import argparse
import configparser
import fnmatch
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile


# Ensure UTF-8 output so Unicode (e.g. ✓) prints on Windows, where stdout
# defaults to a legacy code page (cp1252) that can't encode it.
for _stream in (sys.stdout, sys.stderr):
    reconfigure = getattr(_stream, "reconfigure", None)
    if reconfigure is not None:
        reconfigure(encoding="utf-8")


PLUGIN_SRC_DIR = "addons"
PLUGIN_DIR = "blendkit"
CLIENT_DIR = "bk_client"
CLIENT_REPO_URL = "https://github.com/BlenderKit/bk_client.git"
CLIENT_REPO_REF = "main"
CLIENT_REPO = "BlenderKit/bk_client"
CLIENT_ASSET = "bk_client.zip"
CLIENT_BINARIES = {
    f"bk_client-{platform}-{arch}{suffix}"
    for platform, suffix in (("windows", ".exe"), ("macos", ""), ("linux", ""))
    for arch in ("x86_64", "arm64")
}
GITHUB_API = "https://api.github.com"
CLIENT_DIST_DIR = "client-dist"
USER_AGENT = "blendkit-godot-build"
RESULT_DIR = "out"
ARCHIVE_BASE_NAME = "blendkit-godot"
PLUGIN_CLIENT_DIR = os.path.join(PLUGIN_SRC_DIR, PLUGIN_DIR, "client")

ARCHIVE_EXCLUDE = []


def ensure_godot_ignore(ignore_dir: str):
    """Ensure a .gdignore file exists in the directory (tells Godot to ignore it)."""
    gdignore_path = os.path.join(ignore_dir, ".gdignore")
    if os.path.exists(gdignore_path):
        return
    os.makedirs(ignore_dir, exist_ok=True)
    with open(gdignore_path, "w"):
        pass  # empty file is sufficient
    print(f"Created {gdignore_path}")


def build(
    from_source=False,
    client_bundle=None,
    tag=None,
    client_dir=CLIENT_DIR,
    result_dir=RESULT_DIR,
    dist_dir=CLIENT_DIST_DIR,
):
    """Build the Plugin and create archive.

    By default downloads signed client binaries from a published GitHub release.
    With --from-source, clones and compiles the client from source instead.
    """
    if client_bundle and (from_source or tag):
        raise ValueError(
            "--client-bundle cannot be combined with --from-source or --tag"
        )
    if from_source and tag:
        raise ValueError("--tag applies only to downloaded releases")
    if client_bundle:
        install_client_bundle(client_bundle)
    elif from_source:
        build_client(client_dir=client_dir)
        build_plugin(client_dir=client_dir)
    else:
        get_client_release(tag=tag, dist_dir=dist_dir)
    build_archive(result_dir=result_dir, allow_partial_client=from_source)


def get_client_src():
    """Clone Blendkit Client repository if it doesn't exist."""
    print("# Getting Blendkit Client sources")
    if os.path.exists(CLIENT_DIR):
        print(f"Client Repo already exists at {CLIENT_DIR}, skipping.")
    else:
        print(f"Cloning Client Repo to {CLIENT_DIR} (ref: {CLIENT_REPO_REF})...")
        subprocess.run(
            ["git", "clone", CLIENT_REPO_URL, CLIENT_DIR],
            check=True,
        )
        subprocess.run(
            ["git", "-C", CLIENT_DIR, "checkout", CLIENT_REPO_REF],
            check=True,
        )
    ensure_godot_ignore(CLIENT_DIR)


def github_request(url):
    """Open an authenticated GitHub request (uses GITHUB_TOKEN if set)."""
    headers = {"User-Agent": USER_AGENT}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return urllib.request.Request(url, headers=headers)


def client_api_version():
    """Use the runtime's supported API series as the build pin."""
    with open(os.path.join(PLUGIN_SRC_DIR, PLUGIN_DIR, "plugin.gd")) as f:
        match = re.search(
            r'^const CLIENT_API_VERSION = "(v\d+\.\d+)"', f.read(), re.MULTILINE
        )
    if not match:
        raise ValueError("Missing CLIENT_API_VERSION in plugin.gd")
    return match[1]


def validate_client_version(tag):
    if not isinstance(tag, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError(f"Invalid client version: {tag!r}")
    if tag.rsplit(".", 1)[0] != client_api_version():
        raise ValueError(f"Client {tag} is incompatible with {client_api_version()}")
    return tag


def fetch_release_meta(tag=None):
    """Resolve the newest stable patch in the supported series, or an exact tag."""
    base = f"{GITHUB_API}/repos/{CLIENT_REPO}/releases"
    if tag:
        validate_client_version(tag)
        with urllib.request.urlopen(
            github_request(f"{base}/tags/{tag}"), timeout=60
        ) as resp:
            release = json.load(resp)
        if (
            release.get("draft")
            or release.get("prerelease")
            or release["tag_name"] != tag
        ):
            raise ValueError(f"Not a stable release: {tag}")
        return release
    candidates = []
    page = 1
    while True:
        with urllib.request.urlopen(
            github_request(f"{base}?per_page=100&page={page}"), timeout=60
        ) as resp:
            releases = json.load(resp)
        for release in releases:
            if release.get("draft") or release.get("prerelease"):
                continue
            try:
                validate_client_version(release.get("tag_name"))
            except ValueError:
                continue
            candidates.append(release)
        if len(releases) < 100:
            break
        page += 1
    if not candidates:
        raise ValueError(f"No stable {client_api_version()} release found")
    return max(candidates, key=lambda r: tuple(map(int, r["tag_name"][1:].split("."))))


def download_file(url, dest):
    """Only publish a cache entry after its download completes."""
    print(f"Downloading {url}")
    partial = dest + ".part"
    try:
        with urllib.request.urlopen(github_request(url), timeout=60) as resp, open(
            partial, "wb"
        ) as f:
            shutil.copyfileobj(resp, f)
        os.replace(partial, dest)
    finally:
        if os.path.exists(partial):
            os.remove(partial)


def get_client_release(tag=None, dist_dir=CLIENT_DIST_DIR):
    meta = fetch_release_meta(tag)
    release_tag = validate_client_version(meta["tag_name"])
    assets = {a["name"]: a["browser_download_url"] for a in meta.get("assets", [])}
    if CLIENT_ASSET not in assets:
        raise ValueError(f"Release {release_tag} has no {CLIENT_ASSET}")
    ensure_godot_ignore(dist_dir)
    cache_dir = os.path.join(dist_dir, release_tag)
    os.makedirs(cache_dir, exist_ok=True)
    zip_path = os.path.join(cache_dir, CLIENT_ASSET)
    if not os.path.isfile(zip_path):
        download_file(assets[CLIENT_ASSET], zip_path)
    print(f"Installing Client {release_tag} from {zip_path}")
    install_client_bundle(zip_path, expected_version=release_tag)


def validate_client_directory(directory, expected_version=None, require_all=True):
    """Check metadata and every manifest binary before installation or shipping."""
    with open(os.path.join(directory, "VERSION")) as f:
        version = validate_client_version("v" + f.read().strip())
    if expected_version is not None and version != expected_version:
        raise ValueError(f"Client VERSION {version} does not match {expected_version}")
    with open(os.path.join(directory, "manifest.json")) as f:
        manifest = json.load(f)
    if manifest.get("name") != "bk_client" or manifest.get("version") != version[1:]:
        raise ValueError("Client manifest name/version mismatch")
    seen = set()
    for entry in manifest.get("binaries", []):
        name = entry["filename"]
        if (
            name not in CLIENT_BINARIES | {"bk_client-windows7-x86_64.exe"}
            or name in seen
        ):
            raise ValueError(f"Unexpected or duplicate binary: {name}")
        seen.add(name)
        with open(os.path.join(directory, name), "rb") as f:
            digest = hashlib.sha256()
            size = 0
            for chunk in iter(lambda: f.read(1 << 20), b""):
                digest.update(chunk)
                size += len(chunk)
        if size != entry["size"] or digest.hexdigest() != entry["sha256"]:
            raise ValueError(f"Client checksum/size mismatch: {name}")
    present = {name for name in os.listdir(directory) if name.startswith("bk_client-")}
    if present != seen:
        raise ValueError("Client binaries do not match manifest entries")
    required = CLIENT_BINARIES if require_all else {host_client_binary()}
    if not required <= seen:
        raise ValueError(f"Missing client binaries: {sorted(required - seen)}")
    return version, seen


def host_client_binary():
    os_name = {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}.get(
        platform.system()
    )
    arch = platform.machine().lower()
    arch = {"amd64": "x86_64", "aarch64": "arm64"}.get(arch, arch)
    suffix = ".exe" if os_name == "windows" else ""
    name = f"bk_client-{os_name}-{arch}{suffix}"
    if name not in CLIENT_BINARIES:
        raise ValueError(f"Unsupported host platform: {name}")
    return name


def install_client_bundle(bundle, expected_version=None, require_all=True):
    """Stage an allowlisted bundle; keep the previous installation on failure."""
    parent = os.path.dirname(PLUGIN_CLIENT_DIR)
    os.makedirs(parent, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".client-stage-", dir=parent) as stage:
        unpacked = os.path.join(stage, "unpacked")
        os.mkdir(unpacked)
        allowed = CLIENT_BINARIES | {
            "bk_client-windows7-x86_64.exe",
            "VERSION",
            "manifest.json",
        }
        with zipfile.ZipFile(bundle) as zf:
            seen = set()
            for member in zf.infolist():
                if member.filename not in allowed:
                    continue
                if member.filename in seen or member.is_dir():
                    raise ValueError(
                        f"Duplicate/invalid bundle member: {member.filename}"
                    )
                seen.add(member.filename)
                with zf.open(member) as src, open(
                    os.path.join(unpacked, member.filename), "wb"
                ) as dst:
                    shutil.copyfileobj(src, dst)
        version, binaries = validate_client_directory(
            unpacked, expected_version, require_all
        )
        for name in binaries:
            os.chmod(os.path.join(unpacked, name), 0o755)
        staged_client = os.path.join(stage, "client")
        os.mkdir(staged_client)
        os.replace(unpacked, os.path.join(staged_client, version))
        with open(os.path.join(staged_client, "RESOLVED_VERSION"), "w") as f:
            f.write(version + "\n")
        sync_license()
        backup = os.path.join(stage, "previous")
        had_previous = os.path.exists(PLUGIN_CLIENT_DIR)
        if had_previous:
            os.replace(PLUGIN_CLIENT_DIR, backup)
        try:
            os.replace(staged_client, PLUGIN_CLIENT_DIR)
        except OSError:
            if had_previous:
                os.replace(backup, PLUGIN_CLIENT_DIR)
            raise
    print(f"✓ Installed {len(binaries)} Client {version} binaries")
    if not require_all:
        print("Local development bundle: unsigned; may support only this platform.")


def sync_license():
    plugin_license = os.path.join(PLUGIN_SRC_DIR, PLUGIN_DIR, "LICENSE")
    shutil.copy2("LICENSE", plugin_license)


def build_client(client_dir=CLIENT_DIR):
    """Build an unsigned, host-platform bundle from standalone client sources."""
    if client_dir == CLIENT_DIR:
        get_client_src()
    print("# Building local Client (unsigned)")
    try:
        subprocess.run([sys.executable, "dev.py", "build"], cwd=client_dir, check=True)
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(
            f"Client source build failed in {client_dir}; see the upstream error above. "
            "Use the default published-release build until the source build is fixed."
        ) from exc


def build_plugin(client_dir=CLIENT_DIR, client_bundle=None):
    """Install a local bundle, or the exact version built by the source checkout."""
    if client_bundle:
        install_client_bundle(client_bundle)
        return
    with open(os.path.join(client_dir, "client", "VERSION")) as f:
        version = validate_client_version("v" + f.read().strip())
    bundle = os.path.join(client_dir, "out", version, CLIENT_ASSET)
    install_client_bundle(bundle, expected_version=version, require_all=False)


def get_archive_base_name(version: str) -> str:
    """Generate archive base name from version string."""
    return f"{ARCHIVE_BASE_NAME}_v{version}"


def get_plugin_version() -> str:
    """Read plugin version from plugin.cfg."""
    config_path = os.path.join(PLUGIN_SRC_DIR, "blendkit", "plugin.cfg")
    config = configparser.ConfigParser()
    config.read(config_path)
    return config.get("plugin", "version").strip('"')


def set_plugin_version(version: str):
    """Update plugin version in plugin.cfg."""
    config_path = os.path.join(PLUGIN_SRC_DIR, "blendkit", "plugin.cfg")
    version = version.lstrip("v")
    print(f"# Setting version to {version} in {config_path}")

    with open(config_path, "r") as f:
        content = f.read()

    new_content = re.sub(
        r'^(version=)"[^"]*"', rf'\1"{version}"', content, flags=re.MULTILINE
    )

    with open(config_path, "w") as f:
        f.write(new_content)

    print(f"✓ Plugin version set to {version}")


def human_readable_size(size_bytes: int) -> str:
    """Convert bytes to human readable string."""
    for unit in ["B", "KB", "MB", "GB"]:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"


def copytree_ignore(directory, files):
    """Return list of files to ignore during copytree."""
    ignored = []
    for f in files:
        for pattern in ARCHIVE_EXCLUDE:
            if fnmatch.fnmatch(f, pattern):
                ignored.append(f)
                break
    return ignored


def find_plugin_client_bin_dir(require_all=True):
    with open(os.path.join(PLUGIN_CLIENT_DIR, "RESOLVED_VERSION")) as f:
        version = validate_client_version(f.read().strip())
    versions = [name for name in os.listdir(PLUGIN_CLIENT_DIR) if name.startswith("v")]
    if versions != [version]:
        raise ValueError("Expected exactly one installed client version")
    directory = os.path.join(PLUGIN_CLIENT_DIR, version)
    validate_client_directory(directory, version, require_all)
    return directory


def build_archive(result_dir=RESULT_DIR, allow_partial_client=False):
    """Create a filtered ZIP archive of the plugin."""
    print("# Creating Plugin archive")

    find_plugin_client_bin_dir(require_all=not allow_partial_client)

    plugin_version = get_plugin_version()
    archive_base_name = get_archive_base_name(plugin_version)
    if allow_partial_client:
        archive_base_name += "_local-" + host_client_binary().removeprefix(
            "bk_client-"
        ).removesuffix(".exe")
    plugin_out_dir = os.path.join(result_dir, PLUGIN_SRC_DIR)
    archive_base_path = os.path.join(result_dir, archive_base_name)
    archive_path = archive_base_path + ".zip"

    print(f"Plugin version: {plugin_version}")
    print(f"Excluding patterns: {', '.join(ARCHIVE_EXCLUDE)}")
    print()

    os.makedirs(result_dir, exist_ok=True)
    ensure_godot_ignore(result_dir)
    shutil.rmtree(plugin_out_dir, ignore_errors=True)

    # Copy with filtering
    plugin_src = os.path.join(PLUGIN_SRC_DIR, PLUGIN_DIR)
    plugin_dst = os.path.join(plugin_out_dir, PLUGIN_DIR)

    print(f"Copying Plugin (filtered): {plugin_src} -> {plugin_dst}")
    shutil.copytree(plugin_src, plugin_dst, ignore=copytree_ignore)

    print("Creating ZIP archive...")
    real_archive_path = shutil.make_archive(
        archive_base_path, "zip", result_dir, PLUGIN_SRC_DIR
    )
    if os.path.abspath(archive_path) != os.path.abspath(real_archive_path):
        raise RuntimeError(
            f"Archive path mismatch: expected {archive_path}, got {real_archive_path}"
        )

    archive_size = human_readable_size(os.path.getsize(archive_path))
    print("✓ Blendkit Godot plugin archive DONE \\o/")
    print(f"ZIP archive: {archive_path} ({archive_size})")


def clean():
    """Remove build artifacts."""
    print("# Cleaning build artifacts")

    if os.path.exists(RESULT_DIR):
        print(f"Removing: {RESULT_DIR}")
        shutil.rmtree(RESULT_DIR)

    if os.path.exists(CLIENT_DIST_DIR):
        print(f"Removing: {CLIENT_DIST_DIR}")
        shutil.rmtree(CLIENT_DIST_DIR)

    if os.path.exists(PLUGIN_CLIENT_DIR):
        print(f"Removing: {PLUGIN_CLIENT_DIR}")
        shutil.rmtree(PLUGIN_CLIENT_DIR)

    print("✓ Clean complete")


def test(verbose=False, filter=None):
    """Run pytest tests."""
    print("# Running tests")

    cmd = [sys.executable, "-m", "pytest"]

    if verbose:
        cmd.append("-v")
    if filter:
        cmd.extend(["-k", filter])

    result = subprocess.run(cmd)
    sys.exit(result.returncode)


def test_e2e(verbose=False, filter=None, headed=False):
    """Run the Playwright end-to-end test against the live BlenderKit site."""
    print("# Running end-to-end tests (live site, needs network + Playwright)")

    cmd = [sys.executable, "-m", "pytest", "-m", "e2e", "-rs"]

    if verbose:
        cmd.append("-v")
    if filter:
        cmd.extend(["-k", filter])

    env = os.environ.copy()
    if headed:
        env["HEADED"] = "1"

    result = subprocess.run(cmd, env=env)
    sys.exit(result.returncode)


### Command-Line Interface


# Show default argument values
class NiceHelpFormatter(
    argparse.RawTextHelpFormatter, argparse.ArgumentDefaultsHelpFormatter
):
    pass


parser = argparse.ArgumentParser(
    formatter_class=NiceHelpFormatter,
)
subparsers = parser.add_subparsers(
    title="commands",
    dest="command",
    help="Available commands",
)

# COMMAND: build
parser_build = subparsers.add_parser(
    "build",
    help="Full build from a published client release: download + plugin + archive.",
    description=(
        "Full build from a published Blendkit Client release:\n"
        "download signed client binaries, copy them into the plugin, "
        "create archive.\n"
        "To build the client from source instead, use the 'build-client', "
        "'build-plugin' and 'build-archive' commands."
    ),
    formatter_class=NiceHelpFormatter,
)
parser_build.set_defaults(func=build)
parser_build.add_argument(
    "-s",
    "--from-source",
    action="store_true",
    dest="from_source",
    help="Compile the client from source instead of using a published release.",
)
parser_build.add_argument(
    "-t",
    "--tag",
    type=str,
    default=None,
    dest="tag",
    help="Exact client tag (e.g. v1.12.13). Defaults to latest stable supported patch.",
)
parser_build.add_argument(
    "-d",
    "--dist-dir",
    type=str,
    default=CLIENT_DIST_DIR,
    dest="dist_dir",
    help="Directory for downloaded/extracted client releases.",
)
parser_build.add_argument(
    "-c",
    "--client-dir",
    type=str,
    default=CLIENT_DIR,
    dest="client_dir",
    help="Path to Blendkit Client sources (with --from-source).",
)
parser_build.add_argument(
    "-o",
    "--result-dir",
    type=str,
    default=RESULT_DIR,
    dest="result_dir",
    help="Output directory for the archive.",
)

parser_build.add_argument(
    "--client-bundle",
    help="Install a predownloaded bk_client.zip instead of downloading.",
)

# COMMAND: get-client-release
parser_get_client_release = subparsers.add_parser(
    "get-client-release",
    help="Download a published client release and install its binaries.",
    description=(
        "Download a published Blendkit Client release and copy its signed "
        "binaries into the plugin directory."
    ),
    formatter_class=NiceHelpFormatter,
)
parser_get_client_release.set_defaults(func=get_client_release)
parser_get_client_release.add_argument(
    "-t",
    "--tag",
    type=str,
    default=None,
    dest="tag",
    help="Exact client tag (e.g. v1.12.13). Defaults to latest stable supported patch.",
)
parser_get_client_release.add_argument(
    "-d",
    "--dist-dir",
    type=str,
    default=CLIENT_DIST_DIR,
    dest="dist_dir",
    help="Directory for downloaded/extracted client releases.",
)

# COMMAND: get-client-src
parser_get_client_src = subparsers.add_parser(
    "get-client-src",
    help="Get Blendkit Client sources.",
    description="Get Blendkit Client sources.",
    formatter_class=NiceHelpFormatter,
)
parser_get_client_src.set_defaults(func=get_client_src)

# COMMAND: build-client
parser_build_client = subparsers.add_parser(
    "build-client",
    help="Build Blendkit Client with GO.",
    description="Build Blendkit Client with GO in-place.",
    formatter_class=NiceHelpFormatter,
)
parser_build_client.set_defaults(func=build_client)
parser_build_client.add_argument(
    "-c",
    "--client-dir",
    type=str,
    default=CLIENT_DIR,
    dest="client_dir",
    help="Path to Blendkit Client sources.",
)

# COMMAND: build-plugin
parser_build_plugin = subparsers.add_parser(
    "build-plugin",
    help="Copy client binaries into plugin directory.",
    description="Copy client binaries into addons/blendkit/client/ (in-place).",
    formatter_class=NiceHelpFormatter,
)
parser_build_plugin.set_defaults(func=build_plugin)
parser_build_plugin.add_argument(
    "-c",
    "--client-dir",
    type=str,
    default=CLIENT_DIR,
    dest="client_dir",
    help="Path to Blendkit Client sources.",
)

parser_build_plugin.add_argument(
    "--client-bundle", help="Path to a prebuilt bk_client.zip."
)

# COMMAND: build-archive
parser_build_archive = subparsers.add_parser(
    "build-archive",
    help="Create filtered ZIP archive of the plugin.",
    description="Create filtered ZIP archive of the plugin (requires client binaries).",
    formatter_class=NiceHelpFormatter,
)
parser_build_archive.set_defaults(func=build_archive)
parser_build_archive.add_argument(
    "-o",
    "--result-dir",
    type=str,
    default=RESULT_DIR,
    dest="result_dir",
    help="Output directory for the archive.",
)

parser_build_archive.add_argument(
    "--allow-partial-client",
    action="store_true",
    help="Create a local development archive requiring only this host platform.",
)

# COMMAND: clean
parser_clean = subparsers.add_parser(
    "clean",
    help="Remove build artifacts (out/ and client binaries).",
    description="Remove build artifacts (out/ and client binaries).",
    formatter_class=NiceHelpFormatter,
)
parser_clean.set_defaults(func=clean)

# COMMAND: set-version
parser_set_version = subparsers.add_parser(
    "set-version",
    help="Set the plugin version in plugin.cfg.",
    description="Set the plugin version in plugin.cfg.",
    formatter_class=NiceHelpFormatter,
)
parser_set_version.set_defaults(func=set_plugin_version)
parser_set_version.add_argument(
    "version",
    type=str,
    help="Version string (e.g., 1.2.3 or v1.2.3).",
)

# COMMAND: test
parser_test = subparsers.add_parser(
    "test",
    help="Run pytest tests.",
    description="Run pytest tests for the plugin.",
    formatter_class=NiceHelpFormatter,
)
parser_test.set_defaults(func=test)
parser_test.add_argument(
    "-v",
    "--verbose",
    action="store_true",
    help="Verbose output.",
)
parser_test.add_argument(
    "-k",
    "--filter",
    type=str,
    dest="filter",
    help="Only run tests matching this expression.",
)

# COMMAND: test-e2e
parser_test_e2e = subparsers.add_parser(
    "test-e2e",
    help="Run the Playwright end-to-end test (live site, needs network).",
    description=(
        "Run the browser end-to-end test against blenderkit.com.\n"
        "Requires Playwright (pip install -r requirements-dev.txt && "
        "playwright install chromium) and network access.\n"
        "Set BLENDERKIT_API_KEY to download gated assets."
    ),
    formatter_class=NiceHelpFormatter,
)
parser_test_e2e.set_defaults(func=test_e2e)
parser_test_e2e.add_argument(
    "-v",
    "--verbose",
    action="store_true",
    help="Verbose output.",
)
parser_test_e2e.add_argument(
    "-k",
    "--filter",
    type=str,
    dest="filter",
    help="Only run tests matching this expression.",
)
parser_test_e2e.add_argument(
    "--headed",
    action="store_true",
    help="Run the browser visibly instead of headless.",
)


def main():
    args = parser.parse_args()

    if args.command is None:
        # Print help when no command is given for convenience
        parser.print_help()
        sys.exit(1)

    # Extract kwargs for command function, excluding parser internals
    kwargs = {k: v for k, v in vars(args).items() if k not in ("command", "func")}
    try:
        args.func(**kwargs)
    except (
        OSError,
        ValueError,
        KeyError,
        RuntimeError,
        subprocess.CalledProcessError,
        zipfile.BadZipFile,
    ) as exc:
        parser.exit(1, f"Error: {exc}\n")


if __name__ == "__main__":
    main()
