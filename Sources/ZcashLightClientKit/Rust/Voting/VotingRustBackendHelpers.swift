//
//  VotingRustBackendHelpers.swift
//  ZcashLightClientKit
//
//  Copyright © 2026 Electric Coin Company. All rights reserved.
//

import Foundation

/// Small utilities shared by the voting Rust wrapper layer.
enum VotingRustBackendHelpers {
    /// Runs `body` while holding `lock` (re-entrant unsafe: do not call back into the same lock).
    static func withLock<T>(_ lock: NSLock, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
