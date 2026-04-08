// Swift types matching the JSON serde types in spendability.rs.
// All types are Codable for JSON serialization across the FFI boundary.

import Foundation

// MARK: - Result

/// Result of a spendability PIR check.
public struct SpendabilityResult: Codable, Sendable, Equatable {
    /// Earliest block height covered by the PIR database.
    public let earliestHeight: UInt64
    /// Latest block height covered by the PIR database.
    public let latestHeight: UInt64
    /// Note IDs whose nullifiers were found in the PIR database (i.e. spent).
    public let spentNoteIds: [Int64]
    /// Total zatoshi value of notes found spent by PIR.
    public let totalSpentValue: UInt64

    enum CodingKeys: String, CodingKey {
        case earliestHeight = "earliest_height"
        case latestHeight = "latest_height"
        case spentNoteIds = "spent_note_ids"
        case totalSpentValue = "total_spent_value"
    }

    public init(earliestHeight: UInt64, latestHeight: UInt64, spentNoteIds: [Int64], totalSpentValue: UInt64) {
        self.earliestHeight = earliestHeight
        self.latestHeight = latestHeight
        self.spentNoteIds = spentNoteIds
        self.totalSpentValue = totalSpentValue
    }
}

// MARK: - Unspent note

/// An unspent Orchard note with its nullifier, for PIR spend-checking.
public struct PIRUnspentNote: Codable, Sendable, Equatable {
    public let id: Int64
    /// Raw nullifier bytes (32 bytes).
    public let nf: [UInt8]
    public let value: UInt64

    public init(id: Int64, nf: [UInt8], value: UInt64) {
        self.id = id
        self.nf = nf
        self.value = value
    }
}

// MARK: - Spend metadata

/// Per-nullifier metadata returned by the PIR server when a nullifier is found spent.
public struct PIRSpendMetadata: Codable, Sendable, Equatable {
    /// Block height at which the note was spent.
    public let spendHeight: UInt32
    /// Global Orchard commitment-tree position of the first output in the spending transaction.
    public let firstOutputPosition: UInt32
    /// Number of Orchard actions in the spending transaction.
    public let actionCount: UInt8

    enum CodingKeys: String, CodingKey {
        case spendHeight = "spend_height"
        case firstOutputPosition = "first_output_position"
        case actionCount = "action_count"
    }

    public init(spendHeight: UInt32, firstOutputPosition: UInt32, actionCount: UInt8) {
        self.spendHeight = spendHeight
        self.firstOutputPosition = firstOutputPosition
        self.actionCount = actionCount
    }
}

// MARK: - Nullifier check result

/// Result of checking nullifiers against the PIR server.
public struct PIRNullifierCheckResult: Codable, Sendable, Equatable {
    public let earliestHeight: UInt64
    public let latestHeight: UInt64
    /// Parallel to the input nullifiers: non-nil = spent (with metadata), nil = not spent.
    public let spent: [PIRSpendMetadata?]

    enum CodingKeys: String, CodingKey {
        case earliestHeight = "earliest_height"
        case latestHeight = "latest_height"
        case spent
    }

    public init(earliestHeight: UInt64, latestHeight: UInt64, spent: [PIRSpendMetadata?]) {
        self.earliestHeight = earliestHeight
        self.latestHeight = latestHeight
        self.spent = spent
    }
}

// MARK: - Discovered change note

/// A change note discovered via PIR trial decryption and stored as a provisional
/// note in the wallet DB. Returned by `discoverChangeNotes`.
public struct PIRDiscoveredNote: Codable, Sendable, Equatable {
    /// Global commitment tree position of this note.
    public let position: UInt64
    /// Note value in zatoshis.
    public let value: UInt64
    /// Row ID in pir_provisional_notes (used for witness PIR).
    public let provisionalNoteId: Int64

    enum CodingKeys: String, CodingKey {
        case position
        case value
        case provisionalNoteId = "provisional_note_id"
    }

    public init(position: UInt64, value: UInt64, provisionalNoteId: Int64) {
        self.position = position
        self.value = value
        self.provisionalNoteId = provisionalNoteId
    }
}

// MARK: - Provisional note for PIR

/// A provisional note ready for PIR nullifier checking.
public struct PIRProvisionalNote: Codable, Sendable, Equatable {
    public let id: Int64
    /// Raw nullifier bytes (32 bytes).
    public let nf: [UInt8]
    public let value: UInt64
    /// The canonical `orchard_received_notes` ID that started this chain.
    public let spentNoteId: Int64
    /// This note's depth in the chain (1 = direct change from canonical).
    public let depth: UInt32

    enum CodingKeys: String, CodingKey {
        case id
        case nf
        case value
        case spentNoteId = "spent_note_id"
        case depth
    }

    public init(id: Int64, nf: [UInt8], value: UInt64, spentNoteId: Int64, depth: UInt32) {
        self.id = id
        self.nf = nf
        self.value = value
        self.spentNoteId = spentNoteId
        self.depth = depth
    }
}

// MARK: - Provisional PIR result

/// Result of a PIR nullifier check on a provisional note.
/// Used by `markProvisionalPIRResults` to update the DB.
public struct PIRProvisionalResult: Codable, Sendable, Equatable {
    /// Row ID of the provisional note.
    public let id: Int64
    /// Whether the provisional note was found spent by PIR.
    public let spent: Bool

    public init(id: Int64, spent: Bool) {
        self.id = id
        self.spent = spent
    }
}

// MARK: - Activity entry (PIR-derived transaction)

/// A PIR-derived transaction entry for the activity view. Represents a spending
/// transaction detected via PIR that the scanner has not yet confirmed.
public struct PIRActivityEntry: Codable, Sendable, Equatable {
    /// Hex-encoded 32-byte txid of the spending transaction.
    public let txHash: String
    /// Net amount sent (gross - change) in zatoshis.
    public let netValue: UInt64
    /// Total value of spent input notes in zatoshis.
    public let grossValue: UInt64
    /// Total value of change returned in zatoshis.
    public let changeValue: UInt64
    /// Fee in zatoshis, if available.
    public let fee: UInt64?
    /// Block height of the spending transaction.
    public let height: UInt32
    /// Unix timestamp of the block.
    public let blockTime: UInt32

    enum CodingKeys: String, CodingKey {
        case txHash = "tx_hash"
        case netValue = "net_value"
        case grossValue = "gross_value"
        case changeValue = "change_value"
        case fee
        case height
        case blockTime = "block_time"
    }

    /// The raw transaction ID bytes (32 bytes), decoded from the hex string.
    public var rawID: Data {
        let chars = Array(txHash)
        let byteCount = chars.count / 2
        var data = Data(capacity: byteCount)
        for i in stride(from: 0, to: chars.count - 1, by: 2) {
            if let byte = UInt8(String(chars[i...i + 1]), radix: 16) {
                data.append(byte)
            }
        }
        return data
    }

    public init(
        txHash: String,
        netValue: UInt64,
        grossValue: UInt64,
        changeValue: UInt64,
        fee: UInt64?,
        height: UInt32,
        blockTime: UInt32
    ) {
        self.txHash = txHash
        self.netValue = netValue
        self.grossValue = grossValue
        self.changeValue = changeValue
        self.fee = fee
        self.height = height
        self.blockTime = blockTime
    }
}

// MARK: - Progress

/// Closure type for spendability check progress reporting.
public typealias SpendabilityProgressHandler = @Sendable (Double) -> Void
