# Agent Smith

macOS menubar utility. Watches your Desktop and silently sorts every new file into the right folder — including nested subfolders. When a folder gets crowded, an on-device LLM proposes a subfolder taxonomy for you to approve. Runs entirely on-device.

```
🗄  Agent Smith                              [running]
─────────────────────────────────────────────────────
Assimilated "trip.png" → Receipts/Uber.

Curator plans
─────────────────────────────────────────────────────
Receipts → 3 subfolders                  · 25 files
 • Uber (12) — ride receipts
 • Amazon (8) — order confirmations
 • Tax (5) — annual statements
                              [Approve] [Dismiss]

Recent activity
─────────────────────────────────────────────────────
✓ uber-receipt.pdf       → Receipts/Uber   [Undo]
🗂 Reorganized Receipts into 3 subfolders · 25 files
                                          [Undo all]
```

## Use it

```bash
git clone https://github.com/AlexCSalinas/agent-smith.git
cd agent-smith
mkdir -p ~/Desktop/{Memes,Other,Receipts,Work}
scripts/install-launchd.sh
```

That's it. The menubar icon appears (click it for activity + Undo) and Smith auto-starts at every login from now on. Drop a file or folder on your Desktop — within ~1 second it lands in one of the four category folders.

- **Add a new category** (or subfolder): `mkdir ~/Desktop/Code` (or `~/Desktop/Receipts/Uber`). Smith picks it up on the next file and starts filing directly into it.
- **Let Smith propose subfolders**: when a category accumulates ≥ 20 loose files, Smith asks the on-device LLM to cluster them and shows the plan in the menubar. Approve in one click — every move undoes together.
- **Turn it off permanently**: `scripts/uninstall-launchd.sh`.
- **One-off run (no auto-start)**: `swift run AgentSmith`.
- **Logs**: `~/Library/Logs/AgentSmith/stderr.log`.

Apps, aliases, and active project folders (anything containing `.git`, `package.json`, `Cargo.toml`, `Package.swift`, etc.) are never touched.
