---
name: auto-man
description: Bootstrap a zero-human-intervention delivery loop for a task with machine-checkable success criteria — instantiates verify.sh/goal-condition/hooks templates into an isolated workspace, runs a supervised first pass, then hands off via /goal. Use when the user wants a task delivered end-to-end without babysitting every step, not for open-ended exploration.
argument-hint: "[target-path] [task or plan — a detailed plan is the ideal input]"
disable-model-invocation: true
---

## Preconditions — check before instantiating anything

Refuse to proceed (ask the user instead) if any of these are missing:
- **Machine-checkable success criteria.** If the user's request only has vague criteria ("looks right", "works well"), ask them to narrow it to something a script or a fresh judge subagent could pass/fail — this whole skill is built on verify.sh being able to say pass/fail without asking an LLM's opinion of its own work. This is the one hard gate. The *ideal* input that carries these criteria (along with scope and exemptions) is a detailed plan; a thinner input — a one-line task description — is accepted, but Step 0 turns it into a confirmed plan before anything runs. Don't proceed to instantiation or hands-off on a vague spec.
- **A location that can be isolated.** See Step 1 — this doesn't have to be an existing git repo; if the starting point is genuinely ambiguous (no path given, unclear whether to create new or modify existing), ask the user rather than guessing.
- **The session's permission mode is `auto` (or `acceptEdits` as a documented fallback), not the default manual mode.** This skill's instructions cannot change your permission mode for you — that's a session-level setting, and a skill silently escalating it would be a real security problem. Both Step 3 and Step 4 are designed to run under the *same* permission mode; what distinguishes "supervised" from "hands-off" is whether `/goal` is active, not whether every tool call stops to ask. If you notice tool calls being prompted for confirmation one by one, or you have no way to confirm `auto` mode is active, stop and tell the user directly: they need to relaunch with `claude --permission-mode auto`, or switch modes mid-session, before you continue. Don't push through Step 3 treating per-call prompts as an acceptable substitute for the intended per-turn checkpoint.

## Where this skill lives (read before Step 6 ever edits anything)

This skill is typically installed as a git-based marketplace plugin: `${CLAUDE_SKILL_DIR}` resolves to a path under `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/...` — a shallow git clone pinned at whatever commit was current at last install/update, at a version-numbered path that generally does **not** change between updates (e.g. `0.1.0` stays `0.1.0` until someone bumps it). Any edit made only there is invisible outside this one machine, and **is silently discarded the next time `/plugin update` (or a reinstall) runs**, since that re-fetches into the exact same directory. This has already happened once in practice: four real fixes accumulated as uncommitted local modifications in a cache directory, none reached the actual source repo, and one of them (a template bug) was still shipping to every fresh install weeks later.

Step 6 ("Close the loop") must write into this skill's **source repository** — the git repo this plugin is actually built and published from — never the cache path. Find it, in order: (a) a path the user has already told you about; (b) `git -C "${CLAUDE_SKILL_DIR}" remote -v` — if it points at a real, non-empty, pushable origin and `git status`/`git log` there look like a normal working repo, treat that as the source and work directly in it (a shallow clone pinned to one old commit, or a repo with no remote, is a sign you're still looking at the cache, not the source); (c) ask the user directly where the source repo lives.

**Hard rule: if you cannot find or confirm an actual source repo, do not write anything under `${CLAUDE_SKILL_DIR}` in Step 6.** Stop and report the recommended changes to the user as a proposal instead — see the automation boundary in Step 6 below. A cache-only edit is worse than no edit: it creates the appearance of durability while being one `/plugin update` away from silent deletion.

The publish chain, once you're in the real source: commit → push to its remote → bump the version field in `.claude-plugin/plugin.json` (this is what makes a subsequent `/plugin update` actually pull fresh content into a *new* cache directory, rather than a no-op against the same pinned path) → tell the user to run `/plugin update` (or reinstall) to refresh their local cache. You cannot run `/plugin update` yourself — it's a user-facing command, not a tool call — so this last step is always a handoff.

## Step 0 — Establish the plan you work from

The hands-off phase (Step 4) runs unattended across many turns in `auto` mode — the single biggest lever against it drifting is a precise spec fixed *before* it starts. So the input you actually execute from is always a detailed plan: the task, its machine-checkable acceptance criteria, the scope boundaries, and any known-unfixable exemptions. Everything Step 2 fills into `verify.sh` and `goal-condition.txt` comes from here.

- **If the user handed you a detailed plan**, use it — just confirm it actually carries concrete, machine-checkable criteria (see Preconditions), and fill any gaps by asking.
- **If the input is thin** (a one-line description, a vague ask), your first job is to *elevate* it into that plan yourself — draft the criteria/scope/exemptions and get the user to confirm them — before you isolate anything or copy a single template. A one-liner is an accepted starting point, not an accepted spec to run autonomously on.

Do not move on to Step 1 until the plan is confirmed. This is not the same as requiring the user to write a plan — it's requiring one to *exist and be agreed* before the unattended loop starts.

**Ask the user, as part of confirming the plan: "once this is done, do you want to review the diff yourself?"** Ask it plainly, get an explicit yes or no, and carry the answer forward — Step 2 writes it into `arch-delta.sh`, Step 6 reminds on it, Step 8 routes on it. The user knows their own codebase's stakes; whether a change deserves their eyes is a domain judgment they make far more reliably than any heuristic run against the finished diff.

Do not infer this answer, and do not skip the question because the task "obviously" is or isn't risky. An unanswered question is not a "no" — if the user hasn't said, you don't have an answer, and `arch-delta.sh` will refuse to run rather than record a fabricated one.

**If the plan naturally splits into phases the user might plausibly want to stop between, inspect, or change course on** (not just a long todo list with sequential sections), this is also where you ask how that gets gated — see "Multi-phase plans" below for the exact question, what it changes, and when it's not worth the overhead.

## Multi-phase plans — repeating Steps 1–6 per phase

Skip this section for a single-phase plan; nothing above or below changes for that case. Use it when phases are separably verifiable and separately deliverable — if a later phase can't actually be checked or shipped without pieces only an earlier phase builds, that coupling is a signal to run the plan as one phase instead, since gating between them would add friction without giving the user a real choice.

**Decide this at Step 0, once, alongside the review-diff question — never mid-run:**

1. **Is this actually multi-phase?** If genuinely ambiguous, ask; don't infer it just because the plan has numbered sections.
2. **What cadence gates the phases?** Ask the user directly — same non-inference rule as the review-diff question, an unanswered question is not a default of any kind:
   - `every_phase` — stop and ask before starting each next phase. Max control, max friction.
   - `batch` (with an N) — stop only after every N phases land.
   - `batch_review_at_end` — never stop in real time; run every phase back to back, and let Step 8's batch review be the actual checkpoint. This trades a real-time abort (if phase 2 goes sideways, phase 3 still runs before anyone notices) for throughput — say so plainly when offering it.

Write both answers into `.workflow/state.json`'s `gateCadence`/`gateBatchSize` at Step 2, alongside seeding `phases[]` (one entry per phase, `status: "pending"`, its own slice of the acceptance criteria in `criteriaNames`) and `currentPhase` pointing at the first one.

**What stays a one-time, whole-plan operation — do not repeat these per phase:**
- Step 1's isolation: one shared workspace/worktree for the entire plan.
- Copying `templates/` into the workspace (Step 2's `mkdir`/`cp` block).
- `planBaseRef` — the commit recorded right after isolating, kept in `state.json` distinct from any single phase's own start commit below.

**What repeats per phase:**
- **Start of phase:** capture `git rev-parse HEAD` as *this phase's* `baseRef` (`state.json`'s `phases[i].baseRef`), and re-fill `.workflow/arch-delta.sh`'s `BASE_REF=`/`PHASE_NAME=` lines to that commit and this phase's name — this phase's arch-delta row must diff against where *it* started, not where the whole plan started. Set `currentPhase` and this phase's `status` to `"in_progress"`.
- **`verify.sh` accumulates, it doesn't reset.** Each phase *adds* its own `add_criterion` checks to the same `.workflow/verify.sh` rather than starting a fresh file — so `allPass` at any phase's success stop means "everything shipped so far, including this phase," which also catches phase N regressing something phase N-1 already delivered. `state.json`'s `criteriaPending` for this phase is just its own new criteria; prior phases' criteria stay in `criteriaMet` untouched.
- **`goal-condition.txt` is rewritten per phase, not shared:** `{{SUCCESS_CRITERIA}}` names only this phase's criteria, and `{{PHASE_BOUNDARY_CLAUSE}}` (see the template's own comments) gets filled in — this is what makes the phase boundary something the nested hands-off session itself refuses to cross, instead of something only the orchestrator remembers to enforce from outside.
- Steps 3–5 run exactly as documented, scoped to this phase. Step 4's `MAX_TURNS` is re-derived from *this phase's* supervised-pass turn count — don't reuse an earlier phase's number; the ledger's phase-tagged rows (below) give you comparable history once a few phases have run.
- **Step 6 delivers this phase incrementally** — cherry-pick/merge/PR just this phase's commits, the same way Step 1 already asks you to decide for the whole plan. This is what makes stopping after phase 2 meaningful: the user keeps whatever shipped, instead of everything sitting stranded on one unmerged branch until the last phase closes. Mark `phases[i].status: "done"` and `deliveredAt`.
- Ledger and arch-delta rows are **per phase, not per plan** — tag both with `phase: "<name>"` (see the schemas) so Step 4's `MAX_TURNS` derivation and Step 8's batch review can tell a plan's phases apart instead of reading them as unrelated runs.
- **After Step 6, before touching the next phase:** consult `gateCadence`. `every_phase` → stop, give the user this phase's normal Step 6 report, and wait for explicit go-ahead. `batch` → only stop once `gateBatchSize` phases have landed since the last stop. `batch_review_at_end` → advance `currentPhase` and start the next phase's Step 2–6 immediately, no pause. Whichever fires, do not start the next phase's implementation work before the check — that's the entire point of picking a cadence at Step 0 instead of always barreling through.

When the last phase's Step 6 closes, `currentPhase` goes to `null` and the plan is done — Step 7/8 read across all its phases exactly like any other run.

## Step 1 — Isolate the automation run

Isolation exists to serve two goals, not to mandate any one mechanism:
1. **Fully discardable.** Step 4 runs unattended, multiple turns, in `auto` permission mode. If it goes sideways, the whole attempt must be discardable without touching the user's real working tree, uncommitted changes, or current branch.
2. **A clean cwd for the nested session.** Hooks (`guard.sh`/`token-tally.sh`/`loop-log.sh`) only fire for an active `claude` process running with the isolated location as its cwd (see Step 2) — driving it from outside via a different cwd never exercises them.

Pick the mechanism from the target's actual starting shape — don't default to one option regardless of context:

| Starting shape | Mechanism |
|---|---|
| Existing git repo, full isolation wanted (**default**) | `git worktree add ../<name>-autodeliver <new-branch-name>` after confirming `git status` is clean enough not to be disturbed |
| Existing git repo, worktree doesn't fit (user wants the same checkout, or the environment can't support worktrees) | A dedicated new branch in place; explicitly tell the user working-tree-level changes are *not* isolated and uncommitted content is at risk; require a clean tree before starting |
| Existing non-git directory | Copy it into a scratch directory (or `git init` it first to get a clean rollback point) and work there |
| Greenfield (nothing exists yet) | Create a new empty directory (optionally `git init` it for easy rollback) |
| Multiple repos involved | Isolate each repo that will be written to; set the nested session's cwd to whichever one is the primary target |
| Explicit in-place (user asked for it and accepts the risk) | Only when the tree is clean and revertible; record in the final report that isolation was skipped by request |
| None of the above is clear | Ask the user |

Whatever mechanism is chosen, the isolated location must end up with `.claude/settings.json` in place and be the nested session's cwd — otherwise the hooks in Step 2 silently never fire.

**Decide the delivery path now, not after the work is done.** The isolated location (a worktree, a scratch clone) is a discardable *verification site*, not the deliverable itself — a passing `verify.sh` there proves the fix works, it doesn't get it in front of the user. Before Step 3 starts, settle how the result will actually land: cherry-pick the finished commit(s) onto the real branch, merge the branch, open a PR, or (for a non-git target) copy the changed files back — and say so in your plan. A worktree left on an unmerged branch with nobody told to merge it is a run that quietly delivered nothing.

**Record the starting commit now — Step 2 needs it.** Immediately after isolating (before any implementation edit), run `git rev-parse HEAD` in the isolated location and keep the hash. This is `{{BASE_REF}}`: the fixed point Step 6's `arch-delta.sh` diffs against to derive what changed, so it must be captured before the first implementation commit, not reconstructed afterward from guesswork. For a multi-phase plan, this one capture is the whole-plan `planBaseRef`; each phase additionally captures its own start commit when that phase begins — see "Multi-phase plans" above.

## Step 2 — Instantiate templates

Copy everything from `${CLAUDE_SKILL_DIR}/templates/` into the isolated workspace:

```bash
mkdir -p .claude/hooks .workflow
cp ${CLAUDE_SKILL_DIR}/templates/hooks/*.sh .claude/hooks/ && chmod +x .claude/hooks/*.sh
cp ${CLAUDE_SKILL_DIR}/templates/settings.json.tmpl .claude/settings.json
cp ${CLAUDE_SKILL_DIR}/templates/verify.sh.tmpl .workflow/verify.sh && chmod +x .workflow/verify.sh
cp ${CLAUDE_SKILL_DIR}/templates/goal-condition.tmpl .workflow/goal-condition.txt
cp ${CLAUDE_SKILL_DIR}/templates/lessons.md.tmpl .workflow/lessons.md
cp ${CLAUDE_SKILL_DIR}/templates/state.schema.json .workflow/state.schema.json
cp ${CLAUDE_SKILL_DIR}/templates/loop-entry.schema.json .workflow/loop-entry.schema.json
cp ${CLAUDE_SKILL_DIR}/templates/arch-delta.sh.tmpl .workflow/arch-delta.sh && chmod +x .workflow/arch-delta.sh
cp ${CLAUDE_SKILL_DIR}/templates/arch-delta.schema.json .workflow/arch-delta.schema.json
```

Append `${CLAUDE_SKILL_DIR}/templates/CLAUDE.md.tmpl`'s content to the workspace's `CLAUDE.md` (create it if absent).

**Domain match (do this before filling placeholders):** `ls ${CLAUDE_SKILL_DIR}/recipes/` and read each recipe's "Applies to" section. If one genuinely matches this task's domain, seed `.workflow/verify.sh`'s checks from its "Verify snippets" section and append its "CLAUDE.md conventions to append" section into `CLAUDE.md`. When it's not a clear match, don't force it — fall back to writing checks from first principles below. Getting this wrong costs nothing (worst case: you write the checks yourself instead of adapting a recipe's).

Fill every `{{PLACEHOLDER}}` in `.workflow/verify.sh` (project-specific pass/fail checks — this is the part that can't be templated, it's the actual acceptance logic), `.workflow/goal-condition.txt` (success/safety/no-progress/blocked clauses — all four are mandatory, not just success; only fill `{{JUDGE_CLAUSE}}` if some criterion genuinely needs semantic/visual judgment, see the template's own comments), `.workflow/arch-delta.sh`'s two placeholders (`{{BASE_REF}}` — the commit hash you recorded in Step 1; and `{{HUMAN_REVIEW_REQUESTED}}` — literally `true` or `false`, straight from the user's Step 0 answer, never your own guess), and `CLAUDE.md`'s scope statement. Use the task description the user gave you to derive these; ask a clarifying question if the criteria are genuinely ambiguous rather than guessing. For a multi-phase plan, both `goal-condition.txt` and `arch-delta.sh`'s `BASE_REF`/`PHASE_NAME` get refilled per phase rather than once — see "Multi-phase plans" above for exactly what's one-time vs per-phase.

**Writing `verify.sh` checks from first principles (no matching recipe):** every criterion needs a command-level deterministic signal — an exit code, a file's existence, a count of matching lines in a properly-scoped log. Wrap anything that talks to a flaky external daemon in the provided `retry()` helper. Never put LLM judgment inside `verify.sh` itself — that's the judge subagent's job (see the `{{JUDGE_CLAUSE}}` note above), and only when the task actually needs it.

**Prefer a behavioral check over a structural one whenever the project has the test infrastructure for it.** A criterion like "does this identifier appear ≥3 times in this file" (a structural grep) only proves a *shape* exists — a session could satisfy it without the feature actually working. When the project already has a test runner, a criterion that actually exercises the behavior (a unit/integration test asserting the real outcome) is strictly stronger and should be preferred. Structural/grep checks are a reasonable fallback when there's no test infrastructure to hook into (and are far better than no check at all) — just don't reach for them by default when a real behavioral assertion is available.

Seed `.workflow/state.json` from `state.schema.json` with `iteration: 0` and the acceptance criteria names in `criteriaPending`. For a multi-phase plan, also seed `phases[]`/`currentPhase`/`gateCadence`/`gateBatchSize` from the Step 0 answers — see "Multi-phase plans" above.

**Bootstrap the workspace and run a baseline check before writing any implementation code.** An isolated workspace (a fresh worktree, a fresh clone) usually does not have installed dependencies (`node_modules/`, a Python venv, etc. are normally gitignored) — running `verify.sh` against a dependency-less workspace fails with a misleading error (e.g. "eslint: command not found") that looks like a code problem but is actually an environment problem. Install whatever the project's package manager needs (`npm i` / `pip install -r requirements.txt` / etc.) first, then run `.workflow/verify.sh` **once, before any implementation work**, and read *why* it fails. Confirm it fails for the right reason — the feature genuinely doesn't exist yet — not a wrong reason (a missing tool, a broken import, a criterion that would trivially pass on unmodified code). This is the only way to know your criteria can actually detect absence before you rely on them to detect presence.

## Step 3 — Supervised first pass (no `/goal`)

Work the task normally in this same session, in plain language, checking in at natural milestones (the ones you and the user agree matter — don't invent extra pauses). Without `/goal` active, you already stop and wait for the next message after each turn — that pause *is* the checkpoint, no extra mechanism needed.

Every time something breaks in a way that needed a manual fix: record it in `.workflow/lessons.md` immediately, and route the fix appropriately — project-specific to this project's `CLAUDE.md`, domain-generalizable to a note for a `${CLAUDE_SKILL_DIR}/recipes/<domain>.md` addition, universally generalizable to a note for a `${CLAUDE_SKILL_DIR}/templates/` change (see Step 6 for the actual edit). Don't defer this to "later," do it the moment you find it.

Before declaring the first pass done, run `.workflow/verify.sh` yourself and confirm `allPass: true` in the resulting `evidence.json`. Do not declare success on your own narrative — only on that file's contents.

## Step 4 — Hands-off validation

Only after step 3 is clean, test whether the loop can run with zero intervention. Do this **in a separate nested session**, not by continuing to drive it yourself — hooks (`guard.sh`/`token-tally.sh`/`loop-log.sh`) only fire for tool calls made by a live `claude` process running with the isolated workspace as cwd; driving it from outside via a different tool does not exercise them.

**Determine `MAX_TURNS` first — from real data, not a guess.** Step 3 just ran; you know how many turns/iterations the supervised pass actually took to reach a clean state. Set `MAX_TURNS ≈ that count × 2.5–3`. Don't reuse a number from a different project's run — turn counts aren't portable across tasks.

Bias the multiplier upward (toward 3, or higher) whenever Step 3's supervised pass benefited from context the fresh nested session won't have — e.g. you had already explored/read the relevant files earlier in the same conversation, or you already knew the exact plan/file/line targets before Step 3 started. The nested session in Step 4 starts stone cold: it has to rediscover the codebase, re-derive the same plan, make the edits, *and* run verify.sh itself, all inside `MAX_TURNS`. A run observed in practice: a 3-file, ~40-line diff supervised pass that took a handful of turns (with pre-existing exploration context) still needed all of a `turns×3`-derived `MAX_TURNS=15` budget for the fresh session, and hit the cap having *already produced a fully passing diff* — it simply hadn't gotten to declaring success yet. When in doubt, round up rather than down; a wasted turn budget is far cheaper than a false "safety stop" on a task that actually succeeded. **Better than either guess: if `~/.claude/auto-man/ledger.jsonl` has 3+ prior rows with a comparable `taskShape` (similar `filesTouched`/`diffLoc`, same `hasTestInfra`), set `MAX_TURNS = max(turnsUsed among successful comparable rows) × 1.5` instead of guessing from this run's `supervisedTurns` alone — see the ledger described in Step 6.**

**Determine `BUDGET_USD` — this is the user's call, not yours to guess.** Check in this priority order:
1. Did the user's task description or plan (if one exists) explicitly state a budget? Use it.
2. If not, **ask the user directly** before running anything: "this hands-off run needs a hard dollar cap — what's your limit?" If prior runs on this same project have a `total_cost_usd` in `loop.jsonl`, mention it as context ("a similar run cost about $X last time"), but don't pick the number for them.
3. Never silently default to a made-up constant. If the user says "you decide," say so explicitly in your report afterward — that's still a real decision being made, just delegated, and it should be visible as one rather than presented as if it were principled.

```bash
cd <isolated workspace>
# NOTE: no "run-" prefix here — both loop-log.sh and token-tally.sh already
# prepend "run-" to this value when building their log directory path
# (`.workflow/logs/run-${LOOP_RUN_ID:-default}`). Including it here too
# produces a doubled `run-run-20260101-...` directory name (observed in
# practice, harmless but confusing to cross-reference by hand).
export LOOP_RUN_ID="$(date +%Y%m%d-%H%M%S)"
env LOOP_RUN_ID="$LOOP_RUN_ID" claude \
  --permission-mode auto \
  --max-turns "$MAX_TURNS" \
  --max-budget-usd "$BUDGET_USD" \
  --output-format json \
  -p "/goal $(cat .workflow/goal-condition.txt)"
```

Notes learned the hard way, don't skip these:
- `--output-format json` is required to get any usage/cost data out of the run — default text output prints only the final reply.
- `--max-turns`/`--max-budget-usd` only work in `-p` mode, not with `--bg`. If the user wants a truly detached background run instead (`claude --permission-mode auto --bg "/goal ..."`, managed via `claude agents`/`claude logs <id>`/`claude attach <id>`/`claude stop <id>`), those two flags won't protect you there — the `/goal` condition text's own safety-stop and no-progress-stop clauses are the only backstop in that mode, so make sure both are actually present in the condition (see `goal-condition.tmpl`'s comments). The `--bg` + `/goal` combination has no documented guarantee of working as expected — confirm it on a throwaway prompt before relying on it for a real run, and confirm with the user before using `--bg` at all since it detaches from anything they're watching.
- Before a first-ever hands-off run on a new workflow, suggest the user also set an account-level spend backstop (`/usage-credits` monthly limit, or a workspace spend limit) — not a substitute for `BUDGET_USD` above, but a last resort if the condition text itself turns out to have a hole.

## Step 5 — Verify the hooks actually fired, don't trust the session's self-report

After the run, check the mechanical files directly — do not accept the session's own claim that a hook "worked":

```bash
cat .workflow/logs/run-$LOOP_RUN_ID/loop.jsonl        # mechanical + semantic entries should both be present
cat .workflow/logs/run-$LOOP_RUN_ID/subagent_tokens.count   # should exist if any subagent ran synchronously
cat .workflow/logs/run-$LOOP_RUN_ID/guard_invocations.count # should exist and be >0 if any Bash tool call happened at all
```

`guard_invocations.count` existing and being roughly in the ballpark of how many Bash calls you'd expect is your only signal that the security denylist was actually in the loop at all — unlike the other two hooks, `guard.sh` previously wrote nothing on any path, so its silent non-firing was completely undetectable. If it's missing despite Bash calls having clearly happened, treat that the same as any other hook-silence finding below: don't assume commands were screened.

If `subagent_tokens.count` is missing despite subagents having run, or the JSON output's `usage` fields don't reconcile with what the session claimed, that's a real bug in the hook chain, not a fluke — debug it the same way this skill's own templates were debugged: temporarily tee the hook's raw stdin to a file and inspect the actual payload shape rather than assuming.

**Known behavior, confirmed by comparing multiple runs' `loop.jsonl` mechanical-entry counts against their `terminal_reason`**: in `-p`/`--output-format json` mode, the Stop hook (`loop-log.sh`) fires **at most once per invocation — at the very end, only if the session reaches a natural stop.** When `--max-turns` (or `--max-budget-usd`) forcibly truncates the run before that (`terminal_reason: max_turns`), the Stop hook does not fire at all, so `.workflow/logs/run-$LOOP_RUN_ID/` may never even get created — despite the session having made real file edits and `verify.sh` passing when run by hand afterward. (Cross-run data: a `-p` run that reached `terminal_reason: success` logged exactly 1 mechanical entry; a `-p` run that hit `terminal_reason: max_turns` logged 0; interactive sessions logged one mechanical entry per visible turn, e.g. 12 and 3 in two other runs — confirming `-p` mode's "one turn" from the Stop hook's perspective is the *entire invocation*, not each internal agentic-loop iteration.) **Do not treat an empty/missing `loop.jsonl` after a `-p` mode run as proof the run did nothing** — it is only proof the run didn't reach a natural stop within its turn/budget cap; check `git status`/`git diff` in the isolated workspace and rerun `verify.sh` directly before concluding the task made no progress. Treat Step 5's hook-log checks as corroborating evidence when the run *succeeded*, not as a requirement when it was truncated — always cross-check with `verify.sh`'s own evidence.json regardless of `terminal_reason`.

Append an honest `run_summary` entry to `loop.jsonl`, using exactly the field names in `${CLAUDE_SKILL_DIR}/templates/loop-entry.schema.json` (copied into `.workflow/loop-entry.schema.json` at Step 2) — this schema was revised after real runs invented ad-hoc, inconsistent names for the same fields (see below), so treat it as authoritative rather than improvising your own: `mainSessionTokens` from the `--output-format json` result's `usage` fields (sum of `input_tokens` + `output_tokens` + `cache_creation_input_tokens` + `cache_read_input_tokens`), `subagentTokensSum` from summing `subagent_tokens.count`, `totalTokens` as their sum. If either is genuinely unavailable, write `null` for it and let `totalTokens` be `null` too — never fabricate a number to satisfy the schema. Also record `terminalReason`/`numTurns`/`isError`/`subtype` straight from the CLI result, `stopReason` only if a semantic entry actually declared one (`null` otherwise — do not put the CLI's own low-level `stop_reason`, e.g. `"tool_use"`, in this field; that goes in `cliStopReason`), and `hooksFired` (whether `loop-log.sh`/`token-tally.sh` produced any output at all for this run).

Before moving on, validate the appended line against the schema — a quick stdlib check is enough, no external `jsonschema` package needed:
```bash
python3 -c "
import json
schema = json.load(open('.workflow/loop-entry.schema.json'))
run_summary_schema = next(s for s in schema['oneOf'] if s['properties']['type'].get('const') == 'run_summary')
required = run_summary_schema['required']
allowed = set(run_summary_schema['properties'].keys())
with open('.workflow/logs/run-\$LOOP_RUN_ID/loop.jsonl') as f:
    lines = [json.loads(l) for l in f if l.strip()]
row = next(r for r in reversed(lines) if r.get('type') == 'run_summary')
missing = [k for k in required if k not in row]
extra = set(row.keys()) - allowed
assert not missing, f'missing required fields: {missing}'
assert not extra, f'fields not in schema (typo, or a new ad-hoc name that needs adding to the schema instead): {extra}'
print('run_summary line matches schema')
"
```
If this fails because you invented a field name the schema doesn't have, that's a sign to add it to `loop-entry.schema.json` in Step 6 (proposal-only, see below) rather than just letting the drift continue silently — this exact drift (three different names for the same cost figure across three separate runs) is what made the schema unusable for anything downstream until now.

**`cliTotalCostUsd` (the `--output-format json` result's own `total_cost_usd`) is authoritative — quote that to the user, always, whenever it's available.** Only fall back to estimating `totalCostUsd` yourself when no CLI cost figure exists at all (e.g. a `--bg` run, or a hook-only trace with no final JSON result).

If you must estimate: **do not use one flat blended rate** — `totalTokens * 0.000003` was tried in practice and came out 4.6× too high ($3.44 estimated vs $0.74 actual CLI-reported cost) on a `/goal` loop run, because the loop is inherently cache-read-heavy (94% of that run's tokens were `cache_read_input_tokens`, which price at roughly a tenth of a normal input token) and a single blended rate assumes a much more even input/output/cache mix than these loops actually have. Instead, weight `cache_read_input_tokens` far lower than `input_tokens`/`output_tokens`/`cache_creation_input_tokens` in whatever rough formula you use, and label the result clearly as a rough estimate, not a real figure. `totalCostUsd` (whether estimated or absent) is `null` whenever `totalTokens` is `null` — don't estimate from a number that isn't there.

Finally, append this run's row to `~/.claude/auto-man/ledger.jsonl` (see Step 6 — this is the mechanical, no-approval-needed part of closing the loop, and it's the only place this run's data survives past the isolated workspace being deleted).

## Step 6 — Close the loop

**First, execute the delivery path you decided in Step 1** (cherry-pick, merge, PR, or copy files back) — a passing `verify.sh` in the isolated workspace is proof the fix works, not proof the user has it. Don't leave the result stranded on an unmerged worktree branch; if the delivery step genuinely needs the user's review before landing (e.g. a PR), say so explicitly in your report rather than silently treating "verify.sh passed in the worktree" as equivalent to "done."

For a multi-phase plan, everything in this step happens once per phase, not once for the whole plan — including the delivery above and the gate-cadence check before starting the next phase's work; see "Multi-phase plans" above.

Two different kinds of output come out of this step, with two different automation levels — never conflate them. This split exists because this skill is distributed via a marketplace plugin: an auto-committed prose/template change would reach every future installer without review, whereas a structured data row in your own local ledger carries no such risk.

**Mechanical — do this automatically, every run, no approval needed:**
1. Append a row to `~/.claude/auto-man/ledger.jsonl` (first run on this machine: create it, and copy `${CLAUDE_SKILL_DIR}/templates/ledger.schema.json` to `~/.claude/auto-man/ledger.schema.json` alongside it). Fields: `date`, `project`, `phase` (the phase name for a multi-phase plan, `null` otherwise — see "Multi-phase plans" above), `taskShape` (`filesTouched`, `diffLoc`, `hasTestInfra`), `supervisedTurns`, `maxTurnsSet`, `turnsUsed`, `terminalReason`, `allPassVerifiedByOrchestrator` (did *you* rerun verify.sh, or only cite a prior evidence.json), `hooksFired`, `costUsd` (+ its token breakdown), `criteriaShapes` (counts of grep/exit-code/file-exists-style checks), `outcome` — whose enum **must** include `success_undeclared` (verify.sh passed but the session never got to declare it, e.g. hit `max_turns` first) as a distinct value from plain `failure`, or a run exactly like that gets misfiled as a failure and skews every future decision that reads this ledger. Validate the row against the schema before writing — a malformed entry is worse than no entry, since Step 4's `MAX_TURNS` derivation and Step 7's retro both depend on this file staying parseable.
2. If you are about to modify anything under `templates/` or `recipes/` in this step, run `${CLAUDE_SKILL_DIR}/selftest.sh` first and make sure it still passes with your change applied — it exists specifically to catch template/recipe bugs (malformed artifact paths, missing recipe sections, a schema no real data actually matches) before they ship to the next install.
3. Run `.workflow/arch-delta.sh` and append its output as a row to `~/.claude/auto-man/arch-delta.jsonl` (first run on this machine: create it, and copy `${CLAUDE_SKILL_DIR}/templates/arch-delta.schema.json` alongside it), adding `date`, `project`, `runRef` (this run's `LOOP_RUN_ID` or the commit you delivered), and `reviewedAt: null` (`arch-delta.sh`'s own output already carries `phase`, filled from the `PHASE_NAME` you set at this phase's start, or `null` for a single-phase run) — **never** write a non-null `reviewedAt` here, only Step 8 may do that, and only after a human has actually looked. This is a separate file from the ledger on purpose: the ledger is quantitative telemetry sized for `MAX_TURNS` derivation, this one is qualitative "what shape changed" sized for the human batch review in Step 8 — don't merge them into one file just because they're both per-run.
   - **If `humanReviewRequested` is true, that changes this run's report below**: the user asked for this one, so hand them what they need to actually do it — the branch/commit to look at, the files touched, and the delivery state — rather than a summary that stands in for the diff. Don't let it silently join the Step 8 batch queue; they already told you at Step 0 they wanted to see it.

**Proposal-only — never auto-commit:**
1. Draft the actual `templates/`/`recipes/`/`SKILL.md` diff for anything from `.workflow/lessons.md` that's genuinely generalizable, using the same three-tier test used throughout this skill: **useful to other domains too? → `templates/`. useful only within this task's domain? → `recipes/<domain>.md`. useful only to this one project? → it already lives in the project's own `CLAUDE.md`, nothing to fold back.**
2. Tag every folded-back line with its provenance so it can be reviewed or retired later: `<!-- lesson: <date> run-<id> <project> · last-verified <date> -->` immediately above the added prose (or a trailing inline comment for a one-line shell/config change). Undated, unattributed prose is exactly what made the current templates/recipes impossible to audit or expire.
3. Before proposing something that **contradicts** an existing line in `templates/`/`recipes/`, resolve it — correct or remove the stale claim — rather than appending a second, conflicting statement next to it. Two rounds of "confirmed still valid" / "actually this changed" living side by side is a bug, not documentation.
4. Present the diff to the user and only write it into the skill's **source repo** after they approve (see "Where this skill lives" above — never the cache). If you cannot identify a source repo, stop and hand over the proposal text instead of writing anything.

Report to the user: what passed, what got fixed along the way, the actual evidence (`evidence.json` + the judge subagent's structured verdict, if this task used one) — not a narrative summary standing in for it — and the run's cost: quote `run_summary`'s `totalTokens` (`mainSessionTokens + subagentTokensSum`) and either the accurate `total_cost_usd` from the `--output-format json` result or, if unavailable, the rough `totalCostUsd` estimate (labeled as an estimate). Don't drop the subagent portion — it's the part `/goal`'s own numbers miss. Also state `arch-delta.sh`'s shape summary plainly (files touched, diff size, new/deleted files) and which review path this run took — "you asked to review this one, here's what to look at" or "no review requested — queued for the next Step 8 batch". Say it either way; "nothing to report" is itself the report when the user opted out.

## Step 7 — Retro (optional, standalone entry point)

Run this on its own — not tied to any specific delivery task — when the user asks something like "what have we learned from auto-man runs" or "improve the skill from experience," as opposed to Step 6, which only folds back lessons from *this* run.

1. Read `~/.claude/auto-man/ledger.jsonl` in full, plus every `.workflow/lessons.md` you can still find on disk (check any isolated workspaces/worktrees the user still has lying around — they're the only place a lesson's full narrative survives; the ledger only has the structured summary, by design, since it's meant to stay small and mechanically parseable).
2. Compute retention: for each lesson that claimed "universally generalizable" or "domain-generalizable" in some `lessons.md`, grep whether it actually landed in the current `templates/`/`recipes/` in the source repo — report the ratio. A low ratio is itself a finding worth surfacing, not just a means to an end.
3. Run `${CLAUDE_SKILL_DIR}/selftest.sh` to catch any template/recipe bug that's shipping right now, independent of any specific lesson.
4. For any provenance-tagged line whose `last-verified` date is more than ~90 days old (or whatever staleness window the user prefers), re-check that the file/command/flag/behavior it names still exists/holds before treating it as still valid in your proposal — if it doesn't, propose removing or correcting that line instead of leaving it. `templates/lessons.md.tmpl`'s own warning ("this file rots") applies just as much to what's already landed in `templates/`/`recipes/`, not only to the per-project copy.
5. Produce one consolidated proposal (diff form) covering everything found — same proposal-only rule as Step 6: present it, don't commit without the user's review.

## Step 8 — Architecture batch review (optional, standalone entry point)

Run this on its own — not tied to any specific delivery task — when the user asks something like "batch review what auto-man has delivered" or "what's changed shape since I last looked," as opposed to Step 6, which only reports *this run's* delta.

**Why this step exists.** Per-run diff review doesn't scale with the number of runs — if the owner reads every diff, delivery speed is capped by review speed, which defeats the point of delegating to auto-man. But the fix isn't "stop reviewing" either — an owner who never looks loses real architectural control, and that loss is difficult to reverse once it's happened. The lever that scales is reviewing *shape changes*, compressed across many runs, in batch — O(subsystems that changed) instead of O(diffs produced). Concretely, that's what this step trades against Step 6's per-run report: Step 6 tells you about one run in detail right after it happens; Step 8 tells you about many runs at once, compressed to what's worth your attention.

1. Read `~/.claude/auto-man/arch-delta.jsonl` in full. Partition rows into `reviewedAt: null` (pending) vs already-reviewed — only the pending set is this batch's job.
2. Group the pending rows by `project` (sub-grouping by `phase` when a project has several — a multi-phase plan's rows should read as one plan's phases, not as unrelated runs), then split each group into two buckets purely on `humanReviewRequested` — the user's own Step 0 answer is the only routing signal here, there is no secondary heuristic:
   - **Needs your eyes**: `humanReviewRequested: true`.
   - **Delivered clean**: `humanReviewRequested: false`.
3. For "needs your eyes," present per row: `project`, `phase` (if set), `runRef` (so the user can pull the full diff on demand), `filesTouched`/`diffLoc`, new/deleted files. Do not paste the diff itself here — that would just be Step 6's report repeated N times, which is exactly the O(diffs) cost this step exists to avoid.
4. For "delivered clean," present only a rollup per project (e.g. "12 runs, 340 files touched") — a count to skim, not a list to read line by line. That rollup being small and boring is the mechanical layer doing its job, not a gap in this review.
5. Ask the user which rows they've actually looked at — accepting a "delivered clean" rollup as reviewed without opening each row is a legitimate choice at this layer, not a shortcut being smuggled past them. Only set `reviewedAt` (to today's date) on rows the user explicitly confirmed; never advance it yourself. An unreviewed row silently marked reviewed defeats the entire point of this file — it would make the ledger claim oversight that never happened.
6. If a batch review turns up a run that clearly *should* have been reviewed but was answered "no" at Step 0, the lesson is about how Step 0 asked the question — not about adding a heuristic to catch it after the fact. Route it through the normal Step 6/7 proposal-only channel (e.g. sharpen what Step 0 prompts the user to consider).
