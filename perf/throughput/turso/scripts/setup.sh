#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# https://stackoverflow.com/a/246128
ROOT=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

cd "$ROOT/.."

[ -f "write-throughput-arctic" ] || {
    cargo build --release --features arctic
    cp ../../../target/release/write-throughput write-throughput-arctic
}

[ -f "write-throughput-skipmap" ] || {
    cargo build --release
    cp ../../../target/release/write-throughput write-throughput-skipmap
}

[ -f ~/.cargo/bin/addr2line ] || {
    cargo install addr2line --features=bin
}

[ -f ~/.cargo/bin/breakdown ] || {
    cargo install --git https://github.com/nwtnni/inferno.git
}
