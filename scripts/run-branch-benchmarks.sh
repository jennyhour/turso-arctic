#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TURSO_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CARGO_BIN="${HOME}/.cargo/bin/cargo"
OUT_DIR="${OUT_DIR:-./results}"
RUNS="${RUNS:-5}"
WARMUP="${WARMUP:-1}"
WORKLOAD="${WORKLOAD:-all}" # all|throughput|latency
EVENTS="${EVENTS:-cycles,instructions,cache-misses,branch-misses}"
USE_PERF="${USE_PERF:-0}"   # 0|1, if 1 - wraps measured commands with `perf stat`

if [[ ! -d "$TURSO_REPO/.git" ]]; then
  echo "TURSO_REPO does not look like a git repo: $TURSO_REPO" >&2
  exit 1
fi

if [[ ! -x "$CARGO_BIN" ]]; then
  echo "Expected rustup cargo at $CARGO_BIN, but it was not found/executable." >&2
  exit 1
fi

if [[ "$WORKLOAD" != "all" && "$WORKLOAD" != "throughput" && "$WORKLOAD" != "latency" ]]; then
  echo "Invalid WORKLOAD: $WORKLOAD (expected all|throughput|latency)" >&2
  exit 1
fi

# Resolve OUT_DIR to an absolute path so appends keep working after `cd` into
# benchmark subdirectories.
if [[ "$OUT_DIR" = /* ]]; then
  OUT_DIR_ABS="$OUT_DIR"
else
  OUT_DIR_ABS="$(cd "$SCRIPT_DIR" && mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
fi

ensure_header() {
  local file="$1"
  local expected="$2"
  if [[ ! -f "$file" ]]; then
    echo "$expected" > "$file"
    return
  fi
  local current
  current="$(head -n 1 "$file" || true)"
  if [[ "$current" != "$expected" ]]; then
    echo "$expected" > "$file"
  fi
}

mkdir -p "$OUT_DIR_ABS"

throughput_csv="$OUT_DIR_ABS/throughput-runs.csv"
latency_csv="$OUT_DIR_ABS/latency-runs.csv"
perf_csv="$OUT_DIR_ABS/perf-runs.csv"

# CSV schema (throughput-runs.csv):
# timestamp      : ISO-8601 UTC time for this measured run
# workload       : fixed string "throughput"
# run            : run index in [1..RUNS]
# threads        : worker thread count passed to write-throughput
# batch_size     : inserts per transaction batch
# compute        : synthetic compute per transaction, in microseconds (us)
# throughput     : measured inserts per second (ops/s)
if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "throughput" ]]; then
  ensure_header "$throughput_csv" "timestamp,workload,run,threads,batch_size,compute,throughput"
fi

# CSV schema (latency-runs.csv):
# timestamp      : ISO-8601 UTC time for this measured run
# workload       : fixed string "latency"
# run            : run index in [1..RUNS]
# count          : tenant/database count argument passed to limbo-multitenancy
# p50..p99999    : latency percentiles reported by benchmark (nanoseconds)
if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "latency" ]]; then
  ensure_header "$latency_csv" "timestamp,workload,run,count,p50,p90,p95,p99,p999,p9999,p99999"
fi

# CSV schema (perf-runs.csv), populated only when USE_PERF=1:
# timestamp      : ISO-8601 UTC time for this measured run
# workload       : "throughput" or "latency"
# run            : run index in [1..RUNS]
# event          : perf event name (e.g. cycles, instructions, cache-misses)
# value          : numeric counter value for event
# unit           : perf-reported unit for value (may be empty depending on event)
if [[ "$USE_PERF" == "1" ]]; then
  ensure_header "$perf_csv" "timestamp,workload,run,event,value,unit"
fi

build_targets() {
  if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "throughput" ]]; then
    (cd "$TURSO_REPO/perf/throughput/turso" && "$CARGO_BIN" build --release --quiet --manifest-path Cargo.toml)
  fi
  if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "latency" ]]; then
    (cd "$TURSO_REPO/perf/latency/limbo" && "$CARGO_BIN" build --release --quiet --manifest-path Cargo.toml)
  fi
}

capture_perf_if_enabled() {
  local workload="$1"
  local run="$2"
  shift 2
  local cmd=("$@")

  if [[ "$USE_PERF" != "1" ]]; then
    "${cmd[@]}"
    return
  fi

  local perf_out
  perf_out="$(mktemp)"
  set +e
  perf stat -x, -e "$EVENTS" -o "$perf_out" -- "${cmd[@]}"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    cat "$perf_out" >&2 || true
    rm -f "$perf_out"
    return $rc
  fi
  while IFS=, read -r value _ unit event _; do
    [[ -z "${event:-}" ]] && continue
    [[ "$value" == "<not supported>" ]] && continue
    local ts
    ts="$(date -u +%FT%TZ)"
    echo "$ts,$workload,$run,$event,$value,${unit:-}" >> "$perf_csv"
  done < "$perf_out"
  rm -f "$perf_out"
}

run_throughput() {
  local record="${1:-1}"
  local bin="$TURSO_REPO/target/release/write-throughput"
  if [[ ! -x "$bin" ]]; then
    echo "Missing throughput binary: $bin" >&2
    return 1
  fi
  for run in $(seq 1 "$RUNS"); do
    rm -f "$TURSO_REPO/perf/throughput/turso/write_throughput_test.db"*
    local cmd=(
      "$bin"
      --threads 4
      --batch-size 100
      --compute 100
      --iterations 1000
      --mode concurrent
    )
    local out
    out="$(
      cd "$TURSO_REPO/perf/throughput/turso" &&
      capture_perf_if_enabled "throughput" "$run" "${cmd[@]}" |
      tail -n 1
    )"
    local ts
    ts="$(date -u +%FT%TZ)"
    # Throughput binary prints:
    # Turso,threads,batch_size,compute,throughput
    # where throughput is ops/s and compute is microseconds.
    IFS=, read -r _ threads batch_size compute throughput <<< "$out"
    if [[ "$record" == "1" ]]; then
      echo "$ts,throughput,$run,$threads,$batch_size,$compute,$throughput" >> "$throughput_csv"
    fi
  done
}

run_latency() {
  local record="${1:-1}"
  local bin="$TURSO_REPO/target/release/limbo-multitenancy"
  if [[ ! -x "$bin" ]]; then
    echo "Missing latency binary: $bin" >&2
    return 1
  fi
  for run in $(seq 1 "$RUNS"); do
    local count=100
    local out
    out="$(
      cd "$TURSO_REPO/perf/latency/limbo" &&
      capture_perf_if_enabled "latency" "$run" "$bin" "$count" |
      tail -n 1
    )"
    local ts
    ts="$(date -u +%FT%TZ)"
    # Latency binary prints:
    # count,p50,p90,p95,p99,p999,p9999,p99999
    # percentile values are in nanoseconds.
    IFS=, read -r got_count p50 p90 p95 p99 p999 p9999 p99999 <<< "$out"
    if [[ "$record" == "1" ]]; then
      echo "$ts,latency,$run,$got_count,$p50,$p90,$p95,$p99,$p999,$p9999,$p99999" >> "$latency_csv"
    fi
  done
}

echo "Running workload(s)=$WORKLOAD"
build_targets
if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "throughput" ]]; then
  for _ in $(seq 1 "$WARMUP"); do run_throughput 0 >/dev/null; done
  run_throughput 1
fi
if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "latency" ]]; then
  for _ in $(seq 1 "$WARMUP"); do run_latency 0 >/dev/null; done
  run_latency 1
fi
echo "Done. Results in $OUT_DIR_ABS"
