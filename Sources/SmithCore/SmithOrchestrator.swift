import Foundation
import Models
import Watcher
import Triage
import Filer
import Ledger
import Classifier
import Curator

/// Wires the modules together: Watcher → Triage → Classifier → (Filer + Ledger) or review queue.
/// One `Smith` is spawned per file via `assimilate(_:)` (the per-file work unit from
/// CLAUDE.md §10). All Smith I/O flows through this orchestrator.
public actor SmithOrchestrator {
    public struct Event: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case filed(Move)
            case queued(ReviewItem)
            case skipped(URL, reason: String)
            case error(URL, message: String)
            case undone(Move)
            /// Curator surfaced a validated plan for a crowded category. Sits in
            /// `currentPendingPlans()` until the user approves or dismisses it.
            case curatorProposed(CuratorPlan)
        }
        public let timestamp: Date
        public let kind: Kind

        public init(timestamp: Date = Date(), kind: Kind) {
            self.timestamp = timestamp
            self.kind = kind
        }
    }

    private var config: SmithConfig
    private let watcher: FolderWatcher
    private let triage: Triage
    private let classifier: any FolderClassifier
    private let filer: Filer
    private let ledger: Ledger
    private let curator: Curator

    private var watchTask: Task<Void, Never>?
    private var reviewQueue: [ReviewItem] = []
    private var pendingPlans: [CuratorPlan] = []
    private let eventsContinuation: AsyncStream<Event>.Continuation
    public nonisolated let events: AsyncStream<Event>

    public init(
        config: SmithConfig,
        classifier: any FolderClassifier = LocalClassifier(),
        triage: Triage = Triage(),
        planner: TaxonomyPlanner? = FoundationModelsTaxonomyPlanner.makeIfAvailable()
    ) throws {
        self.config = config
        self.watcher = FolderWatcher(path: config.sourceFolder)
        self.triage = triage
        self.classifier = classifier
        self.filer = Filer()
        self.ledger = try Ledger(at: config.ledgerURL)
        self.curator = Curator(
            config: Curator.Config(
                organizedRoot: config.organizedRoot,
                sourceFolder: config.sourceFolder,
                crowdingThreshold: config.crowdingThreshold
            ),
            planner: planner
        )

        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(200))
        self.events = stream
        self.eventsContinuation = continuation
    }

    // MARK: - Lifecycle

    public func start() async throws {
        try await ensureDirectoriesExist()

        // Snapshot anything already in the source folder BEFORE the watcher starts so the
        // catch-up scan and the live watcher don't overlap. FSEvents `sinceNow` won't refire
        // for pre-existing files, so the watcher will only see things created after this point.
        let preExisting = (try? FileManager.default.contentsOfDirectory(
            at: config.sourceFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        try await watcher.start()
        let stream = watcher.events
        watchTask = Task { [weak self] in
            for await url in stream {
                await self?.assimilate(url)
            }
        }

        AppLog.smith.info("Smith orchestrator started; \(preExisting.count) pre-existing file(s) to sweep")

        // Run the catch-up sweep in the background so start() returns promptly.
        Task { [weak self] in
            guard let self else { return }
            for url in preExisting {
                await self.assimilate(url)
            }
        }
    }

    public func stop() async {
        watchTask?.cancel()
        watchTask = nil
        await watcher.stop()
        eventsContinuation.finish()
        AppLog.smith.info("Smith orchestrator stopped")
    }

    // MARK: - Per-file Smith

    /// The Smith for one file: classify-and-file or route to review.
    /// Public so tests can drive it directly without spinning up the watcher.
    public func assimilate(_ url: URL) async {
        // Fast filter — extension, dotfiles, partial-download suffixes.
        guard triage.shouldConsider(url) else {
            emit(.skipped(url, reason: "not a candidate file type"))
            return
        }

        // Wait for the file to finish being written.
        do {
            try await triage.waitForStability(url)
        } catch {
            emit(.error(url, message: "\(error)"))
            return
        }

        // Build signals + classify.
        let folders = config.candidateFolders()
        if folders.isEmpty {
            emit(.skipped(url, reason: "no candidate folders under organized root yet"))
            return
        }

        // The candidate folders themselves are destinations, not sources — never move them.
        // (Relevant when source == organizedRoot, e.g. categories live on Desktop alongside their inputs.)
        if folders.contains(url.lastPathComponent) {
            emit(.skipped(url, reason: "destination folder — left alone"))
            return
        }

        let signals: FileSignals
        let decision: FolderDecision
        do {
            signals = try await triage.buildSignals(for: url, candidateFolders: folders)
            decision = try await classifier.classify(signals)
        } catch {
            emit(.error(url, message: "\(error)"))
            return
        }

        // Threshold gate. If below threshold and a fallback folder exists, use it; otherwise
        // route to the review queue (the original Prime Directive 3 behavior).
        let effectiveDecision: FolderDecision
        if decision.confidence >= config.autoFileThreshold {
            effectiveDecision = decision
        } else if let fallback = config.fallbackFolder, folders.contains(fallback) {
            effectiveDecision = FolderDecision(
                folder: fallback,
                confidence: decision.confidence,
                reason: "below threshold (\(String(format: "%.2f", decision.confidence))) — sent to fallback: \(decision.reason)"
            )
        } else {
            let item = ReviewItem(url: url, signals: signals, suggestion: decision)
            reviewQueue.append(item)
            emit(.queued(item))
            return
        }

        // Auto-file. Destination may be nested (e.g. "Receipts/Uber") — appendRelative
        // splits on "/" so each component lands as a real path component on every macOS.
        let destDir = config.organizedRoot.appendRelative(effectiveDecision.folder)
        do {
            let move = try filer.move(url, intoDirectory: destDir, decision: effectiveDecision)
            try await ledger.append(move)
            emit(.filed(move))
        } catch {
            emit(.error(url, message: "\(error)"))
        }
    }

    // MARK: - Review queue actions

    public func currentReviewQueue() -> [ReviewItem] { reviewQueue }

    /// User-approved review item: move it using the (possibly user-corrected) folder path.
    /// `folder` may be a nested relative path like "Receipts/Uber".
    public func approveReview(_ id: UUID, intoFolder folder: String) async throws -> Move {
        guard let idx = reviewQueue.firstIndex(where: { $0.id == id }) else {
            throw SmithError.undoFailed(reason: "review item \(id) not found")
        }
        let item = reviewQueue.remove(at: idx)
        let decision = FolderDecision(folder: folder, confidence: 1.0, reason: "user-approved")
        let destDir = config.organizedRoot.appendRelative(folder)
        let move = try filer.move(item.url, intoDirectory: destDir, decision: decision)
        try await ledger.append(move)
        emit(.filed(move))
        return move
    }

    public func dismissReview(_ id: UUID) {
        reviewQueue.removeAll { $0.id == id }
    }

    // MARK: - Curator

    public func currentPendingPlans() -> [CuratorPlan] { pendingPlans }

    /// Scan for crowded categories and propose a plan for each, surfacing each validated
    /// plan as a `.curatorProposed` event. Read-only: no files are moved here. Plans for
    /// categories that already have a pending plan are skipped so repeated scans don't
    /// pile up duplicates.
    public func runCuratorScan() async {
        let crowded = await curator.scanForCrowdedCategories()
        let alreadyPending = Set(pendingPlans.map(\.category))
        for category in crowded where !alreadyPending.contains(category) {
            if let plan = await curator.proposePlan(for: category) {
                pendingPlans.append(plan)
                emit(.curatorProposed(plan))
            }
        }
    }

    public func dismissPlan(_ id: UUID) {
        pendingPlans.removeAll { $0.id == id }
    }

    /// M7 stub: removes the plan from the pending list and returns it. M8 will wire
    /// this to actually execute the contained moves under a single ledger batchID.
    @discardableResult
    public func approvePlan(_ id: UUID) async throws -> CuratorPlan {
        guard let idx = pendingPlans.firstIndex(where: { $0.id == id }) else {
            throw SmithError.undoFailed(reason: "pending plan \(id) not found")
        }
        let plan = pendingPlans.remove(at: idx)
        AppLog.curator.info("approvePlan stub: \(plan.category, privacy: .public) — apply wired in M8")
        return plan
    }

    // MARK: - Undo

    public func undo(_ moveID: UUID) async throws -> Move {
        guard let move = await ledger.get(moveID), !move.undone else {
            throw SmithError.undoFailed(reason: "move not found or already undone")
        }
        let undone = try filer.undo(move)
        let recorded = try await ledger.recordUndo(of: moveID)
        emit(.undone(undone))
        return recorded
    }

    // MARK: - Ledger access (for UI)

    public func recentMoves(limit: Int = 30) async -> [Move] {
        await ledger.recent(limit: limit)
    }

    // MARK: - Internals

    private func ensureDirectoriesExist() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: config.sourceFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: config.organizedRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: config.ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func emit(_ kind: Event.Kind) {
        eventsContinuation.yield(Event(kind: kind))
    }
}

extension URL {
    /// Append a relative path that may contain "/" separators (e.g. "Receipts/Uber"),
    /// splitting it into real path components. Empty / leading-slash segments are dropped.
    /// `URL.appendingPathComponent` happens to preserve slashes for file URLs on macOS,
    /// but going through the components API keeps that out of the platform-specific path
    /// and makes intent explicit.
    func appendRelative(_ relative: String) -> URL {
        var url = self
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(component), isDirectory: true)
        }
        return url
    }
}
