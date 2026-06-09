# Agent Smith

> A macOS menubar utility that watches your Desktop and silently sorts every new file into the right folder. Themed after the Matrix character: every file that lands spawns a "Smith" that assimilates it.

Clutter lands on your Desktop. A Smith reads it, decides where it belongs, files it, and posts a notification with an Undo button. You never see the mess.

```
🗄  Agent Smith                              [running]
─────────────────────────────────────────────────────
Assimilated "Screenshot 2026-06-09.png" → Receipts.

Recent activity                                   [3]
─────────────────────────────────────────────────────
✓ uber-receipt.pdf       → Receipts · 92%   [Undo]
✓ cat-meme.jpg           → Memes    · 88%   [Undo]
✓ project-notes.png      → Work     · 85%   [Undo]

watching: ~/Desktop                          [Quit]
```

## Why it exists

I take a lot of screenshots and download a lot of receipts. My Desktop is a graveyard. Existing "Desktop cleanup" tools either rely on rigid rules (`if filename matches X, move to Y`), or they move files to a black-hole destination you have to dig through. I wanted something that:

- **Decides** where a file belongs by reading it (OCR for images, PDFKit for PDFs, filename otherwise), not by matching brittle regexes.
- **Is invisible.** Lives in the menubar, fires no modals, finishes in under a second.
- **Never loses anything.** Every move is reversible with a single click.
- **Runs on-device.** No cloud, no API keys, no leaks of receipt photos.

## How it works

```
FileWatcher ─(new file URL)─► Triage ─► Classifier ─► Filer ─► Ledger
  (FSEvents)                  (is it a   (Folder      (move +    (append-only
                               candidate?  Decision)   collision  log + undo)
                               stable?)                handling)
                                                          │
                                                          ▼
                                                 Menubar UI
```

Five modules with no UI dependencies (compiler-enforced via separate SPM targets), wired by a `SmithOrchestrator` actor:

| Module | What it does |
|---|---|
| **Watcher** | `FSEvents`-backed top-level watch of `~/Desktop`. Filters events to the watched dir's direct children so we never recurse into our own destination folders. Dedups inside a 500ms window. |
| **Triage** | Decides whether to touch an item at all (blacklist on `.app`, `.bundle`, `.framework`, aliases, `.DS_Store`, partial downloads, iCloud placeholders). Detects active project folders via `.git`/`package.json`/`Cargo.toml`/`Package.swift`/etc. and refuses to move them. Waits for files to finish writing via byte-size stability poll. |
| **Classifier** | Behind a `FolderClassifier` protocol seam. Ships two backends: `FoundationModelsBackend` (Apple's on-device LLM, macOS 26+) gated by `#if canImport(FoundationModels)`, and `HeuristicBackend` (deterministic keyword-overlap with substring fuzz for plurals). The LLM lights up automatically when present. |
| **Filer** | Collision-safe moves (`name.png` → `name (2).png` → `name (3).png`). Refuses to overwrite — ever. |
| **Ledger** | Append-only JSON-Lines log in `~/Library/Application Support/AgentSmith/ledger.jsonl`. Undo appends a new line marking the move undone rather than rewriting history. |

## Quick start

Requires macOS 13+ and Swift 6 (Command Line Tools or full Xcode).

```bash
git clone https://github.com/AlexCSalinas/agent-smith.git
cd agent-smith
mkdir -p ~/Desktop/{Memes,Other,Receipts,Work}    # the four default category folders
swift run AgentSmith                              # menubar icon appears top-right
```

Drop a screenshot on your Desktop. Within ~1 second it moves into the most-likely category folder. Click the menubar icon to see the activity feed.

## Always-on (LaunchAgent)

To run permanently — at every login, restart on crash, no terminal needed:

```bash
scripts/install-launchd.sh
```

This builds a release binary, writes `~/Library/LaunchAgents/com.agentsmith.app.plist`, and `launchctl bootstrap`s it. Logs go to `~/Library/Logs/AgentSmith/`. To turn it off: `scripts/uninstall-launchd.sh`. To rebuild after editing code: re-run `install-launchd.sh` — it kills the old agent and swaps the new one.

> **TCC note**: macOS prompts the LaunchAgent for Desktop access on first run (a separate TCC entry from your Terminal). Click Allow.

## Design principles

Four hard rules. They override convenience.

1. **Never delete a user file.** Move only. No `removeItem`. No trashing.
2. **Every move is reversible.** Recorded in the ledger; undone with a single click.
3. **No silent guessing.** The classifier only chooses from folders the user already created — it can't invent new ones. Below-threshold confidence routes to a fallback folder (default `Other/`) rather than a random guess.
4. **Local-first and private.** OCR, PDF text extraction, and classification all run on-device. File names and contents never leave the machine.
5. **Fail safe.** On any error (permission denied, classification crash, move collision), the file stays exactly where it is.

## Configuration

The default config is `SmithConfig.userDesktopDefault()` — watches `~/Desktop`, files into its subfolders, ledger in Application Support. To customize:

```swift
SmithConfig(
    sourceFolder:      URL(fileURLWithPath: "/path/to/watch"),
    organizedRoot:     URL(fileURLWithPath: "/path/to/categories"),
    ledgerURL:         URL(fileURLWithPath: "/path/to/ledger.jsonl"),
    autoFileThreshold: 0.85,         // confidence required to auto-file
    fallbackFolder:    "Other"       // nil = use review queue instead
)
```

**Adding a new category** is just `mkdir ~/Desktop/NewCategoryName`. Smith picks it up on the next file — no restart, no config edit. Want stuff classified as "Code"? `mkdir ~/Desktop/Code` and a file named `agent-smith.swift` will route there.

**Blacklist** (Triage skips these): `.app`, `.bundle`, `.framework`, `.kext`, `.plugin`, `.saver`, `.appex`, `.icloud`, `.alias`, `.xcodeproj`, `.xcworkspace`, `.lock`, `.swp`, `.DS_Store`, `.localized`, dotfiles, and any folder containing one of the project markers below.

**Project markers** (folders containing any of these are left alone): `.git`, `package.json`, `package.swift`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `Pipfile`, `requirements.txt`, `Gemfile`, `pom.xml`, `build.gradle`, `Makefile`, `CMakeLists.txt`, `pubspec.yaml`, `composer.json`, `node_modules`, `.xcodeproj`, `.xcworkspace`.

## Tech stack

- **Language**: Swift 6 with strict concurrency. Watcher and Ledger are `actor`s.
- **UI**: SwiftUI `MenuBarExtra`. `NSApp.setActivationPolicy(.accessory)` keeps it out of the Dock (equivalent to `LSUIElement = true`).
- **File watching**: Core Services `FSEventStreamCreate`. Bridged into an `AsyncStream<URL>`.
- **OCR**: Apple Vision (`VNRecognizeTextRequest` + `VNClassifyImageRequest`).
- **PDF text**: PDFKit (`PDFDocument`).
- **On-device LLM**: Apple Foundation Models (macOS 26+). Gated behind `#if canImport(FoundationModels)`; falls back to a deterministic keyword heuristic otherwise.
- **Packaging**: Swift Package Manager. Zero third-party dependencies.

## Project layout

```
agent-smith/
├── CLAUDE.md                       # operating spec
├── DEVLOG.md                       # running log of decisions
├── Package.swift                   # multi-target SPM build
├── README.md                       # this file
├── Sources/
│   ├── Models/                     # FileSignals, FolderDecision, Move, FolderClassifier, errors, logging
│   ├── Watcher/                    # FSEvents wrapper (FolderWatcher actor)
│   ├── Triage/                     # filtering, stability, signal extraction (Vision + PDFKit)
│   ├── Filer/                      # collision-safe moves
│   ├── Ledger/                     # append-only JSON-Lines log + undo
│   ├── Classifier/                 # FolderClassifier protocol, Foundation Models + Heuristic backends
│   ├── SmithCore/                  # SmithOrchestrator (wires everything together)
│   └── AgentSmith/                 # SwiftUI MenuBarExtra app
├── Tests/                          # Swift Testing — 44 tests
├── scripts/
│   ├── install-launchd.sh          # build release + register LaunchAgent
│   └── uninstall-launchd.sh        # tear down LaunchAgent
├── Sandbox/                        # dev playground (gitignored at the file level)
└── Fixtures/                       # sample inputs for tests
```

## Tests

```bash
swift test
```

44 tests using Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). Coverage:

- **Filer**: move, collision rename, never-overwrites, undo round-trip, undo refuses to clobber.
- **Ledger**: append + reload persistence, undo folds to latest state, append-only on disk (undo writes a second line), unknown-move undo throws.
- **Watcher**: emits on new file, throws on missing path, dedups rapid duplicate emissions.
- **Triage**: extension whitelist + blacklist semantics, app bundle / `.DS_Store` / dotfile / partial-download rejection, project-folder detection (`.git`, `package.json`, etc.), directory stability shortcut, growing-file timeout, screenshot regex.
- **Classifier**: heuristic picks best token overlap, low confidence on no overlap, empty candidates, fallback to heuristic when Foundation Models unavailable.
- **Orchestrator**: files above threshold, queues below threshold (with `fallbackFolder = nil`), fallback folder routing, undo restores file, skips non-images in whitelist mode, skips when no candidates, startup catch-up sweep, folder moves.

## Status

| Milestone | Status |
|---|---|
| M0 — Scaffold | Done |
| M1 — Watcher | Done |
| M2 — Filer + Ledger + Undo | Done |
| M3 — Triage + Classifier | Done |
| M4 — Menubar UI | Done |
| M5 — Signed `.app` + Full Disk Access onboarding + notarization | Deferred (needs Xcode + signing identity) |

What's intentionally not in v1: a settings UI, multi-source watching, Downloads folder, iCloud sync, scheduled batch runs.

## IP note

Themed homage. The Matrix and Agent Smith are trademarks of Warner Bros. Don't ship a public release with Matrix-branded copy, the Smith likeness, or trademarked assets — original art and copy only.

## License

MIT. See `LICENSE` (if present).
