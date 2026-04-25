#!/usr/bin/env bash
set -euo pipefail

# Benchmarks both repositories from a shared base directory:
# - turso-arctic (Arctic variant)
# - turso        (baseline variant)
#
# Example:
#   ./scripts/run-branch-benchmarks.sh --base-dir /home/cc/jenny --workload throughput --runs 3 --warmup 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
BASE_DIR="$PWD"
WORKLOAD="all"                    # all|throughput|latency
RUNS=5
WARMUP=1
OUT_DIR="./results"
USE_PERF=0                         # 0|1
EVENTS="cycles,instructions,cache-misses,branch-misses"
CARGO_BIN=""
ARCTIC_LOCAL_PATH=""

ARCTIC_REPO=""
BASELINE_REPO=""
OUT_DIR_ABS=""

THROUGHPUT_CSV=""
LATENCY_CSV=""
PERF_CSV=""

usage() {
  cat <<'EOF'
Usage:
  run-branch-benchmarks.sh [options]

Options:
  --base-dir <path>         Directory containing both repos: turso-arctic and turso
                            Default: current working directory
  --workload <mode>         all | throughput | latency
                            Default: all
  --runs <n>                Number of measured runs per variant
                            Default: 5
  --warmup <n>              Number of warmup runs per variant
                            Default: 1
  --out-dir <path>          Output directory for CSV files (relative to base-dir if not absolute)
                            Default: ./results
  --use-perf                Enable perf stat collection
  --events <csv>            perf events when --use-perf is enabled
                            Default: cycles,instructions,cache-misses,branch-misses
  --cargo-bin <path>        Cargo executable path (auto-detected if omitted)
  --arctic-local-path <p>   Local Arctic checkout used as cargo patch for turso-arctic
                            Default: <base-dir>/arctic when present
  -h, --help                Show help

Notes:
  - This script always benchmarks both variants:
    - arctic   => <base-dir>/turso-arctic
    - baseline => <base-dir>/turso
EOF
}

info() {
  echo "[info] $*"
}

warn() {
  echo "[warn] $*" >&2
}

die() {
  echo "[error] $*" >&2
  exit 1
}

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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base-dir)
        BASE_DIR="$2"
        shift 2
        ;;
      --workload)
        WORKLOAD="$2"
        shift 2
        ;;
      --runs)
        RUNS="$2"
        shift 2
        ;;
      --warmup)
        WARMUP="$2"
        shift 2
        ;;
      --out-dir)
        OUT_DIR="$2"
        shift 2
        ;;
      --use-perf)
        USE_PERF=1
        shift
        ;;
      --events)
        EVENTS="$2"
        shift 2
        ;;
      --cargo-bin)
        CARGO_BIN="$2"
        shift 2
        ;;
      --arctic-local-path)
        ARCTIC_LOCAL_PATH="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1 (use --help)"
        ;;
    esac
  done
}

resolve_paths() {
  BASE_DIR="$(cd "$BASE_DIR" && pwd)"
  ARCTIC_REPO="$BASE_DIR/turso-arctic"
  BASELINE_REPO="$BASE_DIR/turso"

  [[ -d "$ARCTIC_REPO/.git" ]] || die "Expected git repo at $ARCTIC_REPO"
  [[ -d "$BASELINE_REPO/.git" ]] || die "Expected git repo at $BASELINE_REPO"

  if [[ -z "$ARCTIC_LOCAL_PATH" && -d "$BASE_DIR/arctic/.git" ]]; then
    ARCTIC_LOCAL_PATH="$BASE_DIR/arctic"
  fi

  if [[ "$OUT_DIR" = /* ]]; then
    OUT_DIR_ABS="$OUT_DIR"
  else
    OUT_DIR_ABS="$(cd "$BASE_DIR" && mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
  fi
}

validate_config() {
  case "$WORKLOAD" in
    all|throughput|latency) ;;
    *) die "Invalid --workload '$WORKLOAD' (expected all|throughput|latency)" ;;
  esac

  [[ "$RUNS" =~ ^[0-9]+$ ]] || die "--runs must be a non-negative integer"
  [[ "$WARMUP" =~ ^[0-9]+$ ]] || die "--warmup must be a non-negative integer"

  if [[ -z "$CARGO_BIN" ]]; then
    if command -v cargo >/dev/null 2>&1; then
      CARGO_BIN="$(command -v cargo)"
    elif [[ -x "$HOME/.cargo/bin/cargo" ]]; then
      CARGO_BIN="$HOME/.cargo/bin/cargo"
    else
      die "cargo command not found in PATH or at $HOME/.cargo/bin/cargo"
    fi
  fi

  if ! command -v "$CARGO_BIN" >/dev/null 2>&1 && [[ ! -x "$CARGO_BIN" ]]; then
    die "cargo command not found: $CARGO_BIN"
  fi
}

init_output_files() {
  mkdir -p "$OUT_DIR_ABS"

  THROUGHPUT_CSV="$OUT_DIR_ABS/throughput-runs.csv"
  LATENCY_CSV="$OUT_DIR_ABS/latency-runs.csv"
  PERF_CSV="$OUT_DIR_ABS/perf-runs.csv"

  if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "throughput" ]]; then
    ensure_header "$THROUGHPUT_CSV" "timestamp,workload,variant,run,threads,batch_size,compute,throughput"
  fi

  if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "latency" ]]; then
    ensure_header "$LATENCY_CSV" "timestamp,workload,variant,run,count,latency_p50_ns,latency_p90_ns,latency_p95_ns,latency_p99_ns,latency_p999_ns,latency_p9999_ns,latency_p99999_ns,index_p50_ns,index_p90_ns,index_p95_ns,index_p99_ns,index_p999_ns,index_p9999_ns,index_p99999_ns"
  fi

  if [[ "$USE_PERF" == "1" ]]; then
    ensure_header "$PERF_CSV" "timestamp,workload,variant,run,event,value,unit"
  fi
}

cargo_cmd_for_repo() {
  local repo="$1"
  local -n out_cmd_ref="$2"

  out_cmd_ref=("$CARGO_BIN")
  if command -v rustup >/dev/null 2>&1 && [[ -f "$repo/rust-toolchain.toml" ]]; then
    local toolchain_channel
    toolchain_channel="$(sed -n 's/^channel = "\(.*\)"/\1/p' "$repo/rust-toolchain.toml" | head -n 1)"
    if [[ -n "$toolchain_channel" ]]; then
      out_cmd_ref=(rustup run "$toolchain_channel" "$CARGO_BIN")
    fi
  fi
}

build_targets() {
  local repo="$1"
  local variant="$2"
  local cargo_args=()
  local cargo_cmd=()
  local arctic_patch_path=""

  cargo_cmd_for_repo "$repo" cargo_cmd

  if [[ "$variant" == "arctic" && -n "$ARCTIC_LOCAL_PATH" && -d "$ARCTIC_LOCAL_PATH/.git" ]]; then
    arctic_patch_path="$ARCTIC_LOCAL_PATH"
    if ! "${cargo_cmd[@]}" metadata --no-deps --manifest-path "$arctic_patch_path/Cargo.toml" >/dev/null 2>&1; then
      arctic_patch_path=""
    fi
  fi

  if [[ -n "$arctic_patch_path" ]]; then
    info "Using local Arctic patch path: $arctic_patch_path"
    cargo_args+=(
      --config "patch.\"ssh://git@github.com/nwtnni/arctic.git\".arctic.path=\"$arctic_patch_path\""
      --config "patch.\"https://github.com/nwtnni/arctic.git\".arctic.path=\"$arctic_patch_path\""
    )
  fi

  if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "throughput" ]]; then
    (
      cd "$repo/perf/throughput/turso"
      CARGO_NET_GIT_FETCH_WITH_CLI=true "${cargo_cmd[@]}" build --release --quiet --manifest-path Cargo.toml "${cargo_args[@]}"
    )
  fi

  if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "latency" ]]; then
    if ! (
      cd "$repo/perf/latency/limbo"
      CARGO_NET_GIT_FETCH_WITH_CLI=true "${cargo_cmd[@]}" build --release --quiet --manifest-path Cargo.toml "${cargo_args[@]}"
    ); then
      warn "Latency benchmark build failed for variant=$variant; latency runs will be skipped"
    fi
  fi
}

resolve_benchmark_binary() {
  local repo="$1"
  local crate_rel="$2"
  local bin_name="$3"

  local candidate_workspace="$repo/target/release/$bin_name"
  local candidate_local="$repo/$crate_rel/target/release/$bin_name"

  if [[ -x "$candidate_workspace" ]]; then
    echo "$candidate_workspace"
    return 0
  fi

  if [[ -x "$candidate_local" ]]; then
    echo "$candidate_local"
    return 0
  fi

  return 1
}

capture_perf_if_enabled() {
  local workload="$1"
  local variant="$2"
  local run="$3"
  shift 3
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
    return "$rc"
  fi

  while IFS=, read -r value _ unit event _; do
    [[ -z "${event:-}" ]] && continue
    [[ "$value" == "<not supported>" ]] && continue
    local ts
    ts="$(date -u +%FT%TZ)"
    echo "$ts,$workload,$variant,$run,$event,$value,${unit:-}" >> "$PERF_CSV"
  done < "$perf_out"

  rm -f "$perf_out"
}

run_throughput() {
  local repo="$1"
  local variant="$2"
  local record="${3:-1}"

  local bin
  if ! bin="$(resolve_benchmark_binary "$repo" "perf/throughput/turso" "write-throughput")"; then
    die "Missing throughput binary for variant=$variant (checked workspace and crate-local target dirs)"
  fi

  for run in $(seq 1 "$RUNS"); do
    rm -f "$repo/perf/throughput/turso/write_throughput_test.db"*

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
      cd "$repo/perf/throughput/turso"
      capture_perf_if_enabled "throughput" "$variant" "$run" "${cmd[@]}" | tail -n 1
    )"

    local ts
    ts="$(date -u +%FT%TZ)"

    # Output format: Turso,threads,batch_size,compute,throughput
    IFS=, read -r _ threads batch_size compute throughput <<< "$out"

    if [[ "$record" == "1" ]]; then
      echo "$ts,throughput,$variant,$run,$threads,$batch_size,$compute,$throughput" >> "$THROUGHPUT_CSV"
    fi
  done
}

run_latency() {
  local repo="$1"
  local variant="$2"
  local record="${3:-1}"

  local bin
  if ! bin="$(resolve_benchmark_binary "$repo" "perf/latency/limbo" "limbo-multitenancy")"; then
    warn "Missing latency binary for variant=$variant (checked workspace and crate-local target dirs); skipping"
    return 0
  fi

  for run in $(seq 1 "$RUNS"); do
    local count=100

    local out
    out="$(
      cd "$repo/perf/latency/limbo"
      capture_perf_if_enabled "latency" "$variant" "$run" "$bin" "$count" | tail -n 1
    )"

    local ts
    ts="$(date -u +%FT%TZ)"

    # Output format:
    # count,latency_p50_ns,latency_p90_ns,latency_p95_ns,latency_p99_ns,latency_p999_ns,latency_p9999_ns,latency_p99999_ns,index_p50_ns,index_p90_ns,index_p95_ns,index_p99_ns,index_p999_ns,index_p9999_ns,index_p99999_ns
    IFS=, read -r got_count latency_p50_ns latency_p90_ns latency_p95_ns latency_p99_ns latency_p999_ns latency_p9999_ns latency_p99999_ns index_p50_ns index_p90_ns index_p95_ns index_p99_ns index_p999_ns index_p9999_ns index_p99999_ns <<< "$out"

    if [[ "$record" == "1" ]]; then
      echo "$ts,latency,$variant,$run,$got_count,$latency_p50_ns,$latency_p90_ns,$latency_p95_ns,$latency_p99_ns,$latency_p999_ns,$latency_p9999_ns,$latency_p99999_ns,$index_p50_ns,$index_p90_ns,$index_p95_ns,$index_p99_ns,$index_p999_ns,$index_p9999_ns,$index_p99999_ns" >> "$LATENCY_CSV"
    fi
  done
}

run_variant() {
  local repo="$1"
  local variant="$2"

  info "Running variant=$variant repo=$repo workload(s)=$WORKLOAD"

  build_targets "$repo" "$variant"

  if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "throughput" ]]; then
    for _ in $(seq 1 "$WARMUP"); do
      run_throughput "$repo" "$variant" 0 >/dev/null
    done
    run_throughput "$repo" "$variant" 1
  fi

  if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "latency" ]]; then
    for _ in $(seq 1 "$WARMUP"); do
      run_latency "$repo" "$variant" 0 >/dev/null
    done
    run_latency "$repo" "$variant" 1
  fi
}

main() {
  parse_args "$@"
  resolve_paths
  validate_config
  init_output_files

  run_variant "$ARCTIC_REPO" "arctic"
  run_variant "$BASELINE_REPO" "baseline"

  info "Done. Results in $OUT_DIR_ABS"
}

main "$@"
