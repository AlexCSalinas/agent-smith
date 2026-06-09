#!/usr/bin/env bash
# Install Agent Smith as a macOS LaunchAgent: starts at login, restarts on crash,
# runs forever in the background. Re-run this any time you change the code — it
# rebuilds the release binary, swaps the agent, and you're back in business.
#
# Uninstall: scripts/uninstall-launchd.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$REPO_DIR/.build/release/AgentSmith"
PLIST="$HOME/Library/LaunchAgents/com.agentsmith.app.plist"
LOG_DIR="$HOME/Library/Logs/AgentSmith"
LABEL="com.agentsmith.app"

echo "==> building release binary (this can take 30–60 seconds the first time)"
(cd "$REPO_DIR" && swift build -c release)
[ -x "$BINARY" ] || { echo "ERROR: build did not produce $BINARY"; exit 1; }

echo "==> preparing log directory"
mkdir -p "$LOG_DIR"

echo "==> stopping any running instances"
launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null || true
pkill -f "swift run AgentSmith" 2>/dev/null || true
pkill -x AgentSmith 2>/dev/null || true
sleep 0.5

echo "==> writing $PLIST"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/stderr.log</string>
</dict>
</plist>
EOF

echo "==> loading launch agent"
launchctl bootstrap "gui/$UID" "$PLIST"

echo "==> verifying"
sleep 1
if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
    echo ""
    echo "    Agent Smith is running. Look for the tray icon in your menubar."
    echo ""
    echo "    Logs:        tail -f $LOG_DIR/stderr.log"
    echo "    Stop:        scripts/uninstall-launchd.sh"
    echo "    After code:  scripts/install-launchd.sh   (re-runs build + swap)"
    echo ""
    echo "    Heads up: macOS may prompt once for Desktop access — click Allow."
else
    echo "ERROR: bootstrap reported success but the service isn't listed."
    echo "       Check $LOG_DIR/stderr.log for details."
    exit 1
fi
