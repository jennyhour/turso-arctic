//! Multiversion concurrency control (MVCC) for Rust.
//!
//! This module implements the main memory MVCC method outlined in the paper
//! "High-Performance Concurrency Control Mechanisms for Main-Memory Databases"
//! by Per-Åke Larson et al (VLDB, 2011).
//!
//! ## Data anomalies
//!
//! * A *dirty write* occurs when transaction T_m updates a value that is written by
//!   transaction T_n but not yet committed. The MVCC algorithm prevents dirty
//!   writes by validating that a row version is visible to transaction T_m before
//!   allowing update to it.
//!
//! * A *dirty read* occurs when transaction T_m reads a value that was written by
//!   transaction T_n but not yet committed. The MVCC algorithm prevents dirty
//!   reads by validating that a row version is visible to transaction T_m.
//!
//! * A *fuzzy read* (non-repeatable read) occurs when transaction T_m reads a
//!   different value in the course of the transaction because another
//!   transaction T_n has updated the value.
//!
//! * A *lost update* occurs when transactions T_m and T_n both attempt to update
//!   the same value, resulting in one of the updates being lost. The MVCC algorithm
//!   prevents lost updates by detecting the write-write conflict and letting the
//!   first-writer win by aborting the later transaction.
//!
//! TODO: phantom reads, cursor lost updates, read skew, write skew.
//!
//! ## TODO
//!
//! * Optimistic reads and writes
//! * Garbage collection

#[cfg(feature = "arctic")]
type TxMap = arctic::concurrent::Map<
    database::TxID,
    Box<database::Transaction>,
    arctic::concurrent::smr::Epoch,
>;

#[cfg(not(feature = "arctic"))]
type TxMap = crossbeam_skiplist::SkipMap<database::TxID, database::Transaction>;

#[cfg(feature = "arctic")]
macro_rules! value {
    ($expr:expr) => {{
        use ::core::ops::Deref as _;
        $expr.deref()
    }};
}

#[cfg(not(feature = "arctic"))]
macro_rules! value {
    ($expr:expr) => {
        $expr.value()
    };
}

#[cfg(feature = "arctic")]
macro_rules! insert {
    ($txs:expr, $key:expr, $tx:expr) => {{
        $txs.upsert(&$key, Box::new($tx))
    }};
}

#[cfg(not(feature = "arctic"))]
macro_rules! insert {
    ($txs:expr, $key:expr, $tx:expr) => {{
        $txs.insert($key, $tx)
    }};
}

#[cfg(feature = "arctic")]
macro_rules! contains {
    ($txs:expr, $key:expr) => {{
        $txs.get($key).is_some()
    }};
}

#[cfg(not(feature = "arctic"))]
macro_rules! contains {
    ($txs:expr, $key:expr) => {{
        $txs.contains_key($key)
    }};
}

#[cfg(feature = "arctic")]
macro_rules! any {
    ($txs:expr, $closure:expr) => {{
        let mut any = false;
        $txs.all()
            .values::<arctic::Ascend>()
            .for_each_internal(|value| {
                use ::core::ops::Deref as _;
                if $closure(value.deref()) {
                    any = true;
                    core::ops::ControlFlow::Break(())
                } else {
                    core::ops::ControlFlow::Continue(())
                }
            });
        any
    }};
}

#[cfg(not(feature = "arctic"))]
macro_rules! any {
    ($txs:expr, $closure:expr) => {
        $txs.iter().any(|entry| $closure(entry.value()))
    };
}

#[cfg(feature = "arctic")]
type RowMap = arctic::concurrent::Map<
    u128,
    Box<RwLock<Vec<database::RowVersion>>>,
    arctic::concurrent::smr::Epoch,
>;

#[cfg(not(feature = "arctic"))]
type RowMap = crossbeam_skiplist::SkipMap<database::RowID, RwLock<Vec<database::RowVersion>>>;

#[cfg(feature = "arctic")]
macro_rules! row_get {
    ($rows:expr, $key:expr) => {{
        $rows.get(&u128::from($key))
    }};
}

#[cfg(not(feature = "arctic"))]
macro_rules! row_get {
    ($rows:expr, $key:expr) => {{
        $rows.get(&$key)
    }};
}

#[cfg(feature = "arctic")]
macro_rules! row_get_or_insert_with {
    ($rows:expr, $key:expr, $with:expr) => {{
        match $rows.insert_with(&u128::from($key), || Box::new($with())) {
            Ok(shared) => shared,
            Err((shared, _)) => shared,
        }
    }};
}

#[cfg(not(feature = "arctic"))]
macro_rules! row_get_or_insert_with {
    ($rows:expr, $key:expr, $with:expr) => {{
        $rows.get_or_insert_with($key, $with)
    }};
}

#[cfg(feature = "arctic")]
macro_rules! row_upper_bound {
    ($rows:expr, $bound:expr, $with:expr) => {{
        let (id, include) = match $bound {
            core::ops::Bound::Included(id) => (u128::from(*id), true),
            core::ops::Bound::Excluded(id) => (u128::from(*id), false),
            core::ops::Bound::Unbounded => unimplemented!(),
        };

        if let Some(prefix) = $rows.range(..=id) {
            let mut iter = prefix.entries::<arctic::Descend>();

            match iter.lend() {
                None => None,
                Some((row_id, _)) if !include && *row_id == id => match iter.lend() {
                    None => None,
                    Some((row_id, row_value)) => $with((RowID::from(*row_id), row_value)),
                },
                Some((row_id, row_value)) => $with((RowID::from(*row_id), row_value)),
            }
        } else {
            None
        }
    }};
}

#[cfg(not(feature = "arctic"))]
macro_rules! row_upper_bound {
    ($rows:expr, $bound:expr, $with:expr) => {{
        $rows
            .upper_bound($bound)
            .and_then(|entry| $with((*entry.key(), entry.value())))
    }};
}

#[cfg(feature = "arctic")]
macro_rules! row_range {
    ($rows:expr, $min:expr, $max:expr, $with:expr) => {{
        if let Some(prefix) = $rows.range(u128::from($min)..=u128::from($max)) {
            let mut output = None;
            prefix
                .entries::<arctic::Ascend>()
                .for_each_internal(|(id, versions)| match $with((RowID::from(*id), versions)) {
                    None => core::ops::ControlFlow::Continue(()),
                    Some(out) => {
                        output = Some(out);
                        core::ops::ControlFlow::Break(())
                    }
                });
            output
        } else {
            None
        }
    }};
}

#[cfg(not(feature = "arctic"))]
macro_rules! row_range {
    ($rows:expr, $min:expr, $max:expr, $with:expr) => {{
        $rows
            .range($min..$max)
            .find_map(|entry| $with((*entry.key(), entry.value())))
    }};
}

pub mod clock;
pub mod cursor;
pub mod database;
pub mod persistent_storage;

pub use clock::LocalClock;
pub use database::MvStore;
use parking_lot::RwLock;

#[cfg(test)]
mod tests {
    use crate::mvcc::database::tests::{
        commit_tx_no_conn, generate_simple_string_row, MvccTestDbNoConn,
    };
    use crate::mvcc::database::RowID;
    use std::sync::atomic::AtomicI64;
    use std::sync::atomic::Ordering;
    use std::sync::Arc;

    static IDS: AtomicI64 = AtomicI64::new(1);

    #[test]
    #[ignore = "FIXME: This test fails because there is write busy lock yet to be fixed"]
    fn test_non_overlapping_concurrent_inserts() {
        // Two threads insert to the database concurrently using non-overlapping
        // row IDs.
        let db = Arc::new(MvccTestDbNoConn::new());
        let iterations = 100000;

        let th1 = {
            let db = db.clone();
            std::thread::spawn(move || {
                let conn = db.get_db().connect().unwrap();
                let mvcc_store = db.get_db().mv_store.as_ref().unwrap().clone();
                for _ in 0..iterations {
                    let tx = mvcc_store.begin_tx(conn.pager.load().clone()).unwrap();
                    let id = IDS.fetch_add(1, Ordering::SeqCst);
                    let id = RowID {
                        table_id: (-2).into(),
                        row_id: id,
                    };
                    let row = generate_simple_string_row((-2).into(), id.row_id, "Hello");
                    mvcc_store.insert(tx, row.clone()).unwrap();
                    commit_tx_no_conn(&db, tx, &conn).unwrap();
                    let tx = mvcc_store.begin_tx(conn.pager.load().clone()).unwrap();
                    let committed_row = mvcc_store.read(tx, id).unwrap();
                    commit_tx_no_conn(&db, tx, &conn).unwrap();
                    assert_eq!(committed_row, Some(row));
                }
            })
        };
        let th2 = {
            std::thread::spawn(move || {
                let conn = db.get_db().connect().unwrap();
                let mvcc_store = db.get_db().mv_store.as_ref().unwrap().clone();
                for _ in 0..iterations {
                    let tx = mvcc_store.begin_tx(conn.pager.load().clone()).unwrap();
                    let id = IDS.fetch_add(1, Ordering::SeqCst);
                    let id = RowID {
                        table_id: (-2).into(),
                        row_id: id,
                    };
                    let row = generate_simple_string_row((-2).into(), id.row_id, "World");
                    mvcc_store.insert(tx, row.clone()).unwrap();
                    commit_tx_no_conn(&db, tx, &conn).unwrap();
                    let tx = mvcc_store.begin_tx(conn.pager.load().clone()).unwrap();
                    let committed_row = mvcc_store.read(tx, id).unwrap();
                    commit_tx_no_conn(&db, tx, &conn).unwrap();
                    assert_eq!(committed_row, Some(row));
                }
            })
        };
        th1.join().unwrap();
        th2.join().unwrap();
    }

    // FIXME: This test fails sporadically.
    #[test]
    #[ignore]
    fn test_overlapping_concurrent_inserts_read_your_writes() {
        let db = Arc::new(MvccTestDbNoConn::new());
        let iterations = 100000;

        let work = |prefix: &'static str| {
            let db = db.clone();
            std::thread::spawn(move || {
                let conn = db.get_db().connect().unwrap();
                let mvcc_store = db.get_db().mv_store.as_ref().unwrap().clone();
                let mut failed_upserts = 0;
                for i in 0..iterations {
                    if i % 1000 == 0 {
                        tracing::debug!("{prefix}: {i}");
                    }
                    if i % 10000 == 0 {
                        let dropped = mvcc_store.drop_unused_row_versions();
                        tracing::debug!("garbage collected {dropped} versions");
                    }
                    let tx = mvcc_store.begin_tx(conn.pager.load().clone()).unwrap();
                    let id = i % 16;
                    let id = RowID {
                        table_id: (-2).into(),
                        row_id: id,
                    };
                    let row = generate_simple_string_row(
                        (-2).into(),
                        id.row_id,
                        &format!("{prefix} @{tx}"),
                    );
                    if let Err(e) = mvcc_store.upsert(tx, row.clone()) {
                        tracing::trace!("upsert failed: {e}");
                        failed_upserts += 1;
                        continue;
                    }
                    let committed_row = mvcc_store.read(tx, id).unwrap();
                    commit_tx_no_conn(&db, tx, &conn).unwrap();
                    assert_eq!(committed_row, Some(row));
                }
                tracing::info!(
                    "{prefix}'s failed upserts: {failed_upserts}/{iterations} {:.2}%",
                    (failed_upserts * 100) as f64 / iterations as f64
                );
            })
        };

        let threads = vec![work("A"), work("B"), work("C"), work("D")];
        for th in threads {
            th.join().unwrap();
        }
    }
}
