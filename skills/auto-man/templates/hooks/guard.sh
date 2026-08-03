#!/bin/bash
# PreToolUse hook (matcher: Bash) — deterministic denylist, independent of permission mode.
# Fires before permission checking, so it still blocks under auto/bypassPermissions modes.
# Contract: exit 2 + stderr reason = deny. exit 0 = allow (defers to normal permission flow).
#
# Unlike the other two hooks (loop-log.sh writes iteration.count every turn,
# token-tally.sh writes subagent_tokens.count whenever a subagent runs),
# guard.sh previously wrote NOTHING on any path — allow, deny, or never
# invoked at all were indistinguishable from the outside. Since it's the
# security-relevant hook, that was the single worst blind spot in the chain:
# a run where it silently never fired would look identical to a run where it
# fired and never needed to block anything. Fix: increment a count file on
# every invocation, before the denylist check, so its firing (or non-firing —
# see SKILL.md Step 5's -p-mode hook-silence note) becomes independently
# checkable the same way the other two hooks already are.
run_dir=".workflow/logs/run-${LOOP_RUN_ID:-default}"
mkdir -p "$run_dir" 2>/dev/null
prev=$(cat "$run_dir/guard_invocations.count" 2>/dev/null || echo 0)
echo $((prev + 1)) > "$run_dir/guard_invocations.count" 2>/dev/null

input=$(cat)
command=$(printf '%s' "$input" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('tool_input', {}).get('command', ''))
except Exception:
    print('')
")

if [ -z "$command" ]; then
  exit 0
fi

blocklist=(
  '(^|[; ])rm[[:space:]]+-rf[[:space:]]+/([[:space:]]|$)'
  '(^|[; ])rm[[:space:]]+-rf[[:space:]]+~([[:space:]]|$)'
  'rm[[:space:]]+-rf[[:space:]]+\$HOME'
  'rm[[:space:]]+-rf[[:space:]]+[^[:space:]]*\.\.'
  '(^|[; ])git[[:space:]]+push'
  '(^|[; ])git[[:space:]]+reset[[:space:]]+--hard'
  '(^|[; ])git[[:space:]]+clean[[:space:]]+-f'
  '(^|[; ])sudo[[:space:]]'
  'curl[^|]*\|[[:space:]]*(sh|bash|zsh)'
  'wget[^|]*\|[[:space:]]*(sh|bash|zsh)'
  'npm[[:space:]]+run[[:space:]]+clean:all'
  ':\(\)\{[[:space:]]*:\|:&[[:space:]]*\};:'
)

for pattern in "${blocklist[@]}"; do
  if echo "$command" | grep -qE "$pattern"; then
    echo "guard.sh: blocked — command matches denylist pattern [$pattern]: $command" >&2
    exit 2
  fi
done

exit 0
