#!/bin/bash
# selftest.sh — self-test for THIS skill's own templates/ and recipes/.
# Run before merging any change under templates/ or recipes/ (SKILL.md
# Step 6/7 require it). Exits 0 if every check passes; non-zero and prints
# which check(s) failed otherwise. Read-only against the skill repo itself —
# all instantiation happens in a throwaway scratch directory.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAIL=1; }

echo "== 1. Hook scripts and *.sh.tmpl templates: bash syntax check =="
for h in "$SKILL_DIR"/templates/hooks/*.sh "$SKILL_DIR"/templates/*.sh.tmpl; do
  name="$(basename "$h")"
  if bash -n "$h" >/dev/null 2>&1; then pass "$name"; else fail "$name (syntax error)"; fi
done

echo "== 2. Every *.json template/schema file is valid JSON =="
for j in "$SKILL_DIR"/templates/*.json; do
  name="$(basename "$j")"
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$j" >/dev/null 2>&1; then
    pass "$name"
  else
    fail "$name (invalid JSON)"
  fi
done

echo "== 3. Every recipe has all 4 mandated sections (recipes/README.md's contract) =="
for r in "$SKILL_DIR"/recipes/*.md; do
  [ "$(basename "$r")" = "README.md" ] && continue
  rn="$(basename "$r")"
  for section in "## Applies to" "## Verify snippets" "## Known pitfalls" "## CLAUDE.md conventions to append"; do
    if grep -qF "$section" "$r"; then
      pass "$rn has '$section'"
    else
      fail "$rn missing '$section'"
    fi
  done
done

echo "== 4. Every recipe listed in 'Available recipes' actually exists on disk, and vice versa =="
listed=$(grep -oE '^- \`[^\`]+\.md\`' "$SKILL_DIR/recipes/README.md" | sed -E 's/^- `([^`]+)`/\1/')
on_disk=$(cd "$SKILL_DIR/recipes" && ls *.md | grep -v '^README.md$')
for f in $listed; do
  if [ -f "$SKILL_DIR/recipes/$f" ]; then pass "listed recipe $f exists"; else fail "listed recipe $f does NOT exist on disk"; fi
done
for f in $on_disk; do
  if echo "$listed" | grep -qx "$f"; then pass "on-disk recipe $f is listed"; else fail "on-disk recipe $f is NOT registered in README.md"; fi
done

echo "== 5. No recipe/template teaches the \$TMP_DIR-for-add_artifact anti-pattern =="
# This is the exact bug class that shipped for weeks after verify.sh.tmpl
# itself was fixed to use $ARTIFACTS_DIR — a recipe kept handing out the old
# pattern. Any occurrence here means an artifact path will be deleted (by
# verify.sh's own `trap rm -rf $TMP_DIR EXIT`) before a judge subagent, which
# runs AFTER verify.sh exits, can ever read it.
bad_hits=$(grep -rn 'add_artifact "\$TMP_DIR' "$SKILL_DIR/templates" "$SKILL_DIR/recipes" 2>/dev/null || true)
if [ -z "$bad_hits" ]; then
  pass "no bare \$TMP_DIR passed to add_artifact anywhere"
else
  fail "found \$TMP_DIR passed to add_artifact (artifact will be deleted before a judge can read it):"
  echo "$bad_hits" | sed 's/^/       /'
fi

echo "== 6. verify.sh.tmpl harness: an artifact registered via ARTIFACTS_DIR survives past the script's own exit =="
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
(
  cd "$SCRATCH" || exit 1
  mkdir -p .workflow

  # Splice one passing criterion + one artifact registration into the
  # template right before its evidence-writing python block — mirrors what
  # Step 2 does at real instantiation time, without needing a full project.
  python3 - "$SKILL_DIR/templates/verify.sh.tmpl" .workflow/verify.sh <<'SPLICE_EOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
content = open(src).read()
marker = 'python3 - "$EVIDENCE_PATH" "$CRITERIA_FILE" "$ARTIFACTS_FILE" <<\'PYEOF\''
idx = content.index(marker)
snippet = (
    'echo "selftest artifact contents" > "$ARTIFACTS_DIR/selftest.txt"\n'
    'add_artifact "$ARTIFACTS_DIR/selftest.txt"\n'
    'add_criterion "selftest_dummy" 1 "always passes"\n\n'
)
open(dst, 'w').write(content[:idx] + snippet + content[idx:])
SPLICE_EOF
  chmod +x .workflow/verify.sh

  if bash .workflow/verify.sh >/dev/null 2>&1; then
    echo "  ok   verify.sh exits 0 when all criteria pass"
  else
    echo "  FAIL verify.sh exited non-zero even though only a passing criterion was added"
    echo "FAILMARK" >> "$SCRATCH/.result"
  fi

  if [ -f .workflow/evidence.json ] && python3 -c "
import json,sys
d = json.load(open('.workflow/evidence.json'))
sys.exit(0 if d.get('allPass') is True and len(d.get('criteria', [])) >= 1 else 1)
" ; then
    echo "  ok   evidence.json has allPass:true and a non-empty criteria list"
  else
    echo "  FAIL evidence.json missing, malformed, or allPass not true"
    echo "FAILMARK" >> "$SCRATCH/.result"
  fi

  if [ -f .workflow/artifacts/selftest.txt ]; then
    echo "  ok   artifact file still exists on disk after verify.sh exited (THE regression this guards)"
  else
    echo "  FAIL artifact file is gone after verify.sh exited — TMP_DIR-cleanup bug has regressed"
    echo "FAILMARK" >> "$SCRATCH/.result"
  fi

  python3 -c "
import json, os, sys
d = json.load(open('.workflow/evidence.json'))
missing = [a for a in d.get('artifacts', []) if not os.path.exists(a)]
sys.exit(1 if missing else 0)
" && echo "  ok   every path evidence.json lists under 'artifacts' still exists" \
   || { echo "  FAIL evidence.json references an artifact path that no longer exists"; echo "FAILMARK" >> "$SCRATCH/.result"; }
)
if [ -f "$SCRATCH/.result" ]; then FAIL=1; fi

echo "== 7. arch-delta.sh.tmpl harness: shape is derived correctly, review answer round-trips, unfilled placeholder refuses =="
SCRATCH2=$(mktemp -d)
trap 'rm -rf "$SCRATCH" "$SCRATCH2"' EXIT
(
  cd "$SCRATCH2" || exit 1
  git init -q .
  git config user.email "selftest@example.com"
  git config user.name "selftest"
  echo "console.log('hello')" > src.js
  echo '{"name":"x","version":"1.0.0"}' > package.json
  echo "test('x', () => {})" > src.test.js
  git add -A && git commit -q -m "base"
  BASE_REF=$(git rev-parse HEAD)

  # Synthetic diff: one file added, one modified, one deleted — enough to
  # exercise every derived field independently.
  echo "function login() {}" > login.js
  echo '{"name":"x","version":"2.0.0"}' > package.json
  rm src.test.js
  git add -A && git commit -q -m "change"

  mkdir -p .workflow
  sed -e "s/{{BASE_REF}}/$BASE_REF/" -e "s/{{HUMAN_REVIEW_REQUESTED}}/true/" \
    "$SKILL_DIR/templates/arch-delta.sh.tmpl" > .workflow/arch-delta.sh
  chmod +x .workflow/arch-delta.sh

  if output=$(bash .workflow/arch-delta.sh 2>.workflow/arch-delta.stderr); then
    echo "  ok   arch-delta.sh exits 0 on a normal diff"
  else
    echo "  FAIL arch-delta.sh exited non-zero: $(cat .workflow/arch-delta.stderr 2>/dev/null)"
    echo "FAILMARK" >> "$SCRATCH2/.result"
  fi

  if echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
required = {'filesTouched','diffLoc','newFiles','deletedFiles','humanReviewRequested'}
missing = required - set(d.keys())
assert not missing, f'missing fields: {missing}'
assert d['humanReviewRequested'] is True, 'humanReviewRequested did not round-trip as boolean true'
assert d['filesTouched'] == 3, f'expected 3 filesTouched, got {d[\"filesTouched\"]}'
assert d['newFiles'] == ['login.js'], f'expected [login.js], got {d[\"newFiles\"]}'
assert d['deletedFiles'] == ['src.test.js'], f'expected [src.test.js], got {d[\"deletedFiles\"]}'
assert d['diffLoc'] > 0, 'diffLoc should be non-zero for a real diff'
" 2>.workflow/arch-delta-assert.stderr; then
    echo "  ok   derived shape is correct and humanReviewRequested round-trips as a real boolean"
  else
    echo "  FAIL derived shape wrong or review answer lost: $(cat .workflow/arch-delta-assert.stderr 2>/dev/null)"
    echo "FAILMARK" >> "$SCRATCH2/.result"
  fi

  # The Step 0 question being skipped must be a hard stop, not a silent
  # default — a fabricated "false" here would record oversight the user
  # never actually declined.
  sed -e "s/{{BASE_REF}}/$BASE_REF/" "$SKILL_DIR/templates/arch-delta.sh.tmpl" > .workflow/arch-delta-unfilled.sh
  if bash .workflow/arch-delta-unfilled.sh >/dev/null 2>&1; then
    echo "  FAIL arch-delta.sh ran with an unfilled HUMAN_REVIEW_REQUESTED instead of refusing"
    echo "FAILMARK" >> "$SCRATCH2/.result"
  else
    echo "  ok   refuses to run when the Step 0 review question was never answered"
  fi

  if python3 - "$SKILL_DIR/templates/arch-delta.schema.json" .workflow/artifacts/arch-delta.json <<'PYEOF'
import json, sys
schema = json.load(open(sys.argv[1]))
row = json.load(open(sys.argv[2]))
props = schema["properties"]
missing = [k for k in row if k not in props]
sys.exit(1 if missing else 0)
PYEOF
  then
    echo "  ok   every field arch-delta.sh emits is declared in arch-delta.schema.json"
  else
    echo "  FAIL arch-delta.sh emitted a field not declared in arch-delta.schema.json"
    echo "FAILMARK" >> "$SCRATCH2/.result"
  fi
)
if [ -f "$SCRATCH2/.result" ]; then FAIL=1; fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "selftest: ALL CHECKS PASSED"
  exit 0
else
  echo "selftest: ONE OR MORE CHECKS FAILED — do not merge/publish until fixed"
  exit 1
fi
