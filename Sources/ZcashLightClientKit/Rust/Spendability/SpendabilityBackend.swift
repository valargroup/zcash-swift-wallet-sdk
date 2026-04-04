// Swift wrapper for the spendability PIR C FFI in spendability.rs.
// Stateless — each call connects to the PIR server, checks nullifiers, and returns.

import Foundation
import libzcashlc

// MARK: - Error

public enum SpendabilityBackendError: LocalizedError, Equatable {
    case rustError(String)

    public var errorDescription: String? {
        switch self {
        case .rustError(let message):
            return "Spendability backend error: \(message)"
        }
    }
}

// MARK: - SpendabilityBackend

/// Wraps the spendability PIR C FFI. Stateless — no persistent handle needed.
public struct SpendabilityBackend: Sendable {
    public init() {}

    /// Check spendability of all unspent orchard notes in the wallet database.
    /// Opens the wallet DB read-write, extracts nullifiers, checks each via PIR,
    /// and records spent notes in `pir_spent_notes`.
    ///
    /// - Parameters:
    ///   - walletDbPath: Path to the wallet SQLite database.
    ///   - pirServerUrl: Base URL of the spend-server.
    ///   - progress: Optional progress callback (0.0..1.0).
    /// - Returns: A `SpendabilityResult` with spent note IDs and total spent value.
    public func checkWalletSpendability(
        walletDbPath: String,
        pirServerUrl: String,
        progress: SpendabilityProgressHandler?
    ) throws -> SpendabilityResult {
        let dbPathBytes = [UInt8](walletDbPath.utf8)
        let urlBytes = [UInt8](pirServerUrl.utf8)

        var context = SpendabilityProgressContext(handler: progress)

        let ptr: UnsafeMutablePointer<FfiBoxedSlice>? = dbPathBytes.withUnsafeBufferPointer { dbBuf in
            urlBytes.withUnsafeBufferPointer { urlBuf in
                withUnsafeMutablePointer(to: &context) { ctxPtr in
                    let callback: (@convention(c) (Double, UnsafeMutableRawPointer?) -> Void)? =
                        progress != nil ? spendabilityProgressTrampoline : nil
                    return zcashlc_check_wallet_spendability(
                        dbBuf.baseAddress,
                        UInt(dbBuf.count),
                        urlBuf.baseAddress,
                        UInt(urlBuf.count),
                        callback,
                        UnsafeMutableRawPointer(ctxPtr)
                    )
                }
            }
        }

        guard let ptr else {
            throw SpendabilityBackendError.rustError(lastErrorMessage(fallback: "`check_wallet_spendability` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }

        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        return try JSONDecoder().decode(SpendabilityResult.self, from: data)
    }

    /// Query PIR-detected spent notes whose spends have not yet been confirmed
    /// by the block scanner. Opens the wallet DB read-only.
    public func getPIRPendingSpends(
        walletDbPath: String
    ) throws -> PIRPendingSpends {
        let dbPathBytes = [UInt8](walletDbPath.utf8)

        let ptr: UnsafeMutablePointer<FfiBoxedSlice>? = dbPathBytes.withUnsafeBufferPointer { dbBuf in
            zcashlc_get_pir_pending_spends(
                dbBuf.baseAddress,
                UInt(dbBuf.count)
            )
        }

        guard let ptr else {
            throw SpendabilityBackendError.rustError(lastErrorMessage(fallback: "`get_pir_pending_spends` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }

        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        return try JSONDecoder().decode(PIRPendingSpends.self, from: data)
    }
}

// MARK: - Private helpers

private extension SpendabilityBackend {
    func lastErrorMessage(fallback: String) -> String {
        let errorLen = zcashlc_last_error_length()
        defer { zcashlc_clear_last_error() }

        if errorLen > 0 {
            let error = UnsafeMutablePointer<Int8>.allocate(capacity: Int(errorLen))
            defer { error.deallocate() }
            zcashlc_error_message_utf8(error, errorLen)
            if let msg = String(validatingUTF8: error) {
                return msg
            }
        }
        return fallback
    }
}

// MARK: - Progress callback trampoline

private struct SpendabilityProgressContext {
    let handler: SpendabilityProgressHandler?
}

private func spendabilityProgressTrampoline(progress: Double, context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let ctx = context.assumingMemoryBound(to: SpendabilityProgressContext.self).pointee
    ctx.handler?(progress)
}
