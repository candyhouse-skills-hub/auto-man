# Auto Man

A zero-human-intervention delivery loop for tasks with machine-checkable success criteria — instantiate deterministic verification, guardrail hooks, and a `/goal` stop condition into an isolated workspace, run a supervised first pass, then hand off to run unattended until it succeeds, hits a safety limit, stalls, or needs you.

## Overview

`auto-man` exists for one reason: to take "did this actually finish?" out of an LLM's self-report and turn it into something a script can answer with an exit code. You set up the scaffold once, watch it prove itself on a supervised pass, then let it run hands-off.

## Key Features

- **Objective verification, not self-report.** `verify.sh`'s exit code and `evidence.json` are the only accepted proof of "done." Anything needing semantic or visual judgment goes to an independent judge subagent — never the model that did the work.
- **Four independent stop conditions**, written verbatim into the `/goal` text — success, safety (turn limit), no-progress, blocked — so the loop can't wander forever or quietly claim success.
- **Isolated and guardrailed.** The unattended run happens in a discardable workspace (a git worktree by default; fallbacks for greenfield/non-git/multi-repo) — never your working tree — and a PreToolUse hook blocks destructive commands (`git push`, `rm -rf`, …) even mid-run.
- **Domain-aware, not domain-locked.** A growing library of recipes seeds verification checks and known pitfalls for a matching deliverable type (e.g. Capacitor mobile launches) and stays invisible when nothing matches — none of it hardcoded into the core.
- **Engineered to stay cheap.** `/goal` re-reads the whole main transcript every turn, so whatever sits in it is paid for again each pass. auto-man keeps it lean: context-heavy work runs in throwaway subagents that return only a summary, large output goes to a file with just a count returned, and the judge runs once with a narrow brief instead of riding along. The bulky detail never gets re-charged into the loop.
- **An honest cost number at the end.** Every run reports `totalTokens = mainSessionTokens + subagentTokensSum` plus a rough USD estimate — subagent spend tallied mechanically by a hook, not taken from `/goal`'s self-report (which leaves it out), so it's the real total, not an undercount.
- **Plan-first.** It always executes from a confirmed, detailed plan — give a one-line task and it drafts one and checks with you before touching anything.

## Prerequisites

- [Claude Code](https://claude.ai/code) CLI, desktop app, or IDE extension.
- A model/account tier that supports `auto` permission mode (recommended) — otherwise falls back to `acceptEdits`, at the cost of more manual prompts.
- A location to isolate into: an existing git repo (most common), or any other starting point described in the skill's Step 1.

## Installation

```
/plugin marketplace add <this repository's path or git URL>
/plugin install auto-man@<marketplace name>
```

## Quick Start

1. **Use `auto` (or `acceptEdits`) permission mode** — default mode prompts on every tool call, defeating the point. Launch with `claude --permission-mode auto`, or switch mid-session.
2. **Invoke the skill** with a target location and a task — a detailed plan (acceptance criteria, scope, exemptions) is ideal; a one-line description also works and gets turned into a confirmed plan first.
3. **Watch the supervised first pass** until `verify.sh` reports `allPass: true`.
4. **Approve the hands-off run.** The skill proposes a turn limit from the supervised pass and asks you for a budget cap, then runs `/goal` unattended until a stop signal fires.
5. **Get the real evidence back** — `evidence.json`, any judge verdict, and the honest token/cost total — not a narrative.

## Learn More

- [`skills/auto-man/SKILL.md`](./skills/auto-man/SKILL.md) — the full step-by-step: establish the plan → isolate → instantiate (matching a recipe if one applies) → supervised pass → hands-off run → verify the hooks fired → fold lessons back in.
- [`skills/auto-man/recipes/README.md`](./skills/auto-man/recipes/README.md) — the domain-recipe layer, and how to add one.
