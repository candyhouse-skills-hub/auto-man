#!/bin/bash
# PreToolUse hook (matcher: Bash) — deterministic denylist, independent of permission mode.
# Fires before permission checking, so it still blocks under auto/bypassPermissions modes.
# Contract: exit 2 + stderr reason = deny. exit 0 = allow (defers to normal permission flow).

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
