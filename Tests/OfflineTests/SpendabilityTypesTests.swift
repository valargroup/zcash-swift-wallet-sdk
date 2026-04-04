//
//  SpendabilityTypesTests.swift
//
//
//  Tests for spendability PIR types used across the FFI boundary.
//  Verifies JSON encoding/decoding matches the Rust serde format
//  produced by spendability.rs and the PIR FFI functions in lib.rs.
//

import XCTest
@testable import ZcashLightClientKit

final class SpendabilityTypesTests: XCTestCase {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    // MARK: - PIRUnspentNote

    func testPIRUnspentNoteDecodesFromRustJSON() throws {
        let json = """
        {"id":42,"nf":[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31],"value":50000}
        """.data(using: .utf8)!

        let note = try decoder.decode(PIRUnspentNote.self, from: json)

        XCTAssertEqual(note.id, 42)
        XCTAssertEqual(note.nf, Array(0...31))
        XCTAssertEqual(note.value, 50_000)
    }

    func testPIRUnspentNoteArrayDecodesFromRustJSON() throws {
        let json = """
        [
          {"id":1,"nf":[170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170,170],"value":10000},
          {"id":2,"nf":[187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187,187],"value":20000}
        ]
        """.data(using: .utf8)!

        let notes = try decoder.decode([PIRUnspentNote].self, from: json)

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].id, 1)
        XCTAssertEqual(notes[0].nf, [UInt8](repeating: 0xAA, count: 32))
        XCTAssertEqual(notes[0].value, 10_000)
        XCTAssertEqual(notes[1].id, 2)
        XCTAssertEqual(notes[1].nf, [UInt8](repeating: 0xBB, count: 32))
        XCTAssertEqual(notes[1].value, 20_000)
    }

    func testPIRUnspentNoteRoundTrip() throws {
        let note = PIRUnspentNote(id: 7, nf: [UInt8](repeating: 0xFF, count: 32), value: 100_000)
        let data = try encoder.encode(note)
        let decoded = try decoder.decode(PIRUnspentNote.self, from: data)

        XCTAssertEqual(note, decoded)
    }

    func testPIRUnspentNoteEmptyArray() throws {
        let json = "[]".data(using: .utf8)!
        let notes = try decoder.decode([PIRUnspentNote].self, from: json)
        XCTAssertTrue(notes.isEmpty)
    }

    // MARK: - PIRNullifierCheckResult

    func testPIRNullifierCheckResultDecodesFromRustJSON() throws {
        let json = """
        {"earliest_height":100,"latest_height":200,"spent":[true,false,true]}
        """.data(using: .utf8)!

        let result = try decoder.decode(PIRNullifierCheckResult.self, from: json)

        XCTAssertEqual(result.earliestHeight, 100)
        XCTAssertEqual(result.latestHeight, 200)
        XCTAssertEqual(result.spent, [true, false, true])
    }

    func testPIRNullifierCheckResultEmptySpent() throws {
        let json = """
        {"earliest_height":0,"latest_height":0,"spent":[]}
        """.data(using: .utf8)!

        let result = try decoder.decode(PIRNullifierCheckResult.self, from: json)

        XCTAssertEqual(result.earliestHeight, 0)
        XCTAssertEqual(result.latestHeight, 0)
        XCTAssertTrue(result.spent.isEmpty)
    }

    func testPIRNullifierCheckResultEncodesSnakeCaseKeys() throws {
        let result = PIRNullifierCheckResult(earliestHeight: 500, latestHeight: 1000, spent: [false, true])
        let data = try encoder.encode(result)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNotNil(jsonObject["earliest_height"], "Expected snake_case key 'earliest_height'")
        XCTAssertNotNil(jsonObject["latest_height"], "Expected snake_case key 'latest_height'")
        XCTAssertNotNil(jsonObject["spent"])
        XCTAssertNil(jsonObject["earliestHeight"], "Should not use camelCase key")
    }

    func testPIRNullifierCheckResultRoundTrip() throws {
        let result = PIRNullifierCheckResult(earliestHeight: 42, latestHeight: 99, spent: [true, true, false])
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(PIRNullifierCheckResult.self, from: data)

        XCTAssertEqual(result, decoded)
    }

    // MARK: - SpendabilityResult

    func testSpendabilityResultDecodesFromRustJSON() throws {
        let json = """
        {"earliest_height":100,"latest_height":200,"spent_note_ids":[1,3],"total_spent_value":50000}
        """.data(using: .utf8)!

        let result = try decoder.decode(SpendabilityResult.self, from: json)

        XCTAssertEqual(result.earliestHeight, 100)
        XCTAssertEqual(result.latestHeight, 200)
        XCTAssertEqual(result.spentNoteIds, [1, 3])
        XCTAssertEqual(result.totalSpentValue, 50_000)
    }

    func testSpendabilityResultEmpty() throws {
        let result = SpendabilityResult(earliestHeight: 0, latestHeight: 0, spentNoteIds: [], totalSpentValue: 0)
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(SpendabilityResult.self, from: data)

        XCTAssertEqual(result, decoded)
        XCTAssertTrue(decoded.spentNoteIds.isEmpty)
        XCTAssertEqual(decoded.totalSpentValue, 0)
    }

    func testSpendabilityResultEncodesSnakeCaseKeys() throws {
        let result = SpendabilityResult(earliestHeight: 1, latestHeight: 2, spentNoteIds: [5], totalSpentValue: 999)
        let data = try encoder.encode(result)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNotNil(jsonObject["earliest_height"])
        XCTAssertNotNil(jsonObject["latest_height"])
        XCTAssertNotNil(jsonObject["spent_note_ids"])
        XCTAssertNotNil(jsonObject["total_spent_value"])
    }

    // MARK: - PIRPendingNote

    func testPIRPendingNoteDecodesFromRustJSON() throws {
        let json = """
        {"note_id":5,"value":10000}
        """.data(using: .utf8)!

        let note = try decoder.decode(PIRPendingNote.self, from: json)

        XCTAssertEqual(note.noteId, 5)
        XCTAssertEqual(note.value, 10_000)
    }

    func testPIRPendingNoteRoundTrip() throws {
        let note = PIRPendingNote(noteId: 99, value: 500_000)
        let data = try encoder.encode(note)
        let decoded = try decoder.decode(PIRPendingNote.self, from: data)

        XCTAssertEqual(note, decoded)
    }

    // MARK: - PIRPendingSpends

    func testPIRPendingSpendsDecodesFromRustJSON() throws {
        let json = """
        {"notes":[{"note_id":5,"value":10000},{"note_id":8,"value":30000}],"total_value":40000}
        """.data(using: .utf8)!

        let result = try decoder.decode(PIRPendingSpends.self, from: json)

        XCTAssertEqual(result.notes.count, 2)
        XCTAssertEqual(result.notes[0].noteId, 5)
        XCTAssertEqual(result.notes[0].value, 10_000)
        XCTAssertEqual(result.notes[1].noteId, 8)
        XCTAssertEqual(result.notes[1].value, 30_000)
        XCTAssertEqual(result.totalValue, 40_000)
    }

    func testPIRPendingSpendsEmpty() throws {
        let json = """
        {"notes":[],"total_value":0}
        """.data(using: .utf8)!

        let result = try decoder.decode(PIRPendingSpends.self, from: json)

        XCTAssertTrue(result.notes.isEmpty)
        XCTAssertEqual(result.totalValue, 0)
    }

    func testPIRPendingSpendsRoundTrip() throws {
        let result = PIRPendingSpends(
            notes: [PIRPendingNote(noteId: 1, value: 5000), PIRPendingNote(noteId: 2, value: 15000)],
            totalValue: 20000
        )
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(PIRPendingSpends.self, from: data)

        XCTAssertEqual(result, decoded)
    }

    func testPIRPendingSpendsEncodesSnakeCaseKeys() throws {
        let result = PIRPendingSpends(
            notes: [PIRPendingNote(noteId: 1, value: 100)],
            totalValue: 100
        )
        let data = try encoder.encode(result)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNotNil(jsonObject["total_value"])
        XCTAssertNil(jsonObject["totalValue"], "Should not use camelCase key")

        let notesArray = jsonObject["notes"] as! [[String: Any]]
        XCTAssertNotNil(notesArray[0]["note_id"])
        XCTAssertNil(notesArray[0]["noteId"], "Should not use camelCase key")
    }

    // MARK: - Cross-type consistency: notes → check → result pipeline

    func testThreePhasePipelineTypes() throws {
        let notes = [
            PIRUnspentNote(id: 1, nf: [UInt8](repeating: 0xAA, count: 32), value: 10_000),
            PIRUnspentNote(id: 2, nf: [UInt8](repeating: 0xBB, count: 32), value: 20_000),
            PIRUnspentNote(id: 3, nf: [UInt8](repeating: 0xCC, count: 32), value: 30_000)
        ]

        let checkResult = PIRNullifierCheckResult(
            earliestHeight: 100,
            latestHeight: 200,
            spent: [true, false, true]
        )

        XCTAssertEqual(notes.count, checkResult.spent.count, "Spent flags must be parallel to notes")

        let spentNotes = zip(notes, checkResult.spent).filter { $0.1 }
        let spentNoteIds = spentNotes.map(\.0.id)
        let totalSpentValue = spentNotes.map(\.0.value).reduce(0, +)

        XCTAssertEqual(spentNoteIds, [1, 3])
        XCTAssertEqual(totalSpentValue, 40_000)

        let finalResult = SpendabilityResult(
            earliestHeight: checkResult.earliestHeight,
            latestHeight: checkResult.latestHeight,
            spentNoteIds: spentNoteIds,
            totalSpentValue: totalSpentValue
        )

        XCTAssertEqual(finalResult.earliestHeight, 100)
        XCTAssertEqual(finalResult.latestHeight, 200)
        XCTAssertEqual(finalResult.spentNoteIds, [1, 3])
        XCTAssertEqual(finalResult.totalSpentValue, 40_000)
    }

    func testThreePhasePipelineNoNotesSpent() throws {
        let notes = [
            PIRUnspentNote(id: 1, nf: [UInt8](repeating: 0xAA, count: 32), value: 10_000),
            PIRUnspentNote(id: 2, nf: [UInt8](repeating: 0xBB, count: 32), value: 20_000)
        ]

        let checkResult = PIRNullifierCheckResult(
            earliestHeight: 50,
            latestHeight: 150,
            spent: [false, false]
        )

        let spentNotes = zip(notes, checkResult.spent).filter { $0.1 }
        XCTAssertTrue(spentNotes.isEmpty)
        XCTAssertEqual(spentNotes.map(\.0.value).reduce(0, +), 0)
    }

    func testThreePhasePipelineAllNotesSpent() throws {
        let notes = [
            PIRUnspentNote(id: 1, nf: [UInt8](repeating: 0xAA, count: 32), value: 10_000),
            PIRUnspentNote(id: 2, nf: [UInt8](repeating: 0xBB, count: 32), value: 20_000)
        ]

        let checkResult = PIRNullifierCheckResult(
            earliestHeight: 50,
            latestHeight: 150,
            spent: [true, true]
        )

        let spentNotes = zip(notes, checkResult.spent).filter { $0.1 }
        XCTAssertEqual(spentNotes.count, 2)
        XCTAssertEqual(spentNotes.map(\.0.id), [1, 2])
        XCTAssertEqual(spentNotes.map(\.0.value).reduce(0, +), 30_000)
    }
}
