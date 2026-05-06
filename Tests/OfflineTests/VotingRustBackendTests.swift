//
//  VotingRustBackendTests.swift
//  ZcashLightClientKitTests
//
//  Copyright © 2026 Electric Coin Company. All rights reserved.
//

import XCTest
@testable import ZcashLightClientKit

final class VotingRustBackendTests: XCTestCase {
    func testOpenSetWalletIdClose_Lifecycle() async throws {
        let backend = VotingRustBackend()
        let url = URL(fileURLWithPath: "/tmp/voting-db-stub-\(UUID().uuidString)")

        XCTAssertEqual(await backend.isOpen, false)

        await backend.open(path: url)
        XCTAssertEqual(await backend.isOpen, true)
        XCTAssertEqual(await backend.databaseURL, url)

        try await backend.setWalletId("wallet-a")
        XCTAssertEqual(await backend.configuredWalletId, "wallet-a")

        await backend.close()
        XCTAssertEqual(await backend.isOpen, false)
        XCTAssertNil(await backend.databaseURL)
        XCTAssertNil(await backend.configuredWalletId)
    }

    func testSetWalletIdBeforeOpen_Throws() async {
        let backend = VotingRustBackend()
        do {
            try await backend.setWalletId("x")
            XCTFail("expected notOpen")
        } catch VotingRustBackendError.notOpen { }
        catch {
            XCTFail("unexpected \(error)")
        }
    }
}
