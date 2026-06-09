# CLAUDE.md — Agent Smith

Project context and operating instructions for Claude Code. Read this fully before writing any code. When in doubt, follow the Prime Directives below over anything else.


## 1. What this is

Agent Smith is a macOS menubar utility that watches cluttered folders (the Desktop and Downloads) and automatically files new junk — starting with screenshots — into the correct existing folder, using an on-device LLM to decide where each file belongs.

It's themed after the Matrix character: every new file that lands spawns a "Smith" that assimilates it (reads it, decides where it goes, files it). The user never has to think about it.

This is a personal / portfolio project. Optimize for a tight, polished, trustworthy v1 — not a sprawling platform.

One-liner: Clutter lands on your desktop, a Smith assimilates it into the right folder, and you never see the mess.


## 2. Prime Directives (non-negotiable)

These override convenience, cleverness, and feature requests. If a task conflicts with one of these, stop and flag it.

1. **Never delete a user file. Ever.** Moving only. No trashing, no overwriting.
2. **Every move is reversible.** Each move is recorded in an append-only ledger (file path → destination, timestamp, decision, confidence). One-tap undo must always work.
3. **No silent guessing.** Only auto-file when classifier confidence is above the threshold. Anything below goes to a review queue for the user to confirm — never a guess.
4. **Local-first and private.** Classification runs on-device by default. File names, contents, and OCR text must not leave the machine unless the user explicitly opts into a cloud backend.
5. **Never touch the user's real folders during development.** All dev and tests run against a sandbox directory (`./Sandbox/Desktop`) seeded with fixture files. The real `~/Desktop` / `~/Downloads` are only ever used in a signed, user-consented release build.
6. **Fail safe.** On any error (permission, classification, move collision), leave the file exactly where it is and log it. A broken Smith does nothing; it never makes things worse.


## 3. v1 Scope

Build exactly this. Resist scope creep — note good ideas in `DEVLOG.md` for later instead of building them now.

In scope:
- Watch one configurable source folder (default: the sandbox Desktop).
- Detect new files; handle **screenshots only** for now (image files matching the macOS screenshot pattern, plus any `.png`/`.jpg` the user drops in).
- Wait until a file is fully written before acting (no half-downloaded files).
- OCR / caption the image, then classify it into one of the user's existing folders under a chosen "organized root."
- Move high-confidence files; queue low-confidence ones for review.
- Menubar UI: status, recent activity feed, the review queue, and an undo button.
- Append-only move ledger with undo.

Out of scope for v1 (do NOT build yet):
- Downloads folder and arbitrary file types (PDFs, zips, installers).
- Auto-creating brand-new folders / inventing a taxonomy.
- A rules engine, scheduling, multi-source watching, iCloud sync, settings beyond the essentials.
- Any cloud/remote classifier (design the seam for it, don't wire it).


## 4. Architecture

Single app, clear module boundaries, one-directional data flow:

```
FileWatcher  ──(new file URL)──▶  Triage  ──▶  Classifier  ──▶  Filer  ──▶  Ledger
   (FSEvents)                    (is it a       (Folder       (move +      (append-only
                                  screenshot?    Decision)     collision    log + undo)
                                  stable?)                     handling)
                                                                   │
                                                                   ▼
                                                          NotificationCenter + Menubar UI
```

- **FileWatcher** — wraps FSEvents for the source folder. Emits a URL when a file is created/renamed-in. An actor so events are serialized.
- **Triage** — filters to screenshots, and confirms the file is stable (size unchanged across two polls, no `.download`/`.crdownload` temp sibling) before passing it on.
- **Classifier** — behind a `FolderClassifier` protocol (see §5). Takes signals (filename, OCR text, image labels, list of existing folders) and returns a typed `FolderDecision { folder, confidence, reason }`.
- **Filer** — performs the move with collision-safe renaming (`name.png` → `name (2).png`), never overwriting. Returns a `Move` record.
- **Ledger** — append-only JSON log of every `Move`; powers the activity feed and undo. An actor.
- **UI** — SwiftUI `MenuBarExtra`: status, recent activity, review queue, undo. No main window needed in v1.

Keep the watcher/classifier/filer free of UI imports so they're unit-testable in isolation.


## 5. Tech stack & key decisions

- **Language:** Swift 6 (strict concurrency on). Use `async`/`await` and `actor` for the watcher and ledger.
- **UI:** SwiftUI `MenuBarExtra`. Menubar-only app (`LSUIElement = true`, no dock icon).
- **Deployment target:** macOS 26 (Tahoe). Apple silicon. (The on-device LLM requires Apple Intelligence to be available.)
- **File watching:** FSEvents (`FSEventStreamCreate`). The C-callback → Swift bridging via `Unmanaged` is the one genuinely fiddly bit — wrap it in a small Swift class and unit-test the event plumbing against the sandbox dir.
- **OCR / image signals:** Apple's Vision framework — `VNRecognizeTextRequest` for on-screen text, `VNClassifyImageRequest` for generic labels. Always on-device, free.
- **Classifier (default backend):** Apple Foundation Models framework. On-device LLM, no API keys, no network, free. Use it like this:

  ```swift
  import FoundationModels

  // Constrained output — the model is forced to return a valid folder choice.
  @Generable
  struct FolderDecision {
      @Guide(description: "Exact name of the best-fitting existing folder")
      let folder: String
      @Guide(description: "Confidence from 0.0 to 1.0")
      let confidence: Double
      @Guide(description: "One short phrase explaining the choice")
      let reason: String
  }

  let session = LanguageModelSession(instructions: """
      You file screenshots into one of the user's EXISTING folders.
      Only choose from the provided folder list. If nothing fits well,
      return low confidence — do not invent a folder.
      """)

  let decision = try await session.respond(
      to: "Filename: \(name)\nText in image: \(ocrText)\nFolders: \(folders.joined(separator: ", "))",
      generating: FolderDecision.self
  ).content
  ```

  Check `SystemLanguageModel.default.availability` first and degrade gracefully (fall back to the review queue) if Apple Intelligence isn't available.

- **The seam:** define `protocol FolderClassifier { func classify(_ signals: FileSignals) async throws -> FolderDecision }`. Ship `LocalClassifier` (Vision + Foundation Models). Leave room for a future `RemoteClassifier` but don't build it.
- **Packaging:** Swift Package Manager for any deps (aim for zero). Xcode project for the app target.
- **Formatting/linting:** `swift-format`. No warnings in committed code.


## 6. Suggested repo layout

```
AgentSmith/
├── CLAUDE.md
├── DEVLOG.md                  # running log of decisions + parked ideas
├── AgentSmith.xcodeproj
├── Sources/
│   ├── App/                   # MenuBarExtra entry point, app lifecycle
│   ├── Watcher/               # FSEvents wrapper
│   ├── Triage/                # screenshot + stability filtering
│   ├── Classifier/            # FolderClassifier protocol + LocalClassifier
│   ├── Filer/                 # collision-safe moves
│   ├── Ledger/                # append-only log + undo
│   ├── UI/                    # SwiftUI views (status, activity, review queue)
│   └── Models/                # FileSignals, FolderDecision, Move
├── Tests/                     # XCTest
├── Sandbox/Desktop/           # dev playground — fixtures live here
└── Fixtures/                  # sample screenshots for tests
```


## 7. Build order (milestones)

Work one milestone at a time. Each must build, pass tests, and be demoable before moving on. Commit at the end of each.

1. **M0 — Scaffold.** Xcode project, menubar app that launches and shows a static menu. `LSUIElement`. Empty modules with protocols stubbed.
2. **M1 — Watcher.** FSEvents watching `./Sandbox/Desktop`; log every new file URL. Test by dropping files in. *Acceptance:* new files reliably logged, no duplicates, no crash on rapid drops.
3. **M2 — Filer + Ledger + Undo.** Move a file into a hard-coded folder, record it, and undo it — all reversible, collision-safe, never overwriting. *Acceptance:* unit tests for move, collision rename, and undo round-trip.
4. **M3 — Triage + Classifier.** Screenshot/stability filtering; Vision OCR; Foundation Models returns a `FolderDecision`. Threshold routing (auto-file vs review queue). *Acceptance:* a fixture screenshot of a receipt classifies into a "Receipts" fixture folder above threshold.
5. **M4 — UI.** Menubar shows live status, recent activity feed, the review queue (approve/correct), and undo. *Acceptance:* full loop visible and controllable from the menubar against the sandbox.
6. **M5 — Real-folder release path.** Entitlements, Full Disk Access onboarding, notarization, switch source to the real `~/Desktop` only behind explicit user consent. *Acceptance:* signed build files a real screenshot with working undo.

After M5, revisit `DEVLOG.md` for v2 (Downloads, more file types).


## 8. Conventions

- **Concurrency:** strict Swift 6 concurrency. Watcher and Ledger are actors. No shared mutable state across threads without isolation.
- **Errors:** no force-unwraps (`!`) on any file I/O. Use typed throwing errors and the fail-safe rule (§2.6).
- **Logging:** `os.Logger` with a subsystem per module. Log every move, every skip, every classification with its confidence.
- **Tests:** the Filer and Ledger MUST have tests (they touch files). Tests run only against `Sandbox/` and `Fixtures/`, never real folders. Mock the classifier in tests so they're deterministic.
- **Naming:** lean into the theme where it's harmless and clear (`Smith` for a per-file work unit, `assimilate(_:)` for classify-and-file) but keep public API names honest.


## 9. Permissions & packaging

- Desktop and Downloads are TCC-protected. The release app needs Full Disk Access (notarized DMG path) or per-folder security-scoped bookmarks (sandboxed path). Plan onboarding around granting this once.
- Enable Hardened Runtime; notarize the release build.
- Foundation Models / Apple Intelligence must be available on the user's machine — detect and degrade gracefully if not.
- During dev, none of this is needed because everything runs against the local `Sandbox/` dir.


## 10. The Smith flavor (UX voice)

Keep it tasteful and never at the expense of clarity. Notifications can read in Smith's deadpan register:

- *Filed:* `Assimilated "Screenshot 2026-06-08.png" → Receipts.`  (with an Undo action)
- *Queued:* `Inevitable, but not yet certain — 2 files await review.`

**IP note:** this is a homage. Use original copy and original menubar art — do not ship the Matrix name, Smith's likeness, or trademarked assets in any public or commercial release. Themed internal/personal builds are fine.


## 11. How to work (for Claude Code)

- Build and run after every change; keep the tree green.
- Work in small, reviewable commits aligned to the milestones.
- Operate only on `Sandbox/` and `Fixtures/` until M5. Never run the app against real user folders without explicit instruction.
- Before any irreversible or file-touching operation outside the sandbox, stop and ask.
- When you make a non-obvious decision, record it in `DEVLOG.md`.
- If something in this file is ambiguous or you'd need to guess, surface it rather than guessing.


## 12. Open questions to confirm before relevant milestones

- **Organized root:** where do filed screenshots live? (e.g. `~/Pictures/Screenshots/<folder>` vs a user-picked root.) — needed for M3.
- **Confidence threshold:** starting value for auto-file vs review (suggest 0.85). — M3.
- **Folder source:** classify only into existing subfolders of the organized root? — M3.
- **Bundle ID / signing identity** for the release build. — M5.


## 13. Definition of done (v1)

Drop a screenshot into `Sandbox/Desktop`. Within a couple of seconds, Smith OCRs it, classifies it into the correct existing folder (or routes it to the review queue if unsure), moves it collision-safely, posts a notification with a working Undo, and records the move in the ledger — all on-device, with zero real user files touched and all tests green.
