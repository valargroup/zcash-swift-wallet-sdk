//
//  PIRChecker.swift
//  ZcashLightClientKit
//
//  Created for PIR Integration Demo
//

import Foundation

// Import the PIR FFI types from the Swift bindings
// The bindings file is at PIR/FFI/NullifierPIR.swift

// MARK: - PIR Configuration

/// Configuration for PIR operations
public struct PIRConfiguration {
    /// Preferred PIR protocol
    public enum PIRProtocol: String {
        case inspire = "inspire"
        case ypir = "ypir"
    }

    /// The preferred protocol to use for PIR queries
    public let preferredProtocol: PIRProtocol

    /// Whether to precompute keys in the background
    public let backgroundKeyPrecomputation: Bool

    /// Maximum number of nullifiers to check in a single batch
    public let maxBatchSize: Int

    public init(
        preferredProtocol: PIRProtocol = .inspire,
        backgroundKeyPrecomputation: Bool = true,
        maxBatchSize: Int = 10
    ) {
        self.preferredProtocol = preferredProtocol
        self.backgroundKeyPrecomputation = backgroundKeyPrecomputation
        self.maxBatchSize = maxBatchSize
    }

    public static let `default` = PIRConfiguration()
}

// MARK: - PIR State

/// Represents the current state of the PIR checker
public enum PIRCheckerState: Equatable {
    case uninitialized
    case fetchingParams
    case initializingCrypto
    case precomputingKeys
    case ready
    case checking(nullifier: String)
    case error(String)
}

// MARK: - PIR Result

/// Result of checking a nullifier via PIR
public struct PIRCheckResult: Equatable {
    /// The nullifier that was checked (hex string)
    public let nullifierHex: String

    /// Whether the nullifier was found to be spent
    public let isSpent: Bool

    /// Block height where the nullifier was spent (if spent)
    public let spentAtHeight: UInt64?

    /// Transaction index within the block (if spent)
    public let txIndex: UInt32?

    /// Statistics about the query
    public let stats: PIRQueryStats
}

/// Statistics for a PIR query
public struct PIRQueryStats: Equatable {
    /// Bytes uploaded (query size)
    public let uploadBytes: UInt64

    /// Bytes downloaded (response size)
    public let downloadBytes: UInt64

    /// Time to generate the query (milliseconds)
    public let queryGenMs: Double

    /// Time to decrypt the response (milliseconds)
    public let decryptMs: Double

    /// Total round-trip time (milliseconds)
    public let totalMs: Double
}

// MARK: - PIR Checker Protocol

/// Protocol for PIR checking operations
public protocol PIRChecking: Actor {
    /// Current state of the PIR checker
    var state: PIRCheckerState { get }

    /// PIR parameters from the server (nil if not fetched)
    var pirParams: PirParamsResponse? { get }

    /// PIR cutoff height - use PIR below this, trial decryption above
    var pirCutoffHeight: BlockHeight? { get }

    /// Whether the PIR checker is ready to process queries
    var isReady: Bool { get }

    /// Initialize the PIR checker by fetching params and setting up crypto
    func initialize() async throws

    /// Check if a nullifier has been spent using PIR
    /// - Parameter nullifierHex: The nullifier as a hex string
    /// - Returns: The PIR check result
    func checkNullifier(_ nullifierHex: String) async throws -> PIRCheckResult

    /// Check multiple nullifiers using PIR
    /// - Parameter nullifiers: Array of nullifier hex strings
    /// - Returns: Array of PIR check results
    func checkNullifiers(_ nullifiers: [String]) async throws -> [PIRCheckResult]

    /// Reset the PIR checker state
    func reset() async
}

// MARK: - PIR Checker Implementation

/// PIR checker that coordinates crypto operations with network requests
public actor PIRChecker: PIRChecking {

    // MARK: - Properties

    private let lightWalletService: LightWalletService
    private let configuration: PIRConfiguration
    private let logger: Logger

    public private(set) var state: PIRCheckerState = .uninitialized
    public private(set) var pirParams: PirParamsResponse?

    public var pirCutoffHeight: BlockHeight? {
        guard let params = pirParams else { return nil }
        return BlockHeight(params.pirCutoffHeight)
    }

    public var isReady: Bool {
        state == .ready
    }

    /// FFI crypto client for PIR operations
    private var cryptoClient: PirCryptoClient?

    // MARK: - Initialization

    init(
        lightWalletService: LightWalletService,
        configuration: PIRConfiguration = .default,
        logger: Logger
    ) {
        self.lightWalletService = lightWalletService
        self.configuration = configuration
        self.logger = logger
    }

    // MARK: - PIRChecking Protocol

    public func initialize() async throws {
        logger.debug("PIRChecker: Starting initialization")
        state = .fetchingParams

        do {
            // Fetch PIR params from server
            pirParams = try await lightWalletService.getPirParams(mode: .direct)
            logger.debug("PIRChecker: Fetched params - cutoff height: \(pirParams?.pirCutoffHeight ?? 0)")

            guard let params = pirParams, params.pirReady else {
                throw PIRCheckerError.pirNotAvailable
            }

            // Initialize crypto client
            state = .initializingCrypto
            try await initializeCryptoClient()

            // Precompute keys if configured
            if configuration.backgroundKeyPrecomputation {
                state = .precomputingKeys
                try await precomputeKeys()
            }

            state = .ready
            logger.debug("PIRChecker: Initialization complete")

        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    public func checkNullifier(_ nullifierHex: String) async throws -> PIRCheckResult {
        guard isReady else {
            throw PIRCheckerError.notReady
        }

        state = .checking(nullifier: nullifierHex)
        defer { state = .ready }

        let startTime = Date()

        do {
            let result = try await performPIRQuery(nullifierHex: nullifierHex)

            let totalMs = Date().timeIntervalSince(startTime) * 1000

            logger.debug("PIRChecker: Checked nullifier \(nullifierHex.prefix(16))... - spent: \(result.isSpent)")

            return PIRCheckResult(
                nullifierHex: nullifierHex,
                isSpent: result.isSpent,
                spentAtHeight: result.spentAtHeight,
                txIndex: result.txIndex,
                stats: PIRQueryStats(
                    uploadBytes: result.stats.uploadBytes,
                    downloadBytes: result.stats.downloadBytes,
                    queryGenMs: result.stats.queryGenMs,
                    decryptMs: result.stats.decryptMs,
                    totalMs: totalMs
                )
            )
        } catch {
            logger.error("PIRChecker: Query failed for \(nullifierHex.prefix(16))...: \(error)")
            throw error
        }
    }

    public func checkNullifiers(_ nullifiers: [String]) async throws -> [PIRCheckResult] {
        guard isReady else {
            throw PIRCheckerError.notReady
        }

        var results: [PIRCheckResult] = []

        // Process in batches
        for batch in nullifiers.chunked(into: configuration.maxBatchSize) {
            for nullifier in batch {
                let result = try await checkNullifier(nullifier)
                results.append(result)
            }
        }

        return results
    }

    public func reset() async {
        state = .uninitialized
        pirParams = nil
        cryptoClient = nil
        logger.debug("PIRChecker: Reset complete")
    }

    // MARK: - Private Methods

    private func initializeCryptoClient() async throws {
        guard let params = pirParams else {
            throw PIRCheckerError.cryptoInitFailed("No PIR params available")
        }

        // Create the FFI crypto client
        cryptoClient = PirCryptoClient()

        // Determine protocol based on which params are available
        // Use InsPIRe if available (preferred), otherwise YPIR
        let protocolName: String
        if params.hasInspireParams {
            protocolName = "inspire"
        } else {
            protocolName = "ypir"
        }

        // Build params JSON manually from protobuf fields
        let paramsJson = buildParamsJson(from: params, protocolName: protocolName)

        // Initialize with params from server
        let ffiParams = FfiPirParams(
            pirCutoffHeight: params.pirCutoffHeight,
            protocol: protocolName,
            paramsJson: paramsJson
        )

        do {
            try cryptoClient?.initialize(params: ffiParams)
            logger.debug("PIRChecker: Crypto client initialized with protocol: \(protocolName)")
        } catch {
            throw PIRCheckerError.cryptoInitFailed("FFI initialization failed: \(error)")
        }
    }

    private func buildParamsJson(from params: PirParamsResponse, protocolName: String) -> String {
        // Build JSON structure expected by the FFI client
        var json: [String: Any] = [
            "pir_cutoff_height": params.pirCutoffHeight,
            "num_nullifiers": params.numNullifiers,
            "pir_ready": params.pirReady
        ]

        // Add Cuckoo params
        if params.hasCuckooParams {
            let cuckoo = params.cuckooParams
            json["cuckoo_params"] = [
                "num_buckets": cuckoo.numBuckets,
                "bucket_size": cuckoo.bucketSize,
                "hash_seed": cuckoo.hashSeed.base64EncodedString(),
                "num_hash_functions": cuckoo.numHashFunctions
            ]
        }

        // Add protocol-specific params
        if protocolName == "inspire", params.hasInspireParams {
            let inspire = params.inspireParams
            json["inspire_params"] = [
                "num_rows": inspire.numRows,
                "num_cols": inspire.numCols,
                "element_size": inspire.elementSize,
                "factor": inspire.factor
            ]
        } else if params.hasYpirParams {
            let ypir = params.ypirParams
            json["ypir_params"] = [
                "num_rows": ypir.numRows,
                "num_cols": ypir.numCols,
                "element_size": ypir.elementSize
            ]
        }

        // Convert to JSON string
        if let jsonData = try? JSONSerialization.data(withJSONObject: json),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return "{}"
    }

    private func precomputeKeys() async throws {
        guard let client = cryptoClient else {
            throw PIRCheckerError.cryptoInitFailed("Crypto client not initialized")
        }

        do {
            // This is CPU-intensive (~3s for InsPIRe) - runs on background queue
            try await Task.detached(priority: .userInitiated) {
                try client.precomputeKeys()
            }.value
            logger.debug("PIRChecker: Keys precomputed successfully")
        } catch {
            throw PIRCheckerError.cryptoInitFailed("Key precomputation failed: \(error)")
        }
    }

    private func performPIRQuery(nullifierHex: String) async throws -> (
        isSpent: Bool,
        spentAtHeight: UInt64?,
        txIndex: UInt32?,
        stats: (uploadBytes: UInt64, downloadBytes: UInt64, queryGenMs: Double, decryptMs: Double)
    ) {
        guard let client = cryptoClient else {
            throw PIRCheckerError.notReady
        }

        // 1. Generate PIR query using crypto client
        let queryGenStart = Date()
        let query: FfiPirQuery
        do {
            query = try client.generateQuery(nullifierHex: nullifierHex)
        } catch {
            throw PIRCheckerError.queryFailed("Query generation failed: \(error)")
        }
        let queryGenMs = Date().timeIntervalSince(queryGenStart) * 1000

        // 2. Send query to server based on protocol
        let responseData: Data
        if configuration.preferredProtocol == .inspire {
            responseData = try await lightWalletService.inspireQuery(query.queryBytes, mode: .direct)
        } else {
            responseData = try await lightWalletService.ypirQuery(query.queryBytes, mode: .direct)
        }

        // 3. Decrypt response using crypto client
        let decryptStart = Date()
        let spentInfo: FfiSpentInfo?
        do {
            spentInfo = try client.decryptResponse(responseBytes: responseData, nullifierHex: nullifierHex)
        } catch {
            throw PIRCheckerError.queryFailed("Response decryption failed: \(error)")
        }
        let decryptMs = Date().timeIntervalSince(decryptStart) * 1000

        return (
            isSpent: spentInfo != nil,
            spentAtHeight: spentInfo?.blockHeight,
            txIndex: spentInfo?.txIndex,
            stats: (
                uploadBytes: UInt64(query.queryBytes.count),
                downloadBytes: UInt64(responseData.count),
                queryGenMs: queryGenMs,
                decryptMs: decryptMs
            )
        )
    }
}

// MARK: - PIR Checker Error

public enum PIRCheckerError: Error, LocalizedError {
    case notReady
    case pirNotAvailable
    case cryptoInitFailed(String)
    case queryFailed(String)
    case invalidNullifier(String)

    public var errorDescription: String? {
        switch self {
        case .notReady:
            return "PIR checker is not ready. Call initialize() first."
        case .pirNotAvailable:
            return "PIR service is not available on the server."
        case .cryptoInitFailed(let msg):
            return "Failed to initialize PIR crypto: \(msg)"
        case .queryFailed(let msg):
            return "PIR query failed: \(msg)"
        case .invalidNullifier(let msg):
            return "Invalid nullifier: \(msg)"
        }
    }
}

// MARK: - Array Extension

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
