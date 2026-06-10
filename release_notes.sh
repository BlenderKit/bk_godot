#!/usr/bin/env bash
# Print the CHANGELOG.md section for the current version to stdout.
# Prints nothing if the section is not found.
# Usage: ./release_notes.sh [VERSION]
#   VERSION: with or without leading 'v' (e.g. 0.4.1 or v0.4.1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGELOG="$SCRIPT_DIR/CHANGELOG.md"
PLUGIN_CFG="$SCRIPT_DIR/addons/blendkit/plugin.cfg"

if [[ $# -ge 1 ]]; then
    VERSION="${1#v}"
else
    VERSION=$(grep '^version=' "$PLUGIN_CFG" | cut -d'"' -f2)
fi

if [[ ! -f "$CHANGELOG" ]]; then
    echo "error: $CHANGELOG not found" >&2
    exit 1
fi

output=$(awk -v ver="$VERSION" '
    $0 ~ ("^## " ver " ") { flag=1; next }
    /^## /                { flag=0 }
    flag                  { print }
' "$CHANGELOG")

if [[ -z "$output" ]]; then
    echo "error: no changelog section found for version $VERSION in $CHANGELOG" >&2
    exit 1
fi

echo "$output"
