//
//  PIRWitnessRetryOfflineTests.swift
//
//
//  Created by Cursor on 4/7/26.
//

import Foundation
@testable import TestUtils
import XCTest
@testable import ZcashLightClientKit

final class PIRWitnessRetryOfflineTests: ZcashTestCase {
    private final class RetryTestTransactionEncoder: TransactionEncoder {
        enum StubbedResult {
            case success([ZcashTransaction.Overview])
            case failure(Error)
        }

        private(set) var createProposedTransactionsCallsCount = 0
        var createResults: [StubbedResult] = []

        func createProposedTransactions(
            proposal: Proposal,
            spendingKey: UnifiedSpendingKey
        ) async throws -> [ZcashTransaction.Overview] {
            createProposedTransactionsCallsCount += 1
            let index = createProposedTransactionsCallsCount - 1
            guard createResults.indices.contains(index) else {
                XCTFail("Missing stubbed result for createProposedTransactions call \(index + 1)")
                return []
            }

            switch createResults[index] {
            case .success(let transactions):
                return transactions
            case .failure(let error):
                throw error
            }
        }

        func proposeTransfer(
            accountUUID: AccountUUID,
            recipient: String,
            amount: Zatoshi,
            memoBytes: MemoBytes?
        ) async throws -> Proposal {
            fatalError("Unused in PIR witness retry tests")
        }

        func proposeShielding(
            accountUUID: AccountUUID,
            shieldingThreshold: Zatoshi,
            memoBytes: MemoBytes?,
            transparentReceiver: String?
        ) async throws -> Proposal? {
            fatalError("Unused in PIR witness retry tests")
        }

        func proposeFulfillingPaymentFromURI(
            _ uri: String,
            accountUUID: AccountUUID
        ) async throws -> Proposal {
            fatalError("Unused in PIR witness retry tests")
        }

        func submit(transaction: EncodedTransaction) async throws {
            fatalError("Unused in PIR witness retry tests")
        }

        func fetchTransactionsForTxIds(_ txIds: [Data]) async throws -> [ZcashTransaction.Overview] {
            fatalError("Unused in PIR witness retry tests")
        }

        func closeDBConnection() {}
    }

    private func makeSpendingKey(network: ZcashNetwork) throws -> UnifiedSpendingKey {
        let derivationTool = DerivationTool(networkType: network.networkType)
        return try derivationTool.deriveUnifiedSpendingKey(
            seed: Environment.seedBytes,
            accountIndex: Zip32AccountIndex(0)
        )
    }

    private func makeProposal() -> Proposal {
        Proposal(inner: FfiProposal())
    }

    private func makeNotePosition() -> PIRNotePosition {
        PIRNotePosition(id: 1, position: 42, value: 60_000)
    }

    private func makeWitnessEntry() -> PIRWitnessEntry {
        PIRWitnessEntry(
            noteId: 1,
            position: 42,
            siblings: Array(repeating: String(repeating: "00", count: 32), count: 32),
            anchorHeight: 1_000,
            anchorRoot: String(repeating: "11", count: 32)
        )
    }

    private func makeSynchronizer(
        rustBackend: ZcashRustBackendWeldingMock,
        transactionEncoder: RetryTestTransactionEncoder,
        syncStatus: InternalSyncStatus = .synced,
        pirWitnessFetcher: @escaping SDKSynchronizer.PIRWitnessFetcher = { _, _, _ in
            preconditionFailure("Unexpected PIR witness fetch")
        }
    ) async throws -> (SDKSynchronizer, SDKFlags) {
        let network = ZcashNetworkBuilder.network(for: .testnet)
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackend }

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: testTempDirectory.appendingPathComponent("data.db"),
            torDirURL: testTempDirectory.appendingPathComponent("tor"),
            endpoint: LightWalletEndpointBuilder.default,
            network: network,
            spendParamsURL: SaplingParamsSourceURL.tests.spendParamFileURL,
            outputParamsURL: SaplingParamsSourceURL.tests.outputParamFileURL,
            saplingParamsSourceURL: .tests,
            alias: .default,
            loggingPolicy: .noLogging,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        let blockProcessor = CompactBlockProcessor(
            initializer: initializer,
            walletBirthdayProvider: { 1 }
        )
        let synchronizer = SDKSynchronizer(
            status: syncStatus,
            initializer: initializer,
            transactionEncoder: transactionEncoder,
            transactionRepository: initializer.transactionRepository,
            blockProcessor: blockProcessor,
            syncSessionTicker: .live,
            pirWitnessFetcher: pirWitnessFetcher
        )
        await synchronizer.updateStatus(syncStatus, updateExternalStatus: false)

        return (synchronizer, initializer.container.resolve(SDKFlags.self))
    }

    func testCreateProposedTransactionsRetriesOnceAfterPIRMismatch() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let transactionEncoder = RetryTestTransactionEncoder()
        transactionEncoder.createResults = [
            .failure(ZcashError.rustCreateToAddress("Selected Orchard inputs were backed by incompatible PIR witness anchors.")),
            .success([])
        ]
        let note = makeNotePosition()
        rustBackend.getPIRWitnessNotesReturnValue = [note]

        let witnessEntry = makeWitnessEntry()
        let (synchronizer, sdkFlags) = try await makeSynchronizer(
            rustBackend: rustBackend,
            transactionEncoder: transactionEncoder,
            pirWitnessFetcher: { _, _, _ in
                return PIRWitnessResult(witnesses: [witnessEntry])
            }
        )
        await sdkFlags.setPIRWitnessServerURL("http://localhost:8080")

        let stream = try await synchronizer.createProposedTransactions(
            proposal: makeProposal(),
            spendingKey: try makeSpendingKey(network: synchronizer.network)
        )

        var iterator = stream.makeAsyncIterator()
        let next = try await iterator.next()
        XCTAssertNil(next)
        XCTAssertEqual(transactionEncoder.createProposedTransactionsCallsCount, 2)
        XCTAssertEqual(rustBackend.getPIRWitnessNotesCallsCount, 1)
        XCTAssertEqual(rustBackend.insertPIRWitnessesCallsCount, 1)
        XCTAssertEqual(rustBackend.insertPIRWitnessesReceivedWitnesses, [witnessEntry])
    }

    func testCreateProposedTransactionsDoesNotRetryForNonPIRFailure() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let transactionEncoder = RetryTestTransactionEncoder()
        transactionEncoder.createResults = [
            .failure(ZcashError.rustCreateToAddress("proposal construction failed"))
        ]
        let (synchronizer, _) = try await makeSynchronizer(
            rustBackend: rustBackend,
            transactionEncoder: transactionEncoder
        )

        do {
            _ = try await synchronizer.createProposedTransactions(
                proposal: makeProposal(),
                spendingKey: try makeSpendingKey(network: synchronizer.network)
            )
            XCTFail("Expected transaction creation to fail")
        } catch let ZcashError.rustCreateToAddress(message) {
            XCTAssertEqual(message, "proposal construction failed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(transactionEncoder.createProposedTransactionsCallsCount, 1)
        XCTAssertEqual(rustBackend.getPIRWitnessNotesCallsCount, 0)
        XCTAssertEqual(rustBackend.insertPIRWitnessesCallsCount, 0)
    }

    func testCreateProposedTransactionsDoesNotRetryWithoutWitnessServerURL() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let transactionEncoder = RetryTestTransactionEncoder()
        transactionEncoder.createResults = [
            .failure(ZcashError.rustCreateToAddress("Selected Orchard inputs were backed by incompatible PIR witness anchors."))
        ]
        let (synchronizer, _) = try await makeSynchronizer(
            rustBackend: rustBackend,
            transactionEncoder: transactionEncoder
        )

        do {
            _ = try await synchronizer.createProposedTransactions(
                proposal: makeProposal(),
                spendingKey: try makeSpendingKey(network: synchronizer.network)
            )
            XCTFail("Expected transaction creation to fail")
        } catch let ZcashError.rustCreateToAddress(message) {
            XCTAssertEqual(message, "Selected Orchard inputs were backed by incompatible PIR witness anchors.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(transactionEncoder.createProposedTransactionsCallsCount, 1)
        XCTAssertEqual(rustBackend.getPIRWitnessNotesCallsCount, 0)
        XCTAssertEqual(rustBackend.insertPIRWitnessesCallsCount, 0)
    }

    func testCreateProposedTransactionsDoesNotRetryWhenProposalHasNoPIRWitnessNotes() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let transactionEncoder = RetryTestTransactionEncoder()
        transactionEncoder.createResults = [
            .failure(ZcashError.rustCreateToAddress("All anchors must be equal"))
        ]
        rustBackend.getPIRWitnessNotesReturnValue = []

        let (synchronizer, sdkFlags) = try await makeSynchronizer(
            rustBackend: rustBackend,
            transactionEncoder: transactionEncoder
        )
        await sdkFlags.setPIRWitnessServerURL("http://localhost:8080")

        do {
            _ = try await synchronizer.createProposedTransactions(
                proposal: makeProposal(),
                spendingKey: try makeSpendingKey(network: synchronizer.network)
            )
            XCTFail("Expected transaction creation to fail")
        } catch let ZcashError.rustCreateToAddress(message) {
            XCTAssertEqual(message, "All anchors must be equal")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(transactionEncoder.createProposedTransactionsCallsCount, 1)
        XCTAssertEqual(rustBackend.getPIRWitnessNotesCallsCount, 1)
        XCTAssertEqual(rustBackend.insertPIRWitnessesCallsCount, 0)
    }

    func testCreateProposedTransactionsDoesNotLoopAfterSecondFailure() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let transactionEncoder = RetryTestTransactionEncoder()
        let witnessEntry = makeWitnessEntry()
        transactionEncoder.createResults = [
            .failure(ZcashError.rustCreateToAddress("Selected Orchard inputs were backed by incompatible PIR witness anchors.")),
            .failure(ZcashError.rustCreateToAddress("All anchors must be equal"))
        ]
        rustBackend.getPIRWitnessNotesReturnValue = [makeNotePosition()]

        let (synchronizer, sdkFlags) = try await makeSynchronizer(
            rustBackend: rustBackend,
            transactionEncoder: transactionEncoder,
            pirWitnessFetcher: { _, _, _ in
                PIRWitnessResult(witnesses: [witnessEntry])
            }
        )
        await sdkFlags.setPIRWitnessServerURL("http://localhost:8080")

        do {
            _ = try await synchronizer.createProposedTransactions(
                proposal: makeProposal(),
                spendingKey: try makeSpendingKey(network: synchronizer.network)
            )
            XCTFail("Expected second transaction creation attempt to fail")
        } catch let ZcashError.rustCreateToAddress(message) {
            XCTAssertEqual(message, "All anchors must be equal")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(transactionEncoder.createProposedTransactionsCallsCount, 2)
        XCTAssertEqual(rustBackend.getPIRWitnessNotesCallsCount, 1)
        XCTAssertEqual(rustBackend.insertPIRWitnessesCallsCount, 1)
    }

    // MARK: - Proactive alignment tests

    func testProactiveAlignmentFetchesWitnessesWhenSyncing() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let transactionEncoder = RetryTestTransactionEncoder()
        transactionEncoder.createResults = [.success([])]

        let note = makeNotePosition()
        rustBackend.getPIRWitnessNotesReturnValue = [note]

        let witnessEntry = makeWitnessEntry()
        var fetchCount = 0
        let (synchronizer, sdkFlags) = try await makeSynchronizer(
            rustBackend: rustBackend,
            transactionEncoder: transactionEncoder,
            syncStatus: .syncing(0.5, false),
            pirWitnessFetcher: { _, _, _ in
                fetchCount += 1
                return PIRWitnessResult(witnesses: [witnessEntry])
            }
        )
        await sdkFlags.setPIRWitnessServerURL("http://localhost:8080")

        let stream = try await synchronizer.createProposedTransactions(
            proposal: makeProposal(),
            spendingKey: try makeSpendingKey(network: synchronizer.network)
        )

        var iterator = stream.makeAsyncIterator()
        let next = try await iterator.next()
        XCTAssertNil(next)
        XCTAssertEqual(fetchCount, 1, "Proactive alignment should fetch witnesses once")
        XCTAssertEqual(transactionEncoder.createProposedTransactionsCallsCount, 1)
        XCTAssertEqual(rustBackend.insertPIRWitnessesCallsCount, 1)
    }

    func testProactiveAlignmentSkippedWhenSynced() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let transactionEncoder = RetryTestTransactionEncoder()
        transactionEncoder.createResults = [.success([])]
        rustBackend.getPIRWitnessNotesReturnValue = [makeNotePosition()]

        let (synchronizer, sdkFlags) = try await makeSynchronizer(
            rustBackend: rustBackend,
            transactionEncoder: transactionEncoder,
            syncStatus: .synced
        )
        await sdkFlags.setPIRWitnessServerURL("http://localhost:8080")

        let stream = try await synchronizer.createProposedTransactions(
            proposal: makeProposal(),
            spendingKey: try makeSpendingKey(network: synchronizer.network)
        )

        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        XCTAssertEqual(rustBackend.getPIRWitnessNotesCallsCount, 0, "Should not query notes when synced")
        XCTAssertEqual(rustBackend.insertPIRWitnessesCallsCount, 0)
    }

    func testProactiveAlignmentSkippedWithoutWitnessServerURL() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let transactionEncoder = RetryTestTransactionEncoder()
        transactionEncoder.createResults = [.success([])]

        let (synchronizer, _) = try await makeSynchronizer(
            rustBackend: rustBackend,
            transactionEncoder: transactionEncoder,
            syncStatus: .syncing(0.3, false)
        )

        let stream = try await synchronizer.createProposedTransactions(
            proposal: makeProposal(),
            spendingKey: try makeSpendingKey(network: synchronizer.network)
        )

        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        XCTAssertEqual(rustBackend.getPIRWitnessNotesCallsCount, 0, "Should not query notes without witness URL")
    }

    func testMixedCanonicalAndProvisionalWitnessInsertion() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let transactionEncoder = RetryTestTransactionEncoder()
        transactionEncoder.createResults = [.success([])]

        let canonicalNote = PIRNotePosition(id: 5, position: 100, value: 50_000)
        let provisionalNote = PIRNotePosition(id: -3, position: 200, value: 30_000)
        rustBackend.getPIRWitnessNotesReturnValue = [canonicalNote, provisionalNote]

        let canonicalWitness = PIRWitnessEntry(
            noteId: 5,
            position: 100,
            siblings: Array(repeating: String(repeating: "aa", count: 32), count: 32),
            anchorHeight: 2_000,
            anchorRoot: String(repeating: "bb", count: 32)
        )
        let provisionalWitness = PIRWitnessEntry(
            noteId: -3,
            position: 200,
            siblings: Array(repeating: String(repeating: "cc", count: 32), count: 32),
            anchorHeight: 2_000,
            anchorRoot: String(repeating: "dd", count: 32)
        )

        var receivedProvisionalNoteId: Int64?
        rustBackend.markProvisionalNoteWitnessedClosure = { noteId, _, _, _ in
            receivedProvisionalNoteId = noteId
        }

        let (synchronizer, sdkFlags) = try await makeSynchronizer(
            rustBackend: rustBackend,
            transactionEncoder: transactionEncoder,
            syncStatus: .syncing(0.5, false),
            pirWitnessFetcher: { _, _, _ in
                PIRWitnessResult(witnesses: [canonicalWitness, provisionalWitness])
            }
        )
        await sdkFlags.setPIRWitnessServerURL("http://localhost:8080")

        let stream = try await synchronizer.createProposedTransactions(
            proposal: makeProposal(),
            spendingKey: try makeSpendingKey(network: synchronizer.network)
        )

        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()

        XCTAssertEqual(rustBackend.insertPIRWitnessesCallsCount, 1, "Canonical witness should use insertPIRWitnesses")
        XCTAssertEqual(
            rustBackend.insertPIRWitnessesReceivedWitnesses,
            [canonicalWitness],
            "Only canonical (positive ID) witnesses should go through insertPIRWitnesses"
        )
        XCTAssertEqual(rustBackend.markProvisionalNoteWitnessedCallsCount, 1, "Provisional witness should use markProvisionalNoteWitnessed")
        XCTAssertEqual(receivedProvisionalNoteId, 3, "Provisional note ID should be passed as abs(noteId)")
    }
}
