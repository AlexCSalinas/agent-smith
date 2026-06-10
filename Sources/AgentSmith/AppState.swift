import Foundation
import SwiftUI
import SmithCore
import Models
import Curator

/// `ObservableObject` shim around the actor-backed `SmithOrchestrator`. Views observe this
/// for state changes; user actions flow back through `Task`s into the orchestrator.
///
/// Singleton so the orchestrator can be started by `AppDelegate.applicationDidFinishLaunching`
/// (i.e. at launch) rather than waiting for the user's first menubar click. SwiftUI views
/// pull the same instance via `.environmentObject(AppState.shared)`.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum RunState: Equatable {
        case stopped
        case starting
        case running
        case errored(String)
    }

    @Published private(set) var runState: RunState = .stopped
    @Published private(set) var recentMoves: [Move] = []
    @Published private(set) var recentActivity: [ActivityEntry] = []
    @Published private(set) var reviewQueue: [ReviewItem] = []
    @Published private(set) var pendingPlans: [CuratorPlan] = []
    @Published private(set) var lastEvent: String = "Waiting for files…"

    let config: SmithConfig
    private var orchestrator: SmithOrchestrator?
    private var eventsTask: Task<Void, Never>?

    private init() {
        self.config = SmithConfig.userDesktopDefault()
    }

    func start() {
        guard runState == .stopped else { return }
        runState = .starting

        Task {
            do {
                let orch = try SmithOrchestrator(config: config)
                self.orchestrator = orch
                try await orch.start()
                self.runState = .running
                await self.refresh()
                self.subscribeToEvents(orch)
            } catch {
                self.runState = .errored("\(error)")
                AppLog.app.error("start failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        let orch = orchestrator
        orchestrator = nil
        runState = .stopped
        Task { await orch?.stop() }
    }

    func undo(_ move: Move) {
        guard let orch = orchestrator else { return }
        Task {
            do {
                _ = try await orch.undo(move.id)
                await self.refresh()
            } catch {
                self.lastEvent = "Undo failed: \(error.localizedDescription)"
            }
        }
    }

    func approve(_ item: ReviewItem, folder: String) {
        guard let orch = orchestrator else { return }
        Task {
            do {
                _ = try await orch.approveReview(item.id, intoFolder: folder)
                await self.refresh()
            } catch {
                self.lastEvent = "Approve failed: \(error.localizedDescription)"
            }
        }
    }

    func dismiss(_ item: ReviewItem) {
        guard let orch = orchestrator else { return }
        Task {
            await orch.dismissReview(item.id)
            await self.refresh()
        }
    }

    func runCuratorScan() {
        guard let orch = orchestrator else { return }
        Task {
            await orch.runCuratorScan()
            await self.refresh()
        }
    }

    func approvePlan(_ plan: CuratorPlan) {
        guard let orch = orchestrator else { return }
        Task {
            do {
                _ = try await orch.approvePlan(plan.id)
                await self.refresh()
            } catch {
                self.lastEvent = "Approve plan failed: \(error.localizedDescription)"
            }
        }
    }

    func dismissPlan(_ plan: CuratorPlan) {
        guard let orch = orchestrator else { return }
        Task {
            await orch.dismissPlan(plan.id)
            await self.refresh()
        }
    }

    func undoBatch(_ batchID: UUID) {
        guard let orch = orchestrator else { return }
        Task {
            _ = await orch.undoBatch(batchID)
            await self.refresh()
        }
    }

    private func subscribeToEvents(_ orch: SmithOrchestrator) {
        let stream = orch.events
        eventsTask = Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: SmithOrchestrator.Event) async {
        switch event.kind {
        case .filed(let move):
            lastEvent = "Assimilated \"\(move.sourceURL.lastPathComponent)\" → \(move.decision.folder)."
        case .queued(let item):
            lastEvent = "Inevitable, but not yet certain — \(item.url.lastPathComponent) awaits review."
        case .skipped(let url, let reason):
            lastEvent = "Skipped \(url.lastPathComponent) — \(reason)."
        case .error(let url, let message):
            lastEvent = "Error on \(url.lastPathComponent): \(message)"
        case .undone(let move):
            lastEvent = "Undone: \(move.sourceURL.lastPathComponent) restored."
        case .curatorProposed(let plan):
            let summary = plan.subfolders
                .prefix(3)
                .map { "\($0.name) (\($0.files.count))" }
                .joined(separator: ", ")
            lastEvent = "Curator suggests: \(plan.category) → \(summary)"
        }
        await refresh()
    }

    private func refresh() async {
        guard let orch = orchestrator else { return }
        let queue = await orch.currentReviewQueue()
        let recent = await orch.recentMoves(limit: 50)
        let plans = await orch.currentPendingPlans()
        self.reviewQueue = queue
        self.recentMoves = recent
        self.pendingPlans = plans
        self.recentActivity = ActivityEntry.group(recent).prefix(20).map { $0 }
    }
}

/// Activity-feed item: either a single live-classifier move, or a Curator batch shown
/// as one row. Grouping happens client-side from the latest moves snapshot so the
/// Ledger remains a flat append-only log of `Move`s.
enum ActivityEntry: Identifiable {
    case single(Move)
    case batch(id: UUID, category: String, moves: [Move])

    var id: String {
        switch self {
        case .single(let m): return "single:\(m.id.uuidString)"
        case .batch(let id, _, _): return "batch:\(id.uuidString)"
        }
    }

    /// Group a most-recent-first list of moves: contiguous moves with the same
    /// `batchID` collapse into one batch entry. Non-batch moves stay individual.
    /// The result is ordered by the first occurrence of each entry in `moves`.
    static func group(_ moves: [Move]) -> [ActivityEntry] {
        var entries: [ActivityEntry] = []
        var batchBuckets: [UUID: [Move]] = [:]
        var batchOrder: [UUID] = []

        for move in moves {
            if let batchID = move.batchID {
                if batchBuckets[batchID] == nil {
                    batchBuckets[batchID] = []
                    batchOrder.append(batchID)
                }
                batchBuckets[batchID]?.append(move)
            } else {
                entries.append(.single(move))
            }
        }

        for batchID in batchOrder {
            let batch = batchBuckets[batchID] ?? []
            let category = batch.first?.decision.folder
                .split(separator: "/")
                .first
                .map(String.init) ?? "—"
            entries.append(.batch(id: batchID, category: category, moves: batch))
        }
        // Keep newest-first overall, using each entry's first move timestamp.
        return entries.sorted { lhs, rhs in
            lhs.timestamp > rhs.timestamp
        }
    }

    var timestamp: Date {
        switch self {
        case .single(let m): return m.timestamp
        case .batch(_, _, let moves): return moves.map(\.timestamp).max() ?? .distantPast
        }
    }
}
