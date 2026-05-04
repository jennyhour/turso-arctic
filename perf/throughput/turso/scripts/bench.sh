#!/bin/sh

echo "index,system,threads,batch_size,compute,throughput" >> throughput.csv

for iteration in $(seq 10); do
    for threads in 1 2 4 8; do
        for index in arctic skipmap; do
            rm -f write_throughput_test.db*

            echo -n "$index," >> throughput.csv

            "./write-throughput-$index" --threads $threads --batch-size 100 --compute 0 -i $((16000 / $threads)) --mode concurrent >> throughput.csv
        done
    done
done
