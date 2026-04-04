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

/// Wraps the PIR network FFI. Stateless — no DB handle, no persistent connection.
public struct SpendabilityBackend: Sendable {
    public init() {}

    /// Check nullifiers against the PIR server. No database access.
    ///
    /// - Parameters:
    ///   - notes: Unspent notes with nullifiers (from phase 1 DB read).
    ///   - pirServerUrl: Base URL of the spend-server.
    ///   - progress: Optional progress callback (0.0..1.0).
    /// - Returns: A `PIRNullifierCheckResult` with spent flags and server metadata.
    public func checkNullifiersPIR(
        notes: [PIRUnspentNote],
        pirServerUrl: String,
        progress: SpendabilityProgressHandler?
    ) throws -> PIRNullifierCheckResult {
        let urlBytes = [UInt8](pirServerUrl.utf8)

        let nullifiers: [[UInt8]] = notes.map { $0.nf }
        let nullifiersJSON = try JSONEncoder().encode(nullifiers)

        var context = SpendabilityProgressContext(handler: progress)

        let ptr: UnsafeMutablePointer<FfiBoxedSlice>? = urlBytes.withUnsafeBufferPointer { urlBuf in
            nullifiersJSON.withUnsafeBytes { nfBuf in
                withUnsafeMutablePointer(to: &context) { ctxPtr in
                    let callback: (@convention(c) (Double, UnsafeMutableRawPointer?) -> Void)? =
                        progress != nil ? spendabilityProgressTrampoline : nil
                    return zcashlc_check_nullifiers_pir(
                        urlBuf.baseAddress,
                        UInt(urlBuf.count),
                        nfBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        UInt(nfBuf.count),
                        callback,
                        UnsafeMutableRawPointer(ctxPtr)
                    )
                }
            }
        }

        guard let ptr else {
            throw SpendabilityBackendError.rustError(lastErrorMessage(fallback: "`checkNullifiersPIR` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }

        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        return try JSONDecoder().decode(PIRNullifierCheckResult.self, from: data)
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
