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

// MARK: - Nullifier check result

/// Result of checking nullifiers against the PIR server.
public struct PIRNullifierCheckResult: Codable, Sendable, Equatable {
    public let earliestHeight: UInt64
    public let latestHeight: UInt64
    /// Parallel to the input nullifiers: true = spent.
    public let spent: [Bool]

    enum CodingKeys: String, CodingKey {
        case earliestHeight = "earliest_height"
        case latestHeight = "latest_height"
        case spent
    }

    public init(earliestHeight: UInt64, latestHeight: UInt64, spent: [Bool]) {
        self.earliestHeight = earliestHeight
        self.latestHeight = latestHeight
        self.spent = spent
    }
}

// MARK: - Pending spends (PIR-detected but not yet confirmed by scanning)

/// A single note detected as spent by PIR that scanning has not yet confirmed.
public struct PIRPendingNote: Codable, Sendable, Equatable {
    public let noteId: Int64
    public let value: UInt64

    enum CodingKeys: String, CodingKey {
        case noteId = "note_id"
        case value
    }

    public init(noteId: Int64, value: UInt64) {
        self.noteId = noteId
        self.value = value
    }
}

/// Aggregated result of PIR-detected spends not yet confirmed by scanning.
public struct PIRPendingSpends: Codable, Sendable, Equatable {
    public let notes: [PIRPendingNote]
    public let totalValue: UInt64

    enum CodingKeys: String, CodingKey {
        case notes
        case totalValue = "total_value"
    }

    public init(notes: [PIRPendingNote], totalValue: UInt64) {
        self.notes = notes
        self.totalValue = totalValue
    }
}

// MARK: - Progress

/// Closure type for spendability check progress reporting.
public typealias SpendabilityProgressHandler = @Sendable (Double) -> Void
