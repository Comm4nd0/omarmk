#!/bin/bash
# Sync this working copy into the Omarchy user plugin directory for live
# development. The shell hot-reloads plugin files on save, so run this after
# each change (or wire it to a file watcher).
set -euo pipefail

PLUGIN_ID="io.github.comm4nd0.omarmk"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

omarchy plugin validate "$SRC"

mkdir -p "$DEST"
rsync -a --delete \
  --exclude '.git' --exclude 'node_modules' --exclude 'tests' --exclude 'scripts' \
  "$SRC/" "$DEST/"

echo "Installed to $DEST"
echo "Enable with: omarchy plugin enable $PLUGIN_ID"
