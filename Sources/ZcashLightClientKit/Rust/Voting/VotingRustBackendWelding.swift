//
//  VotingRustBackendWelding.swift
//  ZcashLightClientKit
//
//  Copyright © 2026 Electric Coin Company. All rights reserved.
//

import Foundation

/// Errors surfaced by the voting Rust backend before or instead of FFI wiring.
public enum VotingRustBackendError: Error {
    /// `setWalletId` was called while no database was opened.
    case notOpen
}

/// Abstraction over the shielded voting `libzcashlc` surface (handle lifecycle and, later,
/// round / delegation / vote operations).
///
/// The concrete ``VotingRustBackend`` type is a shell: it tracks path and wallet id under a lock
/// and does not call into `libzcashlc` yet. Subsequent PRs replace internals with real FFI while
/// keeping this protocol stable for dependency injection and tests.
public protocol VotingRustBackendWelding: Sendable {
    /// Opens (or prepares) the voting database at `path`. Idempotent while already open at the
    /// same path; re-opening a different path closes the previous logical session first.
    func open(path: URL) async

    /// Releases the voting database handle and clears wallet scope. Safe to call when closed.
    func close() async

    /// Sets the wallet identifier used to scope round data. Must be called after ``open(path:)``.
    func setWalletId(_ walletId: String) async throws

    /// Whether ``open(path:)`` has established a session (FFI will treat this as db ready).
    var isOpen: Bool { get async }

    /// Last wallet id passed to ``setWalletId(_:)``, if any.
    var configuredWalletId: String? { get async }

    /// Path last passed to ``open(path:)``.
    var databaseURL: URL? { get async }
}
