#!/bin/bash
# PostToolUse hook (matcher: Agent|Task) — mechanically accumulate subagent token spend.
# Rationale: /goal's self-reported spend only covers the main-session transcript;
# subagent usage (e.g. the visual judge) never enters that transcript and must be
# tallied separately here, then added back in as run_summary.subagentTokensSum.
#
# tool_response for a completed Agent/Task call is a JSON object with a
# top-level "totalTokens" integer field (confirmed by capturing a real
# PostToolUse payload — do not assume any particular text/XML shape without
# checking, since presentation wrappers vary by harness).
#
# Caveat this hook cannot work around: usage fields only appear in the tool
# result for SYNCHRONOUSLY completed Agent/Task calls. A backgrounded subagent's
# return carries only launch metadata — no usage. CLAUDE.md must require judge/
# verify subagents to run with run_in_background: false so this hook can see them.

run_dir=".workflow/logs/run-${LOOP_RUN_ID:-default}"
mkdir -p "$run_dir"

input=$(cat)
tokens=$(printf '%s' "$input" | python3 -c "
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    print(0)
    sys.exit()

resp = data.get('tool_response')
tokens = 0
if isinstance(resp, dict):
    tokens = resp.get('totalTokens') or 0
print(int(tokens) if tokens else 0)
")

tokens=${tokens:-0}
if [ "$tokens" -gt 0 ] 2>/dev/null; then
  echo "$tokens" >> "$run_dir/subagent_tokens.count"
fi

exit 0
