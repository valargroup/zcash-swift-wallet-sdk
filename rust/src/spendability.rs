//! C FFI for spendability PIR checks.

use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use serde::Serialize;

use crate::unwrap_exc_or_null;

#[derive(Serialize)]
/// Result of checking the spendability of all unspent Orchard notes in the wallet.
struct SpendabilityCheckResult {
    /// The earliest height at which the notes were spent.
    earliest_height: u64,
    /// The latest height at which the notes were spent.
    latest_height: u64,
    /// List of IDs of spent notes.
    spent_note_ids: Vec<i64>,
    /// Total zatoshi value of notes found spent by PIR.
    total_spent_value: u64,
}

#[derive(Serialize)]
/// A spent note found by PIR.
struct PIRPendingNote {
    /// The ID of the note.
    note_id: i64,
    /// The zatoshi value of the note.
    value: u64,
}

#[derive(Serialize)]
/// Result of querying the PIR server for all unspent Orchard notes in the wallet.
struct PIRPendingSpendsResult {
    /// List of spent notes.
    notes: Vec<PIRPendingNote>,
    /// Total zatoshi value of notes found spent by PIR.
    total_value: u64,
}

/// Converts a pointer and length to a UTF-8 string.
unsafe fn str_from_ptr(ptr: *const u8, len: usize) -> anyhow::Result<String> {
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    Ok(std::str::from_utf8(bytes)?.to_string())
}

/// Converts a JSON value to a boxed slice.
fn json_to_boxed_slice<T: Serialize>(value: &T) -> anyhow::Result<*mut crate::ffi::BoxedSlice> {
    let json = serde_json::to_vec(value)?;
    Ok(crate::ffi::BoxedSlice::some(json))
}

/// Retries `insert_pir_spent_note` with exponential backoff when the
/// database is busy (concurrent access from the sync thread).
fn insert_pir_spent_note_with_retry(
    conn: &rusqlite::Connection,
    note_id: i64,
) -> anyhow::Result<()> {
    const MAX_RETRIES: u32 = 8;
    const BASE_DELAY_MS: u64 = 50;

    for attempt in 0..=MAX_RETRIES {
        match zcash_client_sqlite::wallet::pir::insert_pir_spent_note(conn, note_id) {
            Ok(_) => return Ok(()),
            Err(zcash_client_sqlite::error::SqliteClientError::DbError(
                rusqlite::Error::SqliteFailure(err, _),
            )) if err.code == rusqlite::ffi::ErrorCode::DatabaseBusy => {
                if attempt == MAX_RETRIES {
                    return Err(anyhow!(
                        "pir_spent_notes insert for note_id={note_id} failed: \
                         database busy after {MAX_RETRIES} retries"
                    ));
                }
                let delay = BASE_DELAY_MS * 2u64.pow(attempt);
                std::thread::sleep(std::time::Duration::from_millis(delay));
            }
            Err(e) => return Err(e.into()),
        }
    }
    unreachable!()
}

/// Queries the PIR server for all unspent Orchard notes in the wallet and
/// records any that are spent into `pir_spent_notes`.
///
/// Returns JSON `SpendabilityCheckResult`, or null on error.
///
/// # Safety
///
/// Pointer/length pairs must be valid UTF-8 slices.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_check_wallet_spendability(
    wallet_db_path: *const u8,
    wallet_db_path_len: usize,
    pir_server_url: *const u8,
    pir_server_url_len: usize,
    progress_callback: Option<unsafe extern "C" fn(f64, *mut std::ffi::c_void)>,
    progress_context: *mut std::ffi::c_void,
) -> *mut crate::ffi::BoxedSlice {
    let progress_context = AssertUnwindSafe(progress_context);
    let res = catch_panic(|| {
        let db_path = unsafe { str_from_ptr(wallet_db_path, wallet_db_path_len) }?;
        let url = unsafe { str_from_ptr(pir_server_url, pir_server_url_len) }?;

        // Open the wallet DB read-write.
        let conn = rusqlite::Connection::open_with_flags(
            &db_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|e| anyhow!("failed to open wallet DB: {e}"))?;

        // Query the PIR server for all unspent Orchard notes in the wallet.
        let notes =
            zcash_client_sqlite::wallet::pir::get_unspent_orchard_notes_for_pir(&conn)
                .map_err(|e| anyhow!("failed to query unspent notes: {e}"))?;

        // If there are no unspent Orchard notes, return an empty result.
        if notes.is_empty() {
            return json_to_boxed_slice(&SpendabilityCheckResult {
                earliest_height: 0,
                latest_height: 0,
                spent_note_ids: vec![],
                total_spent_value: 0,
            });
        }

        let nullifiers: Vec<[u8; 32]> = notes.iter().map(|n| n.nf).collect();

        // Connect to the PIR server.
        let client = spend_client::SpendClientBlocking::connect(&url)
            .map_err(|e| anyhow!("PIR connect failed: {e}"))?;

        // Check the nullifiers with the PIR server.
        let results = client
            .check_nullifiers(&nullifiers, |progress| {
                if let Some(cb) = progress_callback {
                    unsafe { cb(progress, *progress_context) };
                }
            })
            .map_err(|e| anyhow!("PIR check failed: {e}"))?;

        // Record the spent notes.
        let mut spent_note_ids = Vec::new();
        let mut total_spent_value: u64 = 0;
        for (note, spent) in notes.iter().zip(results.iter()) {
            if *spent {
                spent_note_ids.push(note.id);
                total_spent_value += note.value;
            }
        }

        // Insert the spent notes into the wallet DB.
        for &note_id in &spent_note_ids {
            insert_pir_spent_note_with_retry(&conn, note_id)?;
        }

        // Return the result.
        let metadata = client.metadata();
        let result = SpendabilityCheckResult {
            earliest_height: metadata.earliest_height,
            latest_height: metadata.latest_height,
            spent_note_ids,
            total_spent_value,
        };

        json_to_boxed_slice(&result)
    });
    unwrap_exc_or_null(res)
}

/// Returns PIR-detected spent notes not yet confirmed by the block scanner.
///
/// Returns JSON `PIRPendingSpendsResult`, or null on error.
///
/// # Safety
///
/// Pointer/length pair must be a valid UTF-8 slice.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_get_pir_pending_spends(
    wallet_db_path: *const u8,
    wallet_db_path_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        // Open the wallet DB read-only.
        let db_path = unsafe { str_from_ptr(wallet_db_path, wallet_db_path_len) }?;

        let conn = rusqlite::Connection::open_with_flags(
            &db_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|e| anyhow!("failed to open wallet DB: {e}"))?;

        // Query the wallet DB for all spent notes not yet confirmed by the block scanner.
        let pir_result = zcash_client_sqlite::wallet::pir::get_pir_pending_spends(&conn)
            .map_err(|e| anyhow!("failed to query PIR pending spends: {e}"))?;

        // Return the result.
        let result = PIRPendingSpendsResult {
            notes: pir_result
                .notes
                .into_iter()
                .map(|n| PIRPendingNote {
                    note_id: n.note_id,
                    value: n.value,
                })
                .collect(),
            total_value: pir_result.total_value,
        };
        json_to_boxed_slice(&result)
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use super::*;
    use zcash_client_sqlite::wallet::pir::testing::{
        create_pir_test_db_on_disk, insert_test_note,
    };

    #[test]
    fn serialize_spendability_check_result() {
        let result = SpendabilityCheckResult {
            earliest_height: 100,
            latest_height: 200,
            spent_note_ids: vec![1, 3],
            total_spent_value: 50_000,
        };
        let json: serde_json::Value = serde_json::to_value(&result).unwrap();
        assert_eq!(json["earliest_height"], 100);
        assert_eq!(json["latest_height"], 200);
        assert_eq!(json["spent_note_ids"], serde_json::json!([1, 3]));
        assert_eq!(json["total_spent_value"], 50_000);
    }

    #[test]
    fn serialize_pir_pending_spends_result() {
        let result = PIRPendingSpendsResult {
            notes: vec![
                PIRPendingNote { note_id: 5, value: 10_000 },
                PIRPendingNote { note_id: 8, value: 30_000 },
            ],
            total_value: 40_000,
        };
        let json: serde_json::Value = serde_json::to_value(&result).unwrap();
        assert_eq!(json["total_value"], 40_000);
        let notes = json["notes"].as_array().unwrap();
        assert_eq!(notes.len(), 2);
        assert_eq!(notes[0]["note_id"], 5);
        assert_eq!(notes[0]["value"], 10_000);
        assert_eq!(notes[1]["note_id"], 8);
        assert_eq!(notes[1]["value"], 30_000);
    }

    #[test]
    fn serialize_empty_spendability_result() {
        let result = SpendabilityCheckResult {
            earliest_height: 0,
            latest_height: 0,
            spent_note_ids: vec![],
            total_spent_value: 0,
        };
        let json: serde_json::Value = serde_json::to_value(&result).unwrap();
        assert_eq!(json["spent_note_ids"], serde_json::json!([]));
    }

    #[test]
    fn insert_succeeds_without_contention() {
        // Create a test database with no contention.
        let (conn, db_path) = create_pir_test_db_on_disk("no_contention");
        // Insert a test note.
        insert_test_note(&conn, 1, 10_000, Some(&[0xAA; 32]));
        let result = insert_pir_spent_note_with_retry(&conn, 1);
        assert!(result.is_ok());
        // Verify the spent note was inserted.
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM pir_spent_notes", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 1);
        // Clean up.
        drop(conn);
        let _ = std::fs::remove_file(&db_path);
    }

    #[test]
    fn insert_propagates_non_busy_error() {
        let db_path = std::env::temp_dir().join(format!(
            "pir_nonbusy_test_{}.db",
            std::process::id()
        ));
        // Open the wallet DB read-write.
        let conn = rusqlite::Connection::open(&db_path).unwrap();
        // Insert a test note.
        let result = insert_pir_spent_note_with_retry(&conn, 999);
        assert!(result.is_err());
        // Verify the error is not a busy error.
        let msg = format!("{}", result.unwrap_err());
        assert!(
            !msg.contains("database busy"),
            "should not be a busy error: {msg}"
        );
        // Clean up.
        drop(conn);
        let _ = std::fs::remove_file(&db_path);
    }

    #[test]
    fn insert_retries_on_busy() {
        use std::sync::{Arc, Barrier};

        // Create a test database with contention.
        let (conn1, db_path) = create_pir_test_db_on_disk("busy");
        // Insert a test note.
        insert_test_note(&conn1, 1, 10_000, Some(&[0xAA; 32]));

        // Create a barrier to synchronize the two threads.
        let barrier = Arc::new(Barrier::new(2));
        let barrier2 = barrier.clone();
        let db_path2 = db_path.clone();

        // Start the second thread.
        let handle = std::thread::spawn(move || {
            let conn2 = rusqlite::Connection::open(&db_path2).unwrap();
            conn2.execute_batch("BEGIN EXCLUSIVE").unwrap();
            barrier2.wait();
            std::thread::sleep(std::time::Duration::from_millis(150));
            conn2.execute_batch("COMMIT").unwrap();
        });

        // Wait for the second thread to start.
        barrier.wait();
        // Insert the test note.
        let result = insert_pir_spent_note_with_retry(&conn1, 1);
        handle.join().unwrap();

        // Verify the spent note was inserted.
        assert!(result.is_ok());
        // Clean up.
        drop(conn1);
        let _ = std::fs::remove_file(&db_path);
    }
}
