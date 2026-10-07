#!/opt/local/bin/bash
# macOS adaptation of local-kit/run_both.sh.
# Usage: CB=/path/to/ClickBench OUT=./results ./run_both_macos.sh [arm...]
set -u
CB=$(greadlink -f "${CB:-$(dirname "$(greadlink -f "$0")")}")
OUT=$(greadlink -m "${OUT:-./results}");  mkdir -p "$OUT"
ARMS="${*:-simple fluid}"
export PATH="$CB/bin:$PATH"
q() { clickhouse-client --query "$1" 2>/dev/null; }

for arm in $ARMS; do
  cd "$CB/clickhouse-$arm"
  ./start >/dev/null 2>&1 || true
  for i in $(seq 60); do q "SELECT 1" >/dev/null && break; sleep 1; done
  q "DROP TABLE IF EXISTS default.hits SYNC"
  q "SYSTEM FLUSH LOGS"; q "TRUNCATE TABLE IF EXISTS system.part_log"
  rm -f "$CB/clickhouse-$arm.stats.log" result.csv
  # part-count timeline (errors while server restarts are ignored)
  ( while true; do
      r=$(q "SELECT count(), max(level), sum(rows), countIf(level=0) FROM system.parts WHERE database='default' AND table='hits' AND active FORMAT TSV")
      [ -n "$r" ] && echo -e "$(date +%s)\t$r"
      sleep 10
    done ) > "$OUT/$arm.parts_timeline.tsv" &
  SAMPLER=$!
  start=$(date +%s)
  ./benchmark.sh > "$OUT/$arm.log" 2>&1
  echo "wall_seconds $(( $(date +%s) - start ))" >> "$OUT/$arm.log"
  kill $SAMPLER 2>/dev/null
  ./start >/dev/null 2>&1 || true
  for i in $(seq 60); do q "SELECT 1" >/dev/null && break; sleep 1; done
  q "SYSTEM FLUSH LOGS"
  {
    cat "$CB/clickhouse-$arm.stats.log"
    echo "== final active parts"
    q "SELECT count() parts, max(level), sum(rows), formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE database='default' AND table='hits' AND active FORMAT TSVWithNames"
    echo "== part_log by event"
    q "SELECT event_type, count() n, sum(rows) rows, formatReadableSize(sum(size_in_bytes)) bytes, sum(size_in_bytes) raw_bytes, round(sum(duration_ms)/1000,1) dur_s, max(length(merged_from)) max_merge_width FROM system.part_log WHERE database='default' AND table='hits' GROUP BY event_type ORDER BY event_type FORMAT TSVWithNames"
    echo "== write amplification (bytes written by inserts+merges / bytes inserted)"
    q "SELECT round(sum(size_in_bytes) / sumIf(size_in_bytes, event_type='NewPart'), 3) FROM system.part_log WHERE database='default' AND table='hits' AND event_type IN ('NewPart','MergeParts')"
    echo "== merges by result level"
    q "SELECT part_name, length(merged_from) width, formatReadableSize(size_in_bytes) sz, round(duration_ms/1000,1) s, event_time FROM system.part_log WHERE database='default' AND table='hits' AND event_type='MergeParts' ORDER BY event_time FORMAT TSVWithNames"
  } > "$OUT/$arm.stats.txt"
  q "SELECT * FROM system.part_log WHERE database='default' AND table='hits' FORMAT TSVWithNames" > "$OUT/$arm.part_log.tsv"
  cp result.csv "$OUT/$arm.result.csv"
  q "DROP TABLE IF EXISTS default.hits SYNC"
done
"$CB/clickhouse-simple/stop" >/dev/null 2>&1 || true
echo ALL_DONE
