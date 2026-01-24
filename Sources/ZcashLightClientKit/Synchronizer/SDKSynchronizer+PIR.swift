//
//  SDKSynchronizer+PIR.swift
//  ZcashLightClientKit
//
//  Created for PIR Integration Demo
//

import Foundation
import Combine

// MARK: - SDKSynchronizer PIR Extension

extension SDKSynchronizer {
    /// Create a PIR checker for privacy-preserving nullifier lookups
    /// - Parameter configuration: Optional PIR configuration
    /// - Returns: A configured PIRChecker instance
    public func createPIRChecker(configuration: PIRConfiguration = .default) -> PIRChecker {
        return PIRChecker(
            lightWalletService: initializer.lightWalletService,
            configuration: configuration,
            logger: logger
        )
    }

    /// Stream of PIR checking events for observing PIR operations
    public struct PIREvent: Equatable {
        public let timestamp: Date
        public let nullifierHex: String
        public let isSpent: Bool
        public let spentAtHeight: BlockHeight?
        public let queryStats: PIRQueryStats?

        public init(
            timestamp: Date = Date(),
            nullifierHex: String,
            isSpent: Bool,
            spentAtHeight: BlockHeight? = nil,
            queryStats: PIRQueryStats? = nil
        ) {
            self.timestamp = timestamp
            self.nullifierHex = nullifierHex
            self.isSpent = isSpent
            self.spentAtHeight = spentAtHeight
            self.queryStats = queryStats
        }
    }

    /// Check if a note's nullifier has been spent using PIR
    /// - Parameters:
    ///   - nullifierHex: The nullifier hex string to check
    ///   - pirChecker: The PIR checker to use for the query
    /// - Returns: PIRCheckResult with the query results
    public func checkNullifierWithPIR(
        _ nullifierHex: String,
        using pirChecker: PIRChecker
    ) async throws -> PIRCheckResult {
        logger.debug("SDKSynchronizer: Checking nullifier via PIR: \(nullifierHex.prefix(16))...")
        return try await pirChecker.checkNullifier(nullifierHex)
    }

    /// Check multiple nullifiers using PIR
    /// - Parameters:
    ///   - nullifiers: Array of nullifier hex strings
    ///   - pirChecker: The PIR checker to use
    /// - Returns: Array of PIRCheckResults
    public func checkNullifiersWithPIR(
        _ nullifiers: [String],
        using pirChecker: PIRChecker
    ) async throws -> [PIRCheckResult] {
        logger.debug("SDKSynchronizer: Checking \(nullifiers.count) nullifiers via PIR")
        return try await pirChecker.checkNullifiers(nullifiers)
    }

    /// Get the PIR status from the server
    /// - Returns: PirStatusResponse with server PIR status
    public func getPIRStatus() async throws -> PirStatusResponse {
        return try await initializer.lightWalletService.getPirStatus(mode: .direct)
    }

    /// Get the PIR parameters from the server
    /// - Returns: PirParamsResponse with PIR configuration
    public func getPIRParams() async throws -> PirParamsResponse {
        return try await initializer.lightWalletService.getPirParams(mode: .direct)
    }

    /// Determine whether to use PIR or trial decryption for a given block height
    /// - Parameters:
    ///   - height: The block height to check
    ///   - pirCutoffHeight: The PIR cutoff height from params
    /// - Returns: true if PIR should be used (height <= cutoff), false for trial decryption
    public func shouldUsePIR(forHeight height: BlockHeight, pirCutoffHeight: BlockHeight) -> Bool {
        return height <= pirCutoffHeight
    }
}

// MARK: - PIR Demo Helper

/// Helper class for running PIR demos
public class PIRDemoRunner {
    private let synchronizer: SDKSynchronizer
    private let pirChecker: PIRChecker
    private let logger: Logger

    /// Stream of PIR events during demo
    public let eventSubject = PassthroughSubject<SDKSynchronizer.PIREvent, Never>()
    public var eventStream: AnyPublisher<SDKSynchronizer.PIREvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    public init(synchronizer: SDKSynchronizer, configuration: PIRConfiguration = .default) {
        self.synchronizer = synchronizer
        self.pirChecker = synchronizer.createPIRChecker(configuration: configuration)
        self.logger = synchronizer.logger
    }

    /// Initialize the PIR system and prepare for queries
    public func initialize() async throws {
        logger.info("PIRDemoRunner: Initializing PIR system")
        try await pirChecker.initialize()
        logger.info("PIRDemoRunner: PIR system ready")
    }

    /// Run a demo PIR check on a nullifier
    /// - Parameter nullifierHex: The nullifier to check
    /// - Returns: The PIR check result
    public func checkNullifier(_ nullifierHex: String) async throws -> PIRCheckResult {
        logger.info("PIRDemoRunner: Running PIR query for \(nullifierHex.prefix(16))...")

        let result = try await pirChecker.checkNullifier(nullifierHex)

        // Emit event for observers
        eventSubject.send(SDKSynchronizer.PIREvent(
            nullifierHex: nullifierHex,
            isSpent: result.isSpent,
            spentAtHeight: result.spentAtHeight.map { BlockHeight($0) },
            queryStats: result.stats
        ))

        logger.info("PIRDemoRunner: Query complete - spent: \(result.isSpent)")
        return result
    }

    /// Get current PIR status
    public var status: PIRCheckerState {
        get async { await pirChecker.state }
    }

    /// Get PIR cutoff height
    public var cutoffHeight: BlockHeight? {
        get async { await pirChecker.pirCutoffHeight }
    }

    /// Reset the PIR system
    public func reset() async {
        await pirChecker.reset()
        logger.info("PIRDemoRunner: Reset complete")
    }
}
