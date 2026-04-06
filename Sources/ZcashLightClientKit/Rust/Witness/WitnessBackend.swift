import Foundation
import libzcashlc

// MARK: - Error

public enum WitnessBackendError: LocalizedError, Equatable {
    case rustError(String)

    public var errorDescription: String? {
        switch self {
        case .rustError(let message):
            return "Witness backend error: \(message)"
        }
    }
}

// MARK: - WitnessBackend

/// Wraps the witness PIR network FFI. Stateless — no DB handle, no persistent connection.
///
/// Currently a stub: the Rust implementation returns an error until `witness-client`
/// is built (server-side milestone). The Swift side treats this as "server unavailable"
/// and falls back to waiting for shard completion.
public struct WitnessBackend: Sendable {
    public init() {}

    /// Fetch note commitment witnesses from the PIR server. No database access.
    ///
    /// - Parameters:
    ///   - notes: Notes needing witnesses (from DB read).
    ///   - pirServerUrl: Base URL of the witness PIR server.
    ///   - progress: Optional progress callback (0.0..1.0).
    /// - Returns: A `PIRWitnessResult` with witness data for each note.
    public func fetchWitnesses(
        notes: [PIRNotePosition],
        pirServerUrl: String,
        progress: SpendabilityProgressHandler?
    ) throws -> PIRWitnessResult {
        let urlBytes = [UInt8](pirServerUrl.utf8)

        struct PositionInput: Codable {
            let note_id: Int64
            let position: UInt64
        }

        let positions = notes.map { PositionInput(note_id: $0.id, position: $0.position) }
        let positionsJSON = try JSONEncoder().encode(positions)

        var context = WitnessProgressContext(handler: progress)

        let ptr: UnsafeMutablePointer<FfiBoxedSlice>? = urlBytes.withUnsafeBufferPointer { urlBuf in
            positionsJSON.withUnsafeBytes { posBuf in
                withUnsafeMutablePointer(to: &context) { ctxPtr in
                    let callback: (@convention(c) (Double, UnsafeMutableRawPointer?) -> Void)? =
                        progress != nil ? witnessProgressTrampoline : nil
                    return zcashlc_fetch_pir_witnesses(
                        urlBuf.baseAddress,
                        UInt(urlBuf.count),
                        posBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        UInt(posBuf.count),
                        callback,
                        UnsafeMutableRawPointer(ctxPtr)
                    )
                }
            }
        }

        guard let ptr else {
            throw WitnessBackendError.rustError(lastErrorMessage(fallback: "`fetchWitnesses` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }

        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        return try JSONDecoder().decode(PIRWitnessResult.self, from: data)
    }
}

// MARK: - Progress callback trampoline

private struct WitnessProgressContext {
    let handler: SpendabilityProgressHandler?
}

private func witnessProgressTrampoline(progress: Double, context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let ctx = context.assumingMemoryBound(to: WitnessProgressContext.self).pointee
    ctx.handler?(progress)
}
