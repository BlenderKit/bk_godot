#!/usr/bin/env python3
import argparse
import configparser
import fnmatch
import os
import re
import shutil
import subprocess
import sys


PLUGIN_SRC_DIR = "addons"
PLUGIN_DIR = "blendkit"
CLIENT_DIR = "BlenderKit"
CLIENT_REPO_URL = "https://github.com/BlenderKit/BlenderKit.git"
CLIENT_REPO_REF = "main"
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
    with open(gdignore_path, "w") as f:
        pass  # empty file is sufficient
    print(f"Created {gdignore_path}")


def build(client_dir=CLIENT_DIR, result_dir=RESULT_DIR):
    """Build Blendkit Client and Plugin, then create archive."""
    build_client(client_dir=client_dir)
    build_plugin(client_dir=client_dir)
    build_archive(result_dir=result_dir)


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


def build_client(client_dir=CLIENT_DIR):
    """Build Blendkit Client using its dev.py build script."""
    if client_dir == CLIENT_DIR:
        get_client_src()
    print("# Building Blendkit Client with GO")
    subprocess.run(
        ["python3", "dev.py", "build"],
        cwd=client_dir,
        check=True,
    )


def copy_client_binaries(binaries_path: str, result_dir=RESULT_DIR):
    """Copy client binaries from source path to result directory."""
    print(f"Copying Client binaries: {binaries_path} -> {result_dir}")
    if not os.path.exists(binaries_path):
        print(f"Client binaries path {binaries_path} does not exist, exiting.")
        sys.exit(1)
    if not os.path.isdir(binaries_path):
        print(f"Client binaries path {binaries_path} is not a directory, exiting.")
        sys.exit(1)

    client_version = os.path.basename(os.path.normpath(binaries_path))
    target_dir = os.path.join(result_dir, "client", client_version)
    os.makedirs(target_dir, exist_ok=True)

    files = os.listdir(binaries_path)
    if not files:
        print(f"No Client binaries found in {binaries_path}, exiting.")
        sys.exit(1)

    client_files = [f for f in files if f.startswith("blenderkit-client")]
    for file_name in client_files:
        source_file = os.path.join(binaries_path, file_name)
        target_file = os.path.join(target_dir, file_name)
        shutil.copy2(source_file, target_file)
        print(f"Copied: {target_file}")

    print(
        f"{len(client_files)} Blendkit Client {client_version} binaries copied: {binaries_path} -> {target_dir}"
    )


def build_plugin(client_dir=CLIENT_DIR):
    """Copy client binaries into the plugin directory (in-place)."""
    print("# Copying Client binaries into Plugin")

    try:
        client_bin_dir = find_client_bin_dir(client_dir)
    except (FileNotFoundError, OSError):
        print(f"Error: Client binaries not found in {client_dir}")
        print("Run './dev.py build' or './dev.py build-client' first.")
        sys.exit(1)

    client_version = os.path.basename(os.path.normpath(client_bin_dir))
    plugin_dir = os.path.join(PLUGIN_SRC_DIR, PLUGIN_DIR)

    print(f"Client binaries dir: {client_bin_dir}")
    print(f"Client version: {client_version[1:]}")
    print(f"Target dir: {PLUGIN_CLIENT_DIR}/{client_version}")
    print()

    copy_client_binaries(client_bin_dir, plugin_dir)

    print(f"✓ Client binaries copied to {PLUGIN_CLIENT_DIR}")


def find_client_bin_dir(client_dir=CLIENT_DIR):
    """Find the latest client binaries directory in the client build output."""
    base_dir = os.path.join(client_dir, "out", "blenderkit", "client")
    dirs = [
        d
        for d in os.listdir(base_dir)
        if d.startswith("v") and os.path.isdir(os.path.join(base_dir, d))
    ]
    if not dirs:
        raise FileNotFoundError(f"No client binaries found in {base_dir}")
    # sort desc in unlikely case there are multiple versions
    dirs.sort(reverse=True)
    return os.path.join(base_dir, dirs[0])


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


def find_plugin_client_bin_dir():
    """Find the client binaries directory within the plugin."""
    if not os.path.exists(PLUGIN_CLIENT_DIR):
        return None
    dirs = [
        d
        for d in os.listdir(PLUGIN_CLIENT_DIR)
        if d.startswith("v") and os.path.isdir(os.path.join(PLUGIN_CLIENT_DIR, d))
    ]
    if not dirs:
        return None
    dirs.sort(reverse=True)
    return os.path.join(PLUGIN_CLIENT_DIR, dirs[0])


def build_archive(result_dir=RESULT_DIR):
    """Create a filtered ZIP archive of the plugin."""
    print("# Creating Plugin archive")

    # Check that client binaries exist
    client_bin_dir = find_plugin_client_bin_dir()
    if not client_bin_dir:
        print(f"Error: Client binaries not found at {PLUGIN_CLIENT_DIR}")
        print("Run './dev.py build' or './dev.py build-plugin' first.")
        sys.exit(1)

    client_files = [
        f for f in os.listdir(client_bin_dir) if f.startswith("blenderkit-client")
    ]
    if not client_files:
        print(f"Error: No client binaries found in {client_bin_dir}")
        print("Run './dev.py build' or './dev.py build-plugin' first.")
        sys.exit(1)

    plugin_version = get_plugin_version()
    archive_base_name = get_archive_base_name(plugin_version)
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

    print(f"Creating ZIP archive...")
    real_archive_path = shutil.make_archive(
        archive_base_path, "zip", result_dir, PLUGIN_SRC_DIR
    )
    if os.path.abspath(archive_path) != os.path.abspath(real_archive_path):
        raise RuntimeError(
            f"Archive path mismatch: expected {archive_path}, got {real_archive_path}"
        )

    archive_size = human_readable_size(os.path.getsize(archive_path))
    print(f"✓ Blendkit Godot plugin archive DONE \\o/")
    print(f"ZIP archive: {archive_path} ({archive_size})")


def clean():
    """Remove build artifacts."""
    print("# Cleaning build artifacts")

    if os.path.exists(RESULT_DIR):
        print(f"Removing: {RESULT_DIR}")
        shutil.rmtree(RESULT_DIR)

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
    help="Full build: client, plugin, and archive.",
    description="Full build: build client, copy binaries to plugin, create archive.",
    formatter_class=NiceHelpFormatter,
)
parser_build.set_defaults(func=build)
parser_build.add_argument(
    "-c",
    "--client-dir",
    type=str,
    default=CLIENT_DIR,
    dest="client_dir",
    help="Path to Blendkit Client sources.",
)
parser_build.add_argument(
    "-o",
    "--result-dir",
    type=str,
    default=RESULT_DIR,
    dest="result_dir",
    help="Output directory for the archive.",
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


def main():
    args = parser.parse_args()

    if args.command is None:
        # Print help when no command is given for convenience
        parser.print_help()
        sys.exit(1)

    # Extract kwargs for command function, excluding parser internals
    kwargs = {k: v for k, v in vars(args).items() if k not in ("command", "func")}
    args.func(**kwargs)


if __name__ == "__main__":
    main()
