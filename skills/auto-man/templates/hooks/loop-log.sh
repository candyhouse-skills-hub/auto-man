#!/bin/bash
# Stop hook (no matcher — fires after every turn) — writes the MECHANICAL half of
# each loop.jsonl entry (iteration number, timestamp). Never blocks the stop
# (always exit 0): this hook only logs, it must not interfere with /goal's own
# separately-registered Stop hook that decides whether to auto-continue.
#
# The SEMANTIC half (goalVerdict/reason/criteriaMetDelta/commands/failures/
# blockers/lesson) is NOT written here — a hook has no access to the model's
# judgment. CLAUDE.md conventions require the model itself to append a matching
# {"type":"semantic", iteration:<same N>, ...} line before ending each turn.

run_dir=".workflow/logs/run-${LOOP_RUN_ID:-default}"
mkdir -p "$run_dir"

counter_file="$run_dir/iteration.count"
prev=$(cat "$counter_file" 2>/dev/null || echo 0)
iteration=$((prev + 1))
echo "$iteration" > "$counter_file"

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"type":"mechanical","iteration":%d,"ts":"%s"}\n' "$iteration" "$ts" >> "$run_dir/loop.jsonl"

exit 0
