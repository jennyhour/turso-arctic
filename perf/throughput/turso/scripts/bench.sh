#!/bin/sh

echo "index,system,threads,batch_size,compute,throughput,total,commit,insert,exists" >> turso.csv

for iteration in $(seq 10); do
    for threads in 1 2 4 8; do
        for index in arctic skipmap; do
            rm -f write_throughput_test.db*

            echo -n "$index,$(perf record --freq=999 --call-graph=dwarf --output=perf.data ./write-throughput-$index --threads $threads --batch-size 100 --compute 0 -i $((16000 / $threads)) --mode concurrent)," >> turso.csv
            perf script --addr2line=/home/cc/.cargo/bin/addr2line | /home/cc/.cargo/bin/inferno-collapse-perf > perf.collapsed
            /home/cc/.cargo/bin/breakdown perf.collapsed turso_core::vdbe::execute::op_auto_commit turso_core::vdbe::execute::op_insert turso_core::vdbe::execute::op_not_exists >> turso.csv
        done
    done
done
