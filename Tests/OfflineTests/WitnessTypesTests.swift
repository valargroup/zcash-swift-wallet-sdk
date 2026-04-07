import XCTest
@testable import ZcashLightClientKit

final class WitnessTypesTests: XCTestCase {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    // MARK: - PIRNotePosition

    func testPIRNotePositionDecodesFromRustJSON() throws {
        let json = """
        {"id":42,"position":1000,"value":50000}
        """.data(using: .utf8)!

        let note = try decoder.decode(PIRNotePosition.self, from: json)

        XCTAssertEqual(note.id, 42)
        XCTAssertEqual(note.position, 1000)
        XCTAssertEqual(note.value, 50_000)
    }

    func testPIRNotePositionArrayDecodesFromRustJSON() throws {
        let json = """
        [
          {"id":1,"position":100,"value":10000},
          {"id":2,"position":200,"value":20000}
        ]
        """.data(using: .utf8)!

        let notes = try decoder.decode([PIRNotePosition].self, from: json)

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].id, 1)
        XCTAssertEqual(notes[0].position, 100)
        XCTAssertEqual(notes[0].value, 10_000)
        XCTAssertEqual(notes[1].id, 2)
        XCTAssertEqual(notes[1].position, 200)
        XCTAssertEqual(notes[1].value, 20_000)
    }

    func testPIRNotePositionRoundTrip() throws {
        let note = PIRNotePosition(id: 7, position: 999, value: 100_000)
        let data = try encoder.encode(note)
        let decoded = try decoder.decode(PIRNotePosition.self, from: data)

        XCTAssertEqual(note, decoded)
    }

    func testPIRNotePositionEmptyArray() throws {
        let json = "[]".data(using: .utf8)!
        let notes = try decoder.decode([PIRNotePosition].self, from: json)
        XCTAssertTrue(notes.isEmpty)
    }

    // MARK: - PIRWitnessEntry

    func testPIRWitnessEntryDecodesFromRustJSON() throws {
        let sibling = String(repeating: "aa", count: 32)
        let root = String(repeating: "bb", count: 32)
        let json = """
        {"note_id":42,"position":1000,"siblings":["\(sibling)"],"anchor_height":3200000,"anchor_root":"\(root)"}
        """.data(using: .utf8)!

        let entry = try decoder.decode(PIRWitnessEntry.self, from: json)

        XCTAssertEqual(entry.noteId, 42)
        XCTAssertEqual(entry.position, 1000)
        XCTAssertEqual(entry.siblings.count, 1)
        XCTAssertEqual(entry.siblings[0], sibling)
        XCTAssertEqual(entry.anchorHeight, 3_200_000)
        XCTAssertEqual(entry.anchorRoot, root)
    }

    func testPIRWitnessEntryEncodesSnakeCaseKeys() throws {
        let entry = PIRWitnessEntry(
            noteId: 1,
            position: 500,
            siblings: [String(repeating: "cc", count: 32)],
            anchorHeight: 100,
            anchorRoot: String(repeating: "dd", count: 32)
        )
        let data = try encoder.encode(entry)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNotNil(jsonObject["note_id"], "Expected snake_case key 'note_id'")
        XCTAssertNotNil(jsonObject["anchor_height"], "Expected snake_case key 'anchor_height'")
        XCTAssertNotNil(jsonObject["anchor_root"], "Expected snake_case key 'anchor_root'")
        XCTAssertNil(jsonObject["noteId"], "Should not use camelCase key")
        XCTAssertNil(jsonObject["anchorHeight"], "Should not use camelCase key")
        XCTAssertNil(jsonObject["anchorRoot"], "Should not use camelCase key")
    }

    func testPIRWitnessEntryRoundTrip() throws {
        let siblings = (0..<32).map { _ in String(repeating: "ab", count: 32) }
        let entry = PIRWitnessEntry(
            noteId: 99,
            position: 12345,
            siblings: siblings,
            anchorHeight: 3_200_000,
            anchorRoot: String(repeating: "ff", count: 32)
        )
        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(PIRWitnessEntry.self, from: data)

        XCTAssertEqual(entry, decoded)
    }

    // MARK: - PIRWitnessResult

    func testPIRWitnessResultDecodesFromRustJSON() throws {
        let sibling = String(repeating: "aa", count: 32)
        let root = String(repeating: "bb", count: 32)
        let json = """
        {"witnesses":[{"note_id":42,"position":1000,"siblings":["\(sibling)"],"anchor_height":3200000,"anchor_root":"\(root)"}]}
        """.data(using: .utf8)!

        let result = try decoder.decode(PIRWitnessResult.self, from: json)

        XCTAssertEqual(result.witnesses.count, 1)
        XCTAssertEqual(result.witnesses[0].noteId, 42)
        XCTAssertEqual(result.witnesses[0].anchorRoot, root)
    }

    func testPIRWitnessResultEmpty() throws {
        let json = """
        {"witnesses":[]}
        """.data(using: .utf8)!

        let result = try decoder.decode(PIRWitnessResult.self, from: json)
        XCTAssertTrue(result.witnesses.isEmpty)
    }

    func testPIRWitnessResultRoundTrip() throws {
        let result = PIRWitnessResult(witnesses: [
            PIRWitnessEntry(
                noteId: 1,
                position: 100,
                siblings: [String(repeating: "aa", count: 32)],
                anchorHeight: 500,
                anchorRoot: String(repeating: "bb", count: 32)
            )
        ])
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(PIRWitnessResult.self, from: data)

        XCTAssertEqual(result, decoded)
    }

    // MARK: - PIRWitnessedNote

    func testPIRWitnessedNoteDecodesFromRustJSON() throws {
        let json = """
        {"note_id":5,"value":10000,"anchor_height":3200000}
        """.data(using: .utf8)!

        let note = try decoder.decode(PIRWitnessedNote.self, from: json)

        XCTAssertEqual(note.noteId, 5)
        XCTAssertEqual(note.value, 10_000)
        XCTAssertEqual(note.anchorHeight, 3_200_000)
    }

    func testPIRWitnessedNoteEncodesSnakeCaseKeys() throws {
        let note = PIRWitnessedNote(noteId: 1, value: 100, anchorHeight: 500)
        let data = try encoder.encode(note)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNotNil(jsonObject["note_id"], "Expected snake_case key 'note_id'")
        XCTAssertNotNil(jsonObject["anchor_height"], "Expected snake_case key 'anchor_height'")
        XCTAssertNil(jsonObject["noteId"], "Should not use camelCase key")
        XCTAssertNil(jsonObject["anchorHeight"], "Should not use camelCase key")
    }

    func testPIRWitnessedNoteRoundTrip() throws {
        let note = PIRWitnessedNote(
            noteId: 99,
            value: 500_000,
            anchorHeight: 3_200_000
        )
        let data = try encoder.encode(note)
        let decoded = try decoder.decode(PIRWitnessedNote.self, from: data)

        XCTAssertEqual(note, decoded)
    }

    // MARK: - WitnessResult (in-process only, not Codable)

    func testWitnessResultEquality() {
        let a = WitnessResult(witnessedNoteIds: [1, 2, 3], totalWitnessedValue: 30_000)
        let b = WitnessResult(witnessedNoteIds: [1, 2, 3], totalWitnessedValue: 30_000)
        let c = WitnessResult(witnessedNoteIds: [1, 2], totalWitnessedValue: 20_000)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testWitnessResultEmpty() {
        let result = WitnessResult(witnessedNoteIds: [], totalWitnessedValue: 0)

        XCTAssertTrue(result.witnessedNoteIds.isEmpty)
        XCTAssertEqual(result.totalWitnessedValue, 0)
    }
}
