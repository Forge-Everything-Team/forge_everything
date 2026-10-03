#!/usr/bin/env bash
# ============================================================
#  Forge Everything - server launcher
#
#  Syncs the pack from the repo, then starts NeoForge.
#  ALWAYS run this, never ./run.sh directly - run.sh alone will
#  start the server with whatever mods it happened to have last.
#
#  EDIT THIS: point at the same java your run.sh uses.
# ============================================================
set -euo pipefail

JAVA="java"
PACK_URL="https://raw.githubusercontent.com/Rexilyent/forge-everything/main/packwiz/pack.toml"

echo "Syncing modpack..."
if ! "$JAVA" -jar packwiz-installer-bootstrap.jar -g -s server "$PACK_URL"; then
    echo
    echo "Pack sync FAILED - not starting the server."
    echo "A partial mod set fails in ways that look unrelated to the real cause,"
    echo "so this stops here on purpose. Fix the sync, then run again."
    exit 1
fi

echo
echo "Starting server..."
exec ./run.sh
