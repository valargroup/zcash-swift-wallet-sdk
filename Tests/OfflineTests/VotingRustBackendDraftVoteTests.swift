import XCTest
@testable import ZcashLightClientKit

final class VotingRustBackendDraftVoteTests: XCTestCase {
    func testDraftVotesRoundTripAndClear() throws {
        let backend = VotingRustBackend()
        try backend.open(path: ":memory:")
        defer { backend.close() }
        try backend.setWalletId("wallet-a")

        try backend.replaceDraftVotes(
            roundId: "round-a",
            drafts: [
                VotingDraftVote(proposalId: 2, choice: 1),
                VotingDraftVote(proposalId: 1, choice: 0)
            ]
        )

        let loaded = try backend.getDraftVotes(roundId: "round-a")
        XCTAssertEqual(loaded.map(\.proposalId), [1, 2])
        XCTAssertEqual(loaded.map(\.choice), [0, 1])
        XCTAssertTrue(loaded.allSatisfy { $0.updatedAt > 0 })

        try backend.clearDraftVotes(roundId: "round-a")
        XCTAssertTrue(try backend.getDraftVotes(roundId: "round-a").isEmpty)
    }

    func testDraftVotesAreWalletScoped() throws {
        let backend = VotingRustBackend()
        try backend.open(path: ":memory:")
        defer { backend.close() }

        try backend.setWalletId("wallet-a")
        try backend.replaceDraftVotes(
            roundId: "round-a",
            drafts: [VotingDraftVote(proposalId: 1, choice: 1)]
        )

        try backend.setWalletId("wallet-b")
        try backend.replaceDraftVotes(
            roundId: "round-a",
            drafts: [VotingDraftVote(proposalId: 1, choice: 2)]
        )
        XCTAssertEqual(try backend.getDraftVotes(roundId: "round-a").first?.choice, 2)

        try backend.setWalletId("wallet-a")
        XCTAssertEqual(try backend.getDraftVotes(roundId: "round-a").first?.choice, 1)
    }

    func testClearRoundDoesNotDeleteDraftVotes() throws {
        let backend = VotingRustBackend()
        try backend.open(path: ":memory:")
        defer { backend.close() }
        try backend.setWalletId("wallet-a")

        try backend.replaceDraftVotes(
            roundId: "round-a",
            drafts: [VotingDraftVote(proposalId: 1, choice: 1)]
        )

        try backend.clearRound(roundId: "round-a")

        XCTAssertEqual(try backend.getDraftVotes(roundId: "round-a").first?.choice, 1)
    }
}
