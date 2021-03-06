#!/bin/bash
set -e

if [ "$#" -ne 2 ]; then
    echo "usage: ./clickhouse/exec.sh groupby G1_1e7_1e2_0_0";
    exit 1
fi;

source ./clickhouse/ch.sh

# start server
ch_start

# confirm server working, wait if it crashed in last run
ch_active || sleep 120
ch_active || echo "clickhouse-server should be already running, investigate" >&2
ch_active || exit 1

# load data
CH_MEM=107374182400 # 100GB ## old value 128849018880 # 120GB ## now set to 96GB after cache=1 to in-memory temp tables because there was not enough mem for R to parse timings
CH_EXT_GRP_BY=53687091200 # twice less than CH_MEM #96
CH_EXT_SORT=53687091200
clickhouse-client --query="DROP TABLE IF EXISTS ans"
clickhouse-client --query="TRUNCATE TABLE $2"
clickhouse-client --max_memory_usage=$CH_MEM --query="INSERT INTO $2 FORMAT CSVWithNames" < "data/$2.csv"
# confirm all data loaded yandex/ClickHouse#4463
echo -e "clickhouse-client --query=\"SELECT count(*) FROM $2\"\n$2" | Rscript -e 'stdin=readLines(file("stdin")); if ((loaded<-as.numeric(system(stdin[1L], intern=TRUE)))!=as.numeric(strsplit(stdin[2L], "_", fixed=TRUE)[[1L]][2L])) stop("incomplete data load for ", stdin[2L],", loaded ", loaded, " rows only")'

# for each data_name produce sql script
sed "s/DATA_NAME/$2/g" < "clickhouse/$1-clickhouse.sql.in" > "clickhouse/$1-clickhouse.sql"

# cleanup timings from last run if they have not been cleaned up after parsing
mkdir -p clickhouse/log
rm -f clickhouse/log/$1_$2_q*.csv

# execute sql script on clickhouse
clickhouse-client --query="TRUNCATE TABLE system.query_log"
echo "# clickhouse/exec.sh: data loaded, logs truncated, $1-$2 script prepared, sending benchmark sql script"
cat "clickhouse/$1-clickhouse.sql" | clickhouse-client -mn --max_memory_usage=$CH_MEM --max_bytes_before_external_group_by=$CH_EXT_GRP_BY --max_bytes_before_external_sort=$CH_EXT_SORT --receive_timeout=10800 --format=Pretty --output_format_pretty_max_rows 1 && echo "# clickhouse/exec.sh: benchmark sql script finished" || echo "# clickhouse/exec.sh: benchmark sql script for $2 terminated with error"

# need to wait in case if server crashed to release memory
sleep 90

# cleanup data
ch_active && echo "# clickhouse/exec.sh: finishing, truncating table $2" && clickhouse-client --query="DROP TABLE IF EXISTS ans" && clickhouse-client --query="TRUNCATE TABLE $2" || echo "# clickhouse/exec.sh: finishing, clickhouse server down, possibly crashed, could not truncate table $2"

# stop server
ch_stop && echo "# clickhouse/exec.sh: stopping server finished" || echo "# clickhouse/exec.sh: stopping server failed"

# wait for memory
sleep 30

# parse timings from clickhouse/log/[task]_[data_name]_q[i]_r[j].csv
Rscript clickhouse/clickhouse-parse-log.R "$1" "$2"
