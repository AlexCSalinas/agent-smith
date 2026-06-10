import Foundation
import Testing
@testable import Curator
@testable import Models

/// Deterministic planner. Returns whatever `RawTaxonomyPlan` it's given, ignoring the
/// inputs — that's the point: the Curator's validator should reshape the plan into
/// something safe regardless of what the LLM emits.
struct StubPlanner: TaxonomyPlanner {
    let plan: RawTaxonomyPlan
    let onCall: (@Sendable (String, [String]) -> Void)?
    init(_ plan: RawTaxonomyPlan, onCall: (@Sendable (String, [String]) -> Void)? = nil) {
        self.plan = plan
        self.onCall = onCall
    }
    func proposeTaxonomy(category: String, filenames: [String]) async throws -> RawTaxonomyPlan {
        onCall?(category, filenames)
        return plan
    }
}

struct ThrowingPlanner: TaxonomyPlanner {
    struct Boom: Error {}
    func proposeTaxonomy(category: String, filenames: [String]) async throws -> RawTaxonomyPlan {
        throw Boom()
    }
}

@Suite final class CuratorTests {
    let tmpRoot: URL
    let fm = FileManager.default

    init() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CuratorTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        self.tmpRoot = root
    }

    deinit {
        try? fm.removeItem(at: tmpRoot)
    }

    private func makeOrganized() throws -> URL {
        let url = tmpRoot.appendingPathComponent("Organized", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCategory(_ name: String, in organized: URL, files: [String]) throws -> URL {
        let cat = organized.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: cat, withIntermediateDirectories: true)
        for f in files {
            try Data().write(to: cat.appendingPathComponent(f))
        }
        return cat
    }

    private func makeSource() throws -> URL {
        let url = tmpRoot.appendingPathComponent("Desktop", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Crowding detection

    @Test func scanForCrowded_picksCategoriesAtOrAboveThreshold() async throws {
        let organized = try makeOrganized()
        _ = try makeCategory("Receipts", in: organized, files: (0..<20).map { "r\($0).png" })
        _ = try makeCategory("Memes", in: organized, files: (0..<5).map { "m\($0).png" })
        _ = try makeCategory("Work", in: organized, files: (0..<25).map { "w\($0).png" })

        let curator = Curator(
            config: Curator.Config(
                organizedRoot: organized,
                sourceFolder: try makeSource(),
                crowdingThreshold: 20
            ),
            planner: nil
        )
        let crowded = await curator.scanForCrowdedCategories()
        #expect(crowded == ["Receipts", "Work"])
    }

    @Test func scanForCrowded_excludesSourceFolderWhenSharedWithRoot() async throws {
        // Desktop layout: source == organizedRoot. The "source" itself shouldn't be
        // counted as a category even though it's a directory under organizedRoot.
        let shared = try makeOrganized()
        _ = try makeCategory("Receipts", in: shared, files: (0..<25).map { "r\($0).png" })

        let curator = Curator(
            config: Curator.Config(
                organizedRoot: shared,
                sourceFolder: shared,  // same dir
                crowdingThreshold: 20
            ),
            planner: nil
        )
        let crowded = await curator.scanForCrowdedCategories()
        #expect(crowded == ["Receipts"])
    }

    @Test func scanForCrowded_ignoresSubdirsInLooseCount() async throws {
        let organized = try makeOrganized()
        let cat = try makeCategory("Receipts", in: organized, files: (0..<10).map { "r\($0).png" })
        // 10 loose files + 30 files inside a subdir — only loose count toward crowding.
        let sub = cat.appendingPathComponent("Old", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        for i in 0..<30 { try Data().write(to: sub.appendingPathComponent("old\(i).png")) }

        let curator = Curator(
            config: Curator.Config(
                organizedRoot: organized,
                sourceFolder: try makeSource(),
                crowdingThreshold: 20
            ),
            planner: nil
        )
        let crowded = await curator.scanForCrowdedCategories()
        #expect(crowded == [])
    }

    // MARK: - Validation

    private func files(_ n: Int, prefix: String = "f") -> Set<String> {
        Set((0..<n).map { "\(prefix)\($0).png" })
    }

    @Test func validate_dropsClustersBelowMinFileCount() {
        let raw = RawTaxonomyPlan(subfolders: [
            RawSubfolderProposal(name: "Tiny", files: ["a.png", "b.png"], rationale: "x"),
            RawSubfolderProposal(name: "Big", files: ["c.png", "d.png", "e.png"], rationale: "y"),
        ])
        let plan = Curator.validate(
            raw,
            category: "Receipts",
            existingFiles: ["a.png", "b.png", "c.png", "d.png", "e.png"],
            existingSubfolders: []
        )
        #expect(plan?.subfolders.map(\.name) == ["Big"])
    }

    @Test func validate_dropsFilenamesThatDontExist() {
        let raw = RawTaxonomyPlan(subfolders: [
            RawSubfolderProposal(name: "Big",
                files: ["a.png", "ghost.png", "b.png", "phantom.png", "c.png"],
                rationale: "x"),
        ])
        let plan = Curator.validate(
            raw,
            category: "Receipts",
            existingFiles: ["a.png", "b.png", "c.png"],
            existingSubfolders: []
        )
        #expect(plan?.subfolders.first?.files == ["a.png", "b.png", "c.png"])
    }

    @Test func validate_firstClusterWinsForDuplicateFileAssignments() {
        let raw = RawTaxonomyPlan(subfolders: [
            RawSubfolderProposal(name: "Alpha", files: ["a.png", "b.png", "shared.png"], rationale: ""),
            RawSubfolderProposal(name: "Beta",  files: ["c.png", "d.png", "e.png", "shared.png"], rationale: ""),
        ])
        let plan = Curator.validate(
            raw,
            category: "Receipts",
            existingFiles: ["a.png", "b.png", "c.png", "d.png", "e.png", "shared.png"],
            existingSubfolders: []
        )
        let alpha = try? #require(plan?.subfolders.first { $0.name == "Alpha" })
        let beta  = try? #require(plan?.subfolders.first { $0.name == "Beta" })
        #expect(alpha?.files.contains("shared.png") == true)
        #expect(beta?.files.contains("shared.png") == false)
        // Beta keeps its other files (3 after dedup of "shared.png") — still survives the min count.
        #expect(beta?.files == ["c.png", "d.png", "e.png"])
    }

    @Test func validate_reusesExistingSubfolderNameOnFuzzyMatch() {
        let raw = RawTaxonomyPlan(subfolders: [
            // "uber rides" should collapse onto the canonical "Uber" already on disk.
            RawSubfolderProposal(name: "uber-rides", files: ["a.png", "b.png", "c.png"], rationale: ""),
        ])
        let plan = Curator.validate(
            raw,
            category: "Receipts",
            existingFiles: ["a.png", "b.png", "c.png"],
            existingSubfolders: ["UberRides"]
        )
        #expect(plan?.subfolders.first?.name == "UberRides")
    }

    @Test func validate_rejectsPathSeparatorsAndLeadingDots() {
        let raw = RawTaxonomyPlan(subfolders: [
            RawSubfolderProposal(name: "Nested/Stuff", files: ["a.png", "b.png", "c.png"], rationale: ""),
            RawSubfolderProposal(name: ".hidden", files: ["d.png", "e.png", "f.png"], rationale: ""),
            RawSubfolderProposal(name: "Back\\slash", files: ["g.png", "h.png", "i.png"], rationale: ""),
            RawSubfolderProposal(name: "OK", files: ["j.png", "k.png", "l.png"], rationale: ""),
        ])
        let plan = Curator.validate(
            raw,
            category: "Receipts",
            existingFiles: Set((0..<26).map { String(UnicodeScalar(UInt8(97 + $0))) + ".png" }),
            existingSubfolders: []
        )
        #expect(plan?.subfolders.map(\.name) == ["OK"])
    }

    @Test func validate_dropsDuplicateClusterNamesAfterNormalization() {
        let raw = RawTaxonomyPlan(subfolders: [
            RawSubfolderProposal(name: "Tax Documents", files: ["a.png", "b.png", "c.png"], rationale: ""),
            RawSubfolderProposal(name: "tax-documents", files: ["d.png", "e.png", "f.png"], rationale: ""),
        ])
        let plan = Curator.validate(
            raw,
            category: "Receipts",
            existingFiles: ["a.png", "b.png", "c.png", "d.png", "e.png", "f.png"],
            existingSubfolders: []
        )
        #expect(plan?.subfolders.count == 1)
        #expect(plan?.subfolders.first?.name == "Tax Documents")
    }

    @Test func validate_returnsNilWhenNothingSurvives() {
        let raw = RawTaxonomyPlan(subfolders: [
            RawSubfolderProposal(name: "Tiny", files: ["a.png"], rationale: ""),
        ])
        let plan = Curator.validate(
            raw,
            category: "Receipts",
            existingFiles: ["a.png"],
            existingSubfolders: []
        )
        #expect(plan == nil)
    }

    @Test func validate_returnsNilForEmptyPlan() {
        let raw = RawTaxonomyPlan(subfolders: [])
        let plan = Curator.validate(raw, category: "Receipts", existingFiles: [], existingSubfolders: [])
        #expect(plan == nil)
    }

    // MARK: - End-to-end via the actor

    @Test func proposePlan_returnsValidatedPlanForCrowdedCategory() async throws {
        let organized = try makeOrganized()
        let cat = try makeCategory("Receipts", in: organized, files: [])
        for i in 0..<20 { try Data().write(to: cat.appendingPathComponent("uber\(i).png")) }
        for i in 0..<5  { try Data().write(to: cat.appendingPathComponent("misc\(i).png")) }

        let raw = RawTaxonomyPlan(subfolders: [
            RawSubfolderProposal(
                name: "Uber",
                files: (0..<20).map { "uber\($0).png" },
                rationale: "trip receipts"
            ),
            RawSubfolderProposal(
                name: "Misc",
                files: (0..<2).map { "misc\($0).png" },  // < 3 → dropped
                rationale: "leftovers"
            ),
        ])
        let curator = Curator(
            config: Curator.Config(
                organizedRoot: organized,
                sourceFolder: try makeSource(),
                crowdingThreshold: 20
            ),
            planner: StubPlanner(raw)
        )

        let plan = await curator.proposePlan(for: "Receipts")
        #expect(plan?.category == "Receipts")
        #expect(plan?.subfolders.map(\.name) == ["Uber"])
        #expect(plan?.subfolders.first?.files.count == 20)
    }

    @Test func proposePlan_returnsNilOnPlannerError() async throws {
        let organized = try makeOrganized()
        _ = try makeCategory("Receipts", in: organized, files: (0..<30).map { "f\($0).png" })
        let curator = Curator(
            config: Curator.Config(
                organizedRoot: organized,
                sourceFolder: try makeSource(),
                crowdingThreshold: 20
            ),
            planner: ThrowingPlanner()
        )
        let plan = await curator.proposePlan(for: "Receipts")
        #expect(plan == nil)
    }

    @Test func proposePlan_skipsBelowThreshold() async throws {
        let organized = try makeOrganized()
        _ = try makeCategory("Receipts", in: organized, files: (0..<5).map { "f\($0).png" })
        let curator = Curator(
            config: Curator.Config(
                organizedRoot: organized,
                sourceFolder: try makeSource(),
                crowdingThreshold: 20
            ),
            planner: StubPlanner(RawTaxonomyPlan(subfolders: [
                RawSubfolderProposal(name: "Anything", files: ["f0.png", "f1.png", "f2.png"], rationale: "x"),
            ]))
        )
        let plan = await curator.proposePlan(for: "Receipts")
        #expect(plan == nil)
    }

    @Test func proposePlan_isInactiveWhenPlannerNil() async throws {
        let organized = try makeOrganized()
        _ = try makeCategory("Receipts", in: organized, files: (0..<30).map { "f\($0).png" })
        let curator = Curator(
            config: Curator.Config(
                organizedRoot: organized,
                sourceFolder: try makeSource(),
                crowdingThreshold: 20
            ),
            planner: nil
        )
        let plan = await curator.proposePlan(for: "Receipts")
        #expect(plan == nil)
    }
}
