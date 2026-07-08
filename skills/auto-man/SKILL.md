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

## Step 0 — Establish the plan you work from

The hands-off phase (Step 4) runs unattended across many turns in `auto` mode — the single biggest lever against it drifting is a precise spec fixed *before* it starts. So the input you actually execute from is always a detailed plan: the task, its machine-checkable acceptance criteria, the scope boundaries, and any known-unfixable exemptions. Everything Step 2 fills into `verify.sh` and `goal-condition.txt` comes from here.

- **If the user handed you a detailed plan**, use it — just confirm it actually carries concrete, machine-checkable criteria (see Preconditions), and fill any gaps by asking.
- **If the input is thin** (a one-line description, a vague ask), your first job is to *elevate* it into that plan yourself — draft the criteria/scope/exemptions and get the user to confirm them — before you isolate anything or copy a single template. A one-liner is an accepted starting point, not an accepted spec to run autonomously on.

Do not move on to Step 1 until the plan is confirmed. This is not the same as requiring the user to write a plan — it's requiring one to *exist and be agreed* before the unattended loop starts.

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
```

Append `${CLAUDE_SKILL_DIR}/templates/CLAUDE.md.tmpl`'s content to the workspace's `CLAUDE.md` (create it if absent).

**Domain match (do this before filling placeholders):** `ls ${CLAUDE_SKILL_DIR}/recipes/` and read each recipe's "Applies to" section. If one genuinely matches this task's domain, seed `.workflow/verify.sh`'s checks from its "Verify snippets" section and append its "CLAUDE.md conventions to append" section into `CLAUDE.md`. When it's not a clear match, don't force it — fall back to writing checks from first principles below. Getting this wrong costs nothing (worst case: you write the checks yourself instead of adapting a recipe's).

Fill every `{{PLACEHOLDER}}` in `.workflow/verify.sh` (project-specific pass/fail checks — this is the part that can't be templated, it's the actual acceptance logic), `.workflow/goal-condition.txt` (success/safety/no-progress/blocked clauses — all four are mandatory, not just success; only fill `{{JUDGE_CLAUSE}}` if some criterion genuinely needs semantic/visual judgment, see the template's own comments), and `CLAUDE.md`'s scope statement. Use the task description the user gave you to derive these; ask a clarifying question if the criteria are genuinely ambiguous rather than guessing.

**Writing `verify.sh` checks from first principles (no matching recipe):** every criterion needs a command-level deterministic signal — an exit code, a file's existence, a count of matching lines in a properly-scoped log. Wrap anything that talks to a flaky external daemon in the provided `retry()` helper. Never put LLM judgment inside `verify.sh` itself — that's the judge subagent's job (see the `{{JUDGE_CLAUSE}}` note above), and only when the task actually needs it.

Seed `.workflow/state.json` from `state.schema.json` with `iteration: 0` and the acceptance criteria names in `criteriaPending`.

## Step 3 — Supervised first pass (no `/goal`)

Work the task normally in this same session, in plain language, checking in at natural milestones (the ones you and the user agree matter — don't invent extra pauses). Without `/goal` active, you already stop and wait for the next message after each turn — that pause *is* the checkpoint, no extra mechanism needed.

Every time something breaks in a way that needed a manual fix: record it in `.workflow/lessons.md` immediately, and route the fix appropriately — project-specific to this project's `CLAUDE.md`, domain-generalizable to a note for a `${CLAUDE_SKILL_DIR}/recipes/<domain>.md` addition, universally generalizable to a note for a `${CLAUDE_SKILL_DIR}/templates/` change (see Step 6 for the actual edit). Don't defer this to "later," do it the moment you find it.

Before declaring the first pass done, run `.workflow/verify.sh` yourself and confirm `allPass: true` in the resulting `evidence.json`. Do not declare success on your own narrative — only on that file's contents.

## Step 4 — Hands-off validation

Only after step 3 is clean, test whether the loop can run with zero intervention. Do this **in a separate nested session**, not by continuing to drive it yourself — hooks (`guard.sh`/`token-tally.sh`/`loop-log.sh`) only fire for tool calls made by a live `claude` process running with the isolated workspace as cwd; driving it from outside via a different tool does not exercise them.

**Determine `MAX_TURNS` first — from real data, not a guess.** Step 3 just ran; you know how many turns/iterations the supervised pass actually took to reach a clean state. Set `MAX_TURNS ≈ that count × 2.5–3`. Don't reuse a number from a different project's run — turn counts aren't portable across tasks.

**Determine `BUDGET_USD` — this is the user's call, not yours to guess.** Check in this priority order:
1. Did the user's task description or plan (if one exists) explicitly state a budget? Use it.
2. If not, **ask the user directly** before running anything: "this hands-off run needs a hard dollar cap — what's your limit?" If prior runs on this same project have a `total_cost_usd` in `loop.jsonl`, mention it as context ("a similar run cost about $X last time"), but don't pick the number for them.
3. Never silently default to a made-up constant. If the user says "you decide," say so explicitly in your report afterward — that's still a real decision being made, just delegated, and it should be visible as one rather than presented as if it were principled.

```bash
cd <isolated workspace>
export LOOP_RUN_ID="run-$(date +%Y%m%d-%H%M%S)"
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
```

If `subagent_tokens.count` is missing despite subagents having run, or the JSON output's `usage` fields don't reconcile with what the session claimed, that's a real bug in the hook chain, not a fluke — debug it the same way this skill's own templates were debugged: temporarily tee the hook's raw stdin to a file and inspect the actual payload shape rather than assuming.

Append an honest `run_summary` entry to `loop.jsonl`: `mainSessionTokens` from the `--output-format json` result's `usage` fields (sum of `input_tokens` + `output_tokens` + `cache_creation_input_tokens` + `cache_read_input_tokens`), `subagentTokensSum` from summing `subagent_tokens.count`, `totalTokens` as their sum. If either is genuinely unavailable, write `null` for it and let `totalTokens` be `null` too — never fabricate a number to satisfy the schema.

Also write `totalCostUsd` — a deliberately rough estimate, `totalTokens * 0.000003` ($3/million tokens, one blended rate, not split by input/output/cache tier). This is for an at-a-glance sanity check ("does this look like the right order of magnitude"), not a real cost figure — when `--output-format json` was used, its `total_cost_usd` is the accurate number and should be quoted to the user directly instead of this estimate. `totalCostUsd` is `null` whenever `totalTokens` is `null`, for the same reason: don't estimate from a number that isn't there.

## Step 6 — Close the loop

Fold every lesson from `.workflow/lessons.md` that's genuinely generalizable into the skill package right now, not as a deferred TODO. Route by the same three-tier test used throughout this skill: **useful to other domains too? → `templates/`. useful only within this task's domain? → `recipes/<domain>.md`. useful only to this one project? → it already lives in the project's own `CLAUDE.md`, nothing to fold back.**

Report to the user: what passed, what got fixed along the way, the actual evidence (`evidence.json` + the judge subagent's structured verdict, if this task used one) — not a narrative summary standing in for it — and the run's cost: quote `run_summary`'s `totalTokens` (`mainSessionTokens + subagentTokensSum`) and either the accurate `total_cost_usd` from the `--output-format json` result or, if unavailable, the rough `totalCostUsd` estimate (labeled as an estimate). Don't drop the subagent portion — it's the part `/goal`'s own numbers miss.
