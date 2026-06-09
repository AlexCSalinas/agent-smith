# Agent Smith

macOS menubar utility. Watches your Desktop and silently sorts every new file into the right folder. Runs entirely on-device.

```
🗄  Agent Smith                              [running]
─────────────────────────────────────────────────────
Assimilated "Screenshot 2026-06-09.png" → Receipts.

Recent activity
─────────────────────────────────────────────────────
✓ uber-receipt.pdf       → Receipts · 92%   [Undo]
✓ cat-meme.jpg           → Memes    · 88%   [Undo]
✓ project-notes.png      → Work     · 85%   [Undo]
```

## Use it

```bash
git clone https://github.com/AlexCSalinas/agent-smith.git
cd agent-smith
mkdir -p ~/Desktop/{Memes,Other,Receipts,Work}
scripts/install-launchd.sh
```

That's it. The menubar icon appears (click it for activity + Undo) and Smith auto-starts at every login from now on. Drop a file or folder on your Desktop — within ~1 second it lands in one of the four category folders.

- **Add a new category**: `mkdir ~/Desktop/Code` (or whatever you want). Smith picks it up on the next file.
- **Turn it off permanently**: `scripts/uninstall-launchd.sh`.
- **One-off run (no auto-start)**: `swift run AgentSmith`.
- **Logs**: `~/Library/Logs/AgentSmith/stderr.log`.

Apps, aliases, and active project folders (anything containing `.git`, `package.json`, `Cargo.toml`, `Package.swift`, etc.) are never touched.
