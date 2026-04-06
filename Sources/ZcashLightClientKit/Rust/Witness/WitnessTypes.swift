import Foundation

// MARK: - Note position (input to witness PIR)

/// An Orchard note that needs a PIR witness: has a tree position but the shard
/// containing it is not fully scanned.
public struct PIRNotePosition: Codable, Sendable, Equatable {
    public let id: Int64
    public let position: UInt64
    public let value: UInt64

    public init(id: Int64, position: UInt64, value: UInt64) {
        self.id = id
        self.position = position
        self.value = value
    }
}

// MARK: - Witness entry (output from PIR server / input to DB write)

/// A PIR-obtained witness for a single note. Sibling hashes are hex-encoded
/// 32-byte values ordered leaf-to-root.
public struct PIRWitnessEntry: Codable, Sendable, Equatable {
    public let noteId: Int64
    public let position: UInt64
    /// 32 sibling hashes, each a 64-char hex string (32 bytes).
    public let siblings: [String]
    public let anchorHeight: UInt64
    /// The tree root at `anchorHeight`, as a 64-char hex string.
    public let anchorRoot: String

    enum CodingKeys: String, CodingKey {
        case noteId = "note_id"
        case position
        case siblings
        case anchorHeight = "anchor_height"
        case anchorRoot = "anchor_root"
    }

    public init(noteId: Int64, position: UInt64, siblings: [String], anchorHeight: UInt64, anchorRoot: String) {
        self.noteId = noteId
        self.position = position
        self.siblings = siblings
        self.anchorHeight = anchorHeight
        self.anchorRoot = anchorRoot
    }
}

// MARK: - Witness fetch result (from PIR server)

/// Result of fetching witnesses from the PIR server.
public struct PIRWitnessResult: Codable, Sendable, Equatable {
    public let witnesses: [PIRWitnessEntry]

    public init(witnesses: [PIRWitnessEntry]) {
        self.witnesses = witnesses
    }
}

// MARK: - Witnessed note (DB query result for UI)

/// A note that has a PIR witness and is still unspent.
public struct PIRWitnessedNote: Codable, Sendable, Equatable {
    public let noteId: Int64
    public let value: UInt64
    public let anchorHeight: UInt64

    enum CodingKeys: String, CodingKey {
        case noteId = "note_id"
        case value
        case anchorHeight = "anchor_height"
    }

    public init(noteId: Int64, value: UInt64, anchorHeight: UInt64) {
        self.noteId = noteId
        self.value = value
        self.anchorHeight = anchorHeight
    }
}

// MARK: - Orchestration result (returned to app layer)

/// Result of `fetchNoteWitnesses` — notes for which witnesses were obtained.
public struct WitnessResult: Sendable, Equatable {
    public let witnessedNoteIds: [Int64]
    public let totalWitnessedValue: UInt64

    public init(witnessedNoteIds: [Int64], totalWitnessedValue: UInt64) {
        self.witnessedNoteIds = witnessedNoteIds
        self.totalWitnessedValue = totalWitnessedValue
    }
}
