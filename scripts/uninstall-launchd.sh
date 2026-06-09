#!/usr/bin/env bash
# Stop the Agent Smith LaunchAgent and remove it. After this, Smith won't
# auto-start at login. To run it once: `swift run AgentSmith` from the repo.
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.agentsmith.app.plist"
LABEL="com.agentsmith.app"

echo "==> stopping and unloading"
launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null || true

echo "==> removing plist"
rm -f "$PLIST"

echo ""
echo "    Agent Smith disabled. Won't auto-start on next login."
echo "    To re-enable always-on:  scripts/install-launchd.sh"
echo "    To run it once now:      swift run AgentSmith   (from the repo)"
