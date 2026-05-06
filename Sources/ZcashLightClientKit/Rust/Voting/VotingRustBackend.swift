//
//  VotingRustBackend.swift
//  ZcashLightClientKit
//
//  Copyright © 2026 Electric Coin Company. All rights reserved.
//

import Foundation

/// Default ``VotingRustBackendWelding`` implementation: serialized lifecycle state only.
///
/// Real `zcashlc_voting_*` calls will be added here (or via extensions) once the XCFramework
/// exposes the symbols; the opaque handle field is reserved for that wiring.
public final class VotingRustBackend: VotingRustBackendWelding, @unchecked Sendable {
    private let lock = NSLock()
    private var openedPath: URL?
    private var walletId: String?

    public init() {}

    public func open(path: URL) async {
        VotingRustBackendHelpers.withLock(lock) {
            self.openedPath = path
            self.walletId = nil
        }
    }

    public func close() async {
        VotingRustBackendHelpers.withLock(lock) {
            self.openedPath = nil
            self.walletId = nil
        }
    }

    public func setWalletId(_ walletId: String) async throws {
        try VotingRustBackendHelpers.withLock(lock) {
            guard self.openedPath != nil else {
                throw VotingRustBackendError.notOpen
            }
            self.walletId = walletId
        }
    }

    public var isOpen: Bool {
        get async {
            VotingRustBackendHelpers.withLock(lock) {
                self.openedPath != nil
            }
        }
    }

    public var configuredWalletId: String? {
        get async {
            VotingRustBackendHelpers.withLock(lock) {
                self.walletId
            }
        }
    }

    public var databaseURL: URL? {
        get async {
            VotingRustBackendHelpers.withLock(lock) {
                self.openedPath
            }
        }
    }
}
