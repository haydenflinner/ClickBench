#!/opt/local/bin/bash
# Load-only pass to capture part_log merge stats per arm.
# Usage: OUT=<dir> ./merge_stats_pass.sh [arm...]
set -u
CB=$(greadlink -f "$(dirname "$(greadlink -f "$0")")")
OUT=$(greadlink -m "${OUT:-./results-merge}")
mkdir -p "$OUT"
ARMS="${*:-simple fluid}"
export PATH="$CB/bin:$PATH"
q() { clickhouse-client --query "$1" 2>/dev/null; }

for arm in $ARMS; do
  cd "$CB/clickhouse-$arm"
  ./stop >/dev/null 2>&1
  ./start >/dev/null 2>&1 || true
  for i in $(seq 60); do q "SELECT 1" >/dev/null && break; sleep 1; done
  q "DROP TABLE IF EXISTS default.hits SYNC"
  q "SYSTEM FLUSH LOGS"
  q "DROP TABLE IF EXISTS system.part_log SYNC"

  load_start=$(date +%s)
  ./load >/dev/null 2>&1
  load_end=$(date +%s)

  # sample parts until count stable for 3 polls AND no active merges (cap 20 min)
  tl="$OUT/$arm.merge_timeline.tsv"
  prev=-1; stable=0
  for i in $(seq 120); do
    parts=$(q "SELECT count() FROM system.parts WHERE database='default' AND table='hits' AND active" || echo "")
    merges=$(q "SELECT count() FROM system.merges" || echo "0")
    echo -e "$(date +%s)\t$parts\t$merges" >> "$tl"
    if [ "$parts" = "$prev" ] && [ "${merges:-1}" = "0" ]; then
      stable=$((stable + 1)); [ $stable -ge 3 ] && break
    else
      stable=0
    fi
    prev="$parts"
    sleep 10
  done

  q "SYSTEM FLUSH LOGS"
  {
    echo "load_seconds $((load_end - load_start))"
    echo "== final active parts"
    q "SELECT count() parts, max(level), sum(rows), formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE database='default' AND table='hits' AND active FORMAT TSVWithNames"
    echo "== part_log by event"
    q "SELECT event_type, count() n, sum(rows) rows, formatReadableSize(sum(size_in_bytes)) bytes, sum(size_in_bytes) raw_bytes, round(sum(duration_ms)/1000,1) dur_s, max(length(merged_from)) max_merge_width FROM system.part_log WHERE database='default' AND table='hits' GROUP BY event_type ORDER BY event_type FORMAT TSVWithNames"
    echo "== write amplification (bytes written by inserts+merges / bytes inserted)"
    q "SELECT round(sum(size_in_bytes) / sumIf(size_in_bytes, event_type='NewPart'), 3) FROM system.part_log WHERE database='default' AND table='hits' AND event_type IN ('NewPart','MergeParts')"
    echo "== merges by result part"
    q "SELECT part_name, length(merged_from) width, formatReadableSize(size_in_bytes) sz, round(duration_ms/1000,1) s, event_time FROM system.part_log WHERE database='default' AND table='hits' AND event_type='MergeParts' ORDER BY event_time FORMAT TSVWithNames"
  } > "$OUT/$arm.mergestats.txt"
  q "SELECT * FROM system.part_log WHERE database='default' AND table='hits' FORMAT TSVWithNames" > "$OUT/$arm.part_log.tsv"
done
"$CB/clickhouse-simple/stop" >/dev/null 2>&1 || true
echo ALL_DONE
