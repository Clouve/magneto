# Gibbon DevOps — Session Learnings

This file is the catch-all for facts about *this* Gibbon install (the Clouve `apps/gibbon` package) that emerge from real sessions and are too small, too cross-cutting, or too speculative to live in a dedicated [reference/](reference/) or [playbooks/](playbooks/) file. It is part of the skill — Claude Code reads it whenever the Gibbon DevOps skill is loaded.

The protocol that drives appends here is in [SKILL.md](SKILL.md) under "Maintaining this skill". The summary below is just the format guide.

## What goes here

Append an entry when you discover any of the following:

- **Non-obvious behaviour** that surprised you and could bite the next session if it surprised you again.
- **Version-specific facts** about gibbon v30.x that upstream docs do not surface clearly.
- **Environment quirks** of the Clouve packaging — Docker compose vs. Kubernetes differences, [update-config.sh](../image/installer/update-config.sh) edge cases, MySQL 8.0 default-charset interactions, the gibbon-cron wrapper, the SSH-as-`clouve-ops` channel.
- **Workflow patterns** the user has confirmed at least twice — the verified shape of a recurring response.
- **Corrections** to anything elsewhere in the skill — fix the original file *in place*, then drop a one-line stub here pointing at the change so future sessions notice the update.

## What does NOT go here

- Generic PHP / Apache / MySQL / Linux knowledge — training-data territory, not skill content.
- Anything tied to a `/_clv/` path — that namespace is the Clouve platform's, not Gibbon's.
- Anything that belongs in a global Claude Code skill (e.g., "how to use grep", "how memory works") — not Gibbon-specific.
- Per-session ephemera — what you tried and rolled back, the contents of one bug report, the user's preferred name for their database. That belongs in conversation context or the memory system, not here.
- Secrets. Ever. (Including the literal value of `${CLOUVE_OPS_PASSWORD}`, the tenant's `ANTHROPIC_API_KEY`, or any DB password.)

## Entry format

Use one fenced section per entry, in the shape below. Keep it terse — one paragraph, max ~10 lines. If an entry needs more, promote it to its own file under `reference/` or `playbooks/` and replace the entry here with a one-line pointer.

```
### YYYY-MM-DD — short title (≤ 60 chars)

**Category:** gotcha | version-note | env-quirk | workflow-pattern | correction
**Origin:** one-sentence trigger (what task surfaced this).

Body — the fact itself. If it overrules something elsewhere in the skill,
link to that file with a relative path. If a future reader could re-derive
this from the code in two minutes, it does not belong here.
```

## Edit rules (mirror of SKILL.md "Maintaining this skill")

1. **Prefer the right file over this one.** Reference facts go in `reference/*.md`. New verified procedures go in `playbooks/*.md`. New audited automation goes under `scripts/`. Use `learnings.md` only when the fact is too small, too cross-cutting, or too speculative for a permanent home.
2. **De-duplicate before appending.** Grep this file for the topic first. If a related entry exists, extend it; do not create a parallel entry.
3. **Keep entries terse and dated.** ISO-8601 (`YYYY-MM-DD`), one paragraph.
4. **Promote entries that grow.** If an entry crosses ~10 lines or earns repeated reference, move it to its own file under `reference/` or `playbooks/` and leave a one-line pointer here.
5. **Drop superseded entries.** Once a learning is reflected in a dedicated reference file, delete the entry here — git history retains the original capture.

## Entries

_(none yet — append as you learn)_
