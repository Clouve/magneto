# Gibbon DevOps — Reference

Sourced from:
- [GibbonEdu/core](https://github.com/GibbonEdu/core) at tag `v30.0.01` (shallow-cloned during research; not vendored).
- [docs.gibbonedu.org](https://docs.gibbonedu.org) — admin, install, upgrade, developer sections.
- Clouve's own `apps/gibbon` image layer: [apps/gibbon/image/](../../image/).

Everything in this `reference/` folder is research — the operational rules the [SKILL.md](../SKILL.md) leans on. Each file is scoped narrowly so Claude Code loads only what a given task needs.

## File map

| File | What's in it |
|---|---|
| [stack-and-runtime.md](stack-and-runtime.md) | PHP / MySQL / Apache versions, required PHP extensions, `ini` settings Gibbon demands, filesystem layout |
| [install-and-bootstrap.md](install-and-bootstrap.md) | The container's first-boot flow, `auto.php` auto-installer, what `config.php` contains, the install sentinel |
| [upgrade.md](upgrade.md) | How Gibbon versions itself, the `CHANGEDB.php` migration file, the `;end` statement separator, `update.php` vs. our image's `upgrade.sh` |
| [modules.md](modules.md) | 27 core modules vs. third-party "Additional" modules, `manifest.php` required fields, install/uninstall/update semantics |
| [data-model.md](data-model.md) | 208-table schema — the never-touch list, the safe-to-touch list, key scope tables (`gibbonSetting`, `gibbonSchoolYear`, `gibbonModule`) |
| [backup-restore.md](backup-restore.md) | What a "complete" backup is for this app, volume layout, restore verification steps |
| [academic-year-rollover.md](academic-year-rollover.md) | Why rollover is the riskiest routine operation, the 3-step flow in `modules/User Admin/rollover.php`, the `max_input_vars` cliff |
| [security.md](security.md) | File permissions, installer lockdown, CSRF/nonce, 2FA, `Impersonate User` gate, known CVEs from the v30 release notes |
| [operations-and-signals.md](operations-and-signals.md) | What "healthy" looks like, where logs live, the in-container cron daemon + `gibbon-cron.sh` dispatcher |
| [troubleshooting.md](troubleshooting.md) | Failure modes seen in the wild (charset/collation mismatch, max_input_vars, config.php sed breakage, stale upload cache) and first-checks for each |

## Versioning

This reference targets Gibbon **v30.0.01** (the version shipped by the app today). Patch releases within v30.x may introduce minor differences but the table names, `CHANGEDB.php` format, cron CLI scripts, and rollover flow are stable. A Gibbon minor or major bump triggers a skill re-research pass — see the spec's §5 resolved-decision 6.
