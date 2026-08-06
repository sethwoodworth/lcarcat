# AGENTS.md — working rules for agents on lcarcat

**New to this repo?** Read `docs/codebase-overview.md` first — repo layout, subsystem map, and navigation to all specialist docs.

---

## Task routing

Load only the docs relevant to your task:

| Working on… | Read first |
|-------------|-----------|
| zsh LCARS prompt | `docs/zsh-prompt.md`, `docs/asset-pipeline.md` |
| kitty config or image rendering | `docs/kitty-graphics.md`, `docs/asset-pipeline.md` |
| nvim chrome (elbows, caps, frame) | `docs/nvim-chrome.md`, `docs/asset-pipeline.md` |
| colors or palette | `docs/palette.md` |
| screenshot tests or evaluating rendering | `docs/testing.md` |
| evaluating nvim gutter color | `docs/testing.md` — run `test/scenarios/nvim_eob_gutter.sh` |
| deploy or file mappings | `docs/deployment.md` |
| design or layout decisions | `docs/lcars-design.md` |
| any text output, glyphs, or symbols (shell scripts, hooks, prompts) | `docs/lcars-design.md` (glyph kit) |

---

## Invariants

**Minimum viable image.** PNGs only where a shape curves — the elbow corner and right round cap. Everything else is background-colored terminal cells. Ask "can this be a background cell?" first.

**Image sizing.** PNG pixel dimensions must equal `cols × cellw` by `rows × cellh` exactly, where `cellw`/`cellh` come from kitty's CSI 16t reply. Any mismatch causes a sub-cell aspect-fit inset. → `docs/kitty-graphics.md`, `docs/asset-pipeline.md`

**Glyphs and style.**
- No icon-font glyphs. Avoid `✘ ✓ ⚠ ⏱ →`.
- No T/+ junctions. Bars meet stems via 2-sided elbows; free ends get caps.
- Spell words out in full — no abbreviations without asking (`MODIFIED` not `MOD`).
- Chips use `NN-WORD` dashed form (e.g. `03-STAGED`); labels uppercase; Long-Now numbers.

→ `docs/lcars-design.md` for structural rules and glyph kit.

**Deployment.** Run `./deploy.sh` after every edit (`--dry-run` to preview). Changes must land in the repo and the deployed `~/.config` copy. → `docs/deployment.md`

---

## Agent session behavior

- **Track conversational decisions in beads as they happen.** When the user clarifies requirements, makes a design choice, or rules something out, add it to the relevant bead's `--notes` or `--design` field immediately.
- **Claim beads before starting work.** Run `bd update <id> --claim`.
- **Close beads only after the user validates the change**, not just after deploying.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
