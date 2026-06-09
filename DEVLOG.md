# DEVLOG

Running log of decisions and parked ideas. Newest first.

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
