# Recipes — domain layer

The auto-man skill uses three layers of knowledge:

1. **Universal** (`templates/`) — domain-agnostic. Ships as-is to every project.
2. **Domain** (this directory) — reusable within one class of deliverable (e.g. "mobile app via Capacitor"), not universal, not project-specific. A recipe here seeds `verify.sh` and `CLAUDE.md` when the target project matches its domain; it's invisible to projects that don't match.
3. **Project** (target project's own `CLAUDE.md` + `.workflow/lessons.md`) — filled at instantiation time, never flows back into the skill.

See `SKILL.md` Step 2 for how a recipe gets matched and applied, and Step 5/6 for how a new lesson gets routed into the right layer.

## Available recipes

- `capacitor-ios-android-launch.md` — web app wrapped with Capacitor, launched on iOS/Android simulators/emulators.

## Adding a new recipe

Each recipe is a single markdown file with these four sections:

```markdown
# <domain name>

## Applies to

One or two sentences describing what kind of project/task this matches.

## Verify snippets (adapt before use)

Concrete `verify.sh` check patterns for this domain — the deterministic
signals worth checking and the shell commands that check them.

## Known pitfalls

Bugs/gotchas specific to this domain's tools, discovered on real runs, with
root cause and fix — not just a workaround.

## CLAUDE.md conventions to append

Domain-specific non-interactive flags, startup-check commands, and other
conventions that belong in the target project's `CLAUDE.md`.
```

Only add a recipe when a lesson is genuinely domain-generalizable — see the "Lessons" routing in `templates/CLAUDE.md.tmpl` and `templates/lessons.md.tmpl`.
