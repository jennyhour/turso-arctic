use clap::Parser;
use hdrhistogram::Histogram;
use std::{sync::Arc, time::Instant};
use turso_core::{Database, PlatformIO, Statement};

#[derive(Parser)]
struct Opts {
    count: usize,
}

fn run_stmt(stmt: &mut Statement) {
    loop {
        match stmt.step().unwrap() {
            turso_core::StepResult::Done => break,
            turso_core::StepResult::IO => stmt.run_once().unwrap(),
            turso_core::StepResult::Row => continue,
            turso_core::StepResult::Interrupt | turso_core::StepResult::Busy => {
                panic!("statement interrupted or busy")
            }
        }
    }
}

fn remove_existing_database_files(database: &str) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let path = format!("{database}{suffix}");
        let _ = std::fs::remove_file(path);
    }
}

fn main() {
    env_logger::init();
    let opts = Opts::parse();
    let mut overall_hist = Histogram::<u64>::new(2).unwrap().into_sync();
    let mut index_hist = Histogram::<u64>::new(2).unwrap().into_sync();
    let io = Arc::new(PlatformIO::new().unwrap());

    for i in 0..opts.count {
        let database = format!("database{}.db", i);
        remove_existing_database_files(&database);
        let db = Database::open_file(io.clone(), &database, true, true).unwrap();
        let mv_store = db.get_mv_store().cloned();
        let conn = db.connect().unwrap();

        let mut create_stmt = conn
            .prepare("CREATE TABLE IF NOT EXISTS \"user\"(id INTEGER)")
            .unwrap();
        run_stmt(&mut create_stmt);

        let mut clear_stmt = conn.prepare("DELETE FROM \"user\"").unwrap();
        run_stmt(&mut clear_stmt);

        for id in 1..=100 {
            let sql = format!("INSERT INTO \"user\"(id) VALUES ({id})");
            let mut insert_stmt = conn.prepare(sql).unwrap();
            run_stmt(&mut insert_stmt);
        }

        if let Some(mv_store) = mv_store.as_ref() {
            mv_store.reset_index_timing_counters();
        }

        let mut begin_stmt = conn.prepare("BEGIN CONCURRENT").unwrap();
        run_stmt(&mut begin_stmt);

        let mut stmt = conn.prepare("SELECT * FROM user LIMIT 100").unwrap();

        for _ in 0..100 {
            for _ in 0..10 {
                let index_before = mv_store
                    .as_ref()
                    .map(|mv_store| mv_store.index_timing_counters());
                let now = Instant::now();
                let mut count = 0;

                stmt.reset();
                loop {
                    match stmt.step().unwrap() {
                        turso_core::StepResult::Row => {
                            count += 1;
                        }
                        turso_core::StepResult::IO => {
                            stmt.run_once().unwrap();
                        }
                        turso_core::StepResult::Done => break,
                        turso_core::StepResult::Interrupt | turso_core::StepResult::Busy => {
                            panic!("query interrupted or busy")
                        }
                    }
                }

                assert_eq!(count, 100);

                let overall_ns = now.elapsed().as_nanos() as u64;
                let index_ns = match (
                    index_before,
                    mv_store
                        .as_ref()
                        .map(|mv_store| mv_store.index_timing_counters()),
                ) {
                    (Some(before), Some(after)) => {
                        after.index_time_ns.saturating_sub(before.index_time_ns)
                    }
                    _ => 0,
                };

                overall_hist.record(overall_ns).unwrap();
                index_hist.record(index_ns).unwrap();
            }
        }

        let mut rollback_stmt = conn.prepare("ROLLBACK").unwrap();
        run_stmt(&mut rollback_stmt);
    }

    overall_hist.refresh();
    index_hist.refresh();
    println!("count,latency_p50_ns,latency_p90_ns,latency_p95_ns,latency_p99_ns,latency_p999_ns,latency_p9999_ns,latency_p99999_ns,index_p50_ns,index_p90_ns,index_p95_ns,index_p99_ns,index_p999_ns,index_p9999_ns,index_p99999_ns");
    println!(
        "{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}",
        opts.count,
        overall_hist.value_at_quantile(0.5),
        overall_hist.value_at_quantile(0.90),
        overall_hist.value_at_quantile(0.95),
        overall_hist.value_at_quantile(0.99),
        overall_hist.value_at_quantile(0.999),
        overall_hist.value_at_quantile(0.9999),
        overall_hist.value_at_quantile(0.99999),
        index_hist.value_at_quantile(0.5),
        index_hist.value_at_quantile(0.90),
        index_hist.value_at_quantile(0.95),
        index_hist.value_at_quantile(0.99),
        index_hist.value_at_quantile(0.999),
        index_hist.value_at_quantile(0.9999),
        index_hist.value_at_quantile(0.99999)
    );
}
