# DEVLOG

Running log of decisions and parked ideas. Newest first.

## 2026-06-09 — M6: Deep filing into existing subfolders

`SmithConfig.candidateFolders()` now returns relative paths up to depth 2
(`"Receipts"`, `"Receipts/Uber"`). Live classification can now pick a subfolder
that already exists — folder *creation* remains forbidden for the live path
(reserved for the upcoming Curator in M7/M8). Off-list guards stay in both
backends; a hallucinated folder returns confidence 0.0.

### Context budget — chose truncation

The on-device Foundation Models window is small. We cap candidate entries sent
to the LLM at 40 (see `FoundationModelsBackend.candidateBudget`). All top-level
categories are always retained; subfolders are added round-robin per category
until the cap is reached. Chosen over two-stage prompting because the upstream
list is already sorted and the v1 deployment has < 20 categories — truncation
is one round-trip and good enough; two-stage was overkill for the projected
catalog size.

### Heuristic nested scoring

`HeuristicBackend` now scores `"Receipts/Uber"` primarily on the last
component (`Uber`) with a 30% contribution from parent tokens, plus a small
nesting bonus so a confidently-matched subfolder beats its equally-confident
parent. The bonus pushes raw score > 1.0; the final confidence is still
clamped (`min(0.9, score)`).

### Orchestrator path handling

`URL.appendingPathComponent("a/b")` happens to preserve slashes for file URLs,
but to keep that out of the platform-specific path we added
`URL.appendRelative(_:)` which explicitly splits on `/`. Used in
`assimilate(_:)` and `approveReview(_:intoFolder:)`. `Filer.move` already
handled intermediate directory creation, so no changes there.

## 2026-06-09 — Always-on via LaunchAgent

User wanted Agent Smith to run with zero ongoing effort. Added two helper scripts:

- `scripts/install-launchd.sh` — builds the release binary, writes
  `~/Library/LaunchAgents/com.agentsmith.app.plist`, kills any
  `swift run` or stray instances, and `launchctl bootstrap`s the new agent
  (`gui/$UID` domain). Idempotent — re-run after code changes to rebuild and
  swap. Logs go to `~/Library/Logs/AgentSmith/{stdout,stderr}.log`.
- `scripts/uninstall-launchd.sh` — `launchctl bootout` + remove the plist.

The agent has `RunAtLoad = true` and `KeepAlive = true`, so it boots at
login and restarts if it ever crashes.

### Layout changes coupled to this

The 4 category folders moved from `~/Pictures/Screenshots/` to `~/Desktop/`.
`SmithConfig.userDesktopDefault` now has `sourceFolder == organizedRoot ==
~/Desktop`, plus two safety nets to prevent the watcher from looping:

1. `FolderWatcher` now filters FSEvents to TOP-LEVEL changes only (the C
   callback compares the event's parent path against the canonicalized watch
   root). Without this, the watcher would see files moving into its own
   destination subfolders and try to re-sort them. Canonicalization (resolve
   symlinks + standardize) is required because FSEvents emits the
   `/private/var/...` form for paths under `/var/...` (a symlink).
2. `SmithOrchestrator.assimilate(_:)` now skips items whose lastPathComponent
   is one of the candidate folder names — the categories never get filed
   into themselves.

The watcher also now emits directory events (previously file-only) so
folders dropped on Desktop become sortable.

### TCC implications

The LaunchAgent-started binary is a separate process from Terminal, so macOS
prompts for Desktop access independently on first launch. User clicks Allow
once; subsequent launches reuse the grant. If they ever delete the agent's
TCC entry in System Settings → Privacy → Files and Folders, they'll be
prompted again.

## 2026-06-09 — Drop review queue, broaden file types

Two deliberate departures from v1 scope (CLAUDE.md §2.3 and §3), at user's request:

**Auto-move everything — no review queue.** `SmithConfig.fallbackFolder` added. When set, any
classifier decision below `autoFileThreshold` is rewritten to use the fallback folder
(provided it exists under `organizedRoot`) instead of routing to the review queue.
`userDesktopDefault` ships with `fallbackFolder = "Other"`, so the review queue is
effectively unused in the production config. Prime Directive 3 (no silent guessing) is
formally violated — Smith now guesses, but every move is still reversible via undo. The
review queue UI + orchestrator code path is left intact for configs where `fallbackFolder`
is nil (so old behavior is one config flip away).

**All file types and folders.** `Triage.Config` inverted from whitelist → blacklist:

- `allowedExtensions` now defaults to empty (= accept everything).
- `excludedExtensions` lists macOS bundle types (`.app`, `.bundle`, `.framework`, `.kext`,
  `.plugin`, `.saver`, `.appex`) plus iCloud placeholders and editor lock files.
- `excludedFilenames` covers `.DS_Store` and `.localized`.
- `processFolders = true` by default — directories are moved as opaque blobs.
- `pdfExtensions = ["pdf"]` triggers PDFKit text extraction via the new
  `PDFTextExtractor` (best-effort, returns empty string on parse failure so the file
  still goes through filename-only classification).

`Triage.waitForStability(_:)` short-circuits for directories (no byte-size signal exists
for a folder; we treat a visible folder as done). `Triage.buildSignals(_:)` routes content
extraction by extension: Vision for images, PDFKit for PDFs, filename-only for everything
else (zips, docs, code, folders, …).

**Risk note** — first catch-up sweep against a populated `~/Desktop` will move basically
everything not on the blacklist. Mostly into `Other/` because filenames rarely
token-match. The user was warned; mitigation is the existing undo.

## 2026-06-09 — Switched watch path to real ~/Desktop

User wants the natural Cmd-Shift-3 → Desktop flow, no macOS preference changes. So:

- `SmithConfig.userDesktopDefault()` now watches `~/Desktop` and files into
  `~/Pictures/Screenshots/<folder>` (deliberately different trees so cleaned files don't
  accumulate sub-folders on the Desktop).
- macOS screenshot default location was reverted (`defaults delete com.apple.screencapture
  location`) so the preference matches user expectation.
- Catch-up sweep added to `SmithOrchestrator.start()` so a snapshot of the source folder is
  processed at launch before live FSEvents come in (covers the case "I launched the app and
  there are 30 screenshots already sitting on my Desktop"). Test in
  `Tests/SmithCoreTests/StartupSweepTests.swift`.

### Prime Directive 5 deviation, recorded

CLAUDE.md §2.5 says "Never touch the user's real folders during development." The user
explicitly overrode this — they want production behavior now. On first launch after this
change, macOS will TCC-prompt the parent process (Terminal under `swift run`) for Desktop
read access. Until granted, `FolderWatcher.start()` will throw `watcherFailedToStart`.

This means the on-Tahoe / M5 release path is more aligned now: the same `userDesktopDefault`
config will be the production one, just running from a notarized `.app` with the right
entitlements instead of from a `swift run` against Terminal's TCC scope.

## 2026-06-08 — Initial build (M0–M4 in one sweep)

All non-deferred milestones (M0 scaffold, M1 watcher, M2 filer+ledger+undo, M3 triage+classifier,
M4 menubar UI) are implemented in this single pass. M5 (entitlements, notarization, real-folder
switch) is held until the user has Xcode + a signing identity (see "M5 prerequisites" below).

### Test framework — Swift Testing, not XCTest

Command Line Tools ship the FoundationModels-free Testing.framework but **not** the XCTest
swiftmodule for macOS. Tests are written against `import Testing` (`@Suite`, `@Test`, `#expect`,
`#require`). This is the Swift 6 default anyway and produces nicer output; nothing lost. On a
machine with full Xcode, `swift test` works either way.

### URL.resourceValues bug we tripped on

First pass of `Triage.fileByteSize(_:)` used `url.resourceValues(forKeys: [.fileSizeKey])`.
Resource values are **cached on the URL instance**, so the stability poll observed the same size
forever and falsely declared a growing file stable. Fixed by switching to
`FileManager.attributesOfItem(atPath:)` which always re-reads. Worth remembering — this bug
would be invisible against a finished file and only surface against an actively-downloading one.

### Heuristic classifier substring matching

The fallback heuristic now does light substring fuzz when comparing folder tokens to signal
tokens, so simple English plurals (`receipt` ↔ `Receipts`) hit each other. Real fix is stemming,
but substring-contains with a minimum length of 4 chars covers the common case for now and
doesn't pull in a dependency.

### M5 prerequisites (handoff)

To finish v1 on a machine with Xcode + macOS 26 (Tahoe):

1. Open the package in Xcode (`open Package.swift`).
2. Convert the executable target to an App target, or wrap with an Xcode app shell that imports
   `SmithCore`. Add `Info.plist` with `LSUIElement = true` (the `setActivationPolicy(.accessory)`
   call we use at runtime is a workaround that works without a bundle but `LSUIElement` is the
   correct production setting).
3. Add entitlements:
   - Hardened Runtime
   - App Sandbox OFF *or* security-scoped bookmark to user-selected source folder
   - Or request Full Disk Access via TCC if going the notarized-DMG route
4. Add an onboarding flow that prompts the user to pick:
   - Source folder (default to `~/Desktop`)
   - Organized root (default to `~/Pictures/Screenshots/`)
5. On macOS 26, the `FoundationModelsBackend` lights up automatically via `#if canImport`. Verify
   `SystemLanguageModel.default.availability` is `.available` on the user's hardware.
6. Notarize the release build.
7. IP note (CLAUDE.md §10): keep the in-app copy and menubar art original — no Matrix
   trademarks, no Smith likeness.

## 2026-06-08 — Initial scaffold

### Environment constraints discovered

The dev machine is on **macOS 15.5 with Command Line Tools only** (no full Xcode install). CLAUDE.md targets **macOS 26 Tahoe** with the Foundation Models framework. Consequences:

- **Foundation Models framework is not available** at build time on this machine. The `LocalClassifier` ships with a `FoundationModelsBackend` stub that is gated behind `#if canImport(FoundationModels)` so it compiles on a macOS 26 box, plus a `HeuristicBackend` (filename + OCR text pattern matching) that runs everywhere so the rest of the pipeline can be developed and tested end-to-end on the current machine.
- **Xcode project is not generated** — using Swift Package Manager (`Package.swift`) for the build. The executable target uses `NSApp.setActivationPolicy(.accessory)` at startup to get menubar-only behavior without an `Info.plist`'s `LSUIElement` key. A real `.xcodeproj` with entitlements, hardened runtime, and notarization is M5 work and requires the user to install Xcode on a macOS 26 machine.
- **Vision OCR** is available on macOS 15.5 so M3's OCR path is real, not stubbed.

### Layout decision

Picked multi-target SPM over one-library-with-subdirectories. Each subsystem (`Models`, `Watcher`, `Triage`, `Filer`, `Ledger`, `Classifier`, `SmithCore`) is its own target. Trade-off: more `Package.swift` boilerplate, but the compiler enforces the "no UI imports in core" rule from CLAUDE.md §4 — a UI import in `Watcher` won't compile, full stop.

### Parked for later

- Downloads folder + arbitrary file types — v2 per CLAUDE.md §3.
- Auto-creating new folders / taxonomy inference — out of scope.
- Cloud / remote classifier — protocol seam exists (`FolderClassifier`), no implementation.
- Rules engine, multi-source watching, settings UI beyond essentials.
- `swift-format` config — add when there's enough code to bother.
