# 0011: Agent docs: one root AGENTS.md, nested AGENTS.md per subtree, enforced by a test

- **Status:** Accepted
- **Date:** 2026-11-07
- **Links:** Beads `ds-nhh.8` and children `ds-nhh.8.1`-`ds-nhh.8.3`; PR #43 (single source), PR #51 (nested
  check), PR #53 (compress, nest), PR #55 (drop duplicate Claude block); `scripts/ci/test-agent-docs.sh`;
  `AGENTS.md`; `traefik-rules/AGENTS.md`; `dolt/AGENTS.md`

## Context

Several coding agents work on this repo. PR #43 (2026-11-01) made `AGENTS.md` the single source of instructions:
`CLAUDE.md` imports it with `@AGENTS.md`, `GEMINI.md` is a symlink to it, Cursor reads it natively. By 2026-11-07 it
was 16189 bytes against a 16384-byte check (`ds-nhh.8`), and the planned homelab-as-code work would add more.

## Decision

1. **Root `AGENTS.md` holds rules that can be broken from anywhere**: hard rules, repo map, validation matrix,
   one-line invariants, Beads usage. Test for keeping a rule at root (`ds-nhh.8`): it can be violated by editing a
   file outside a single subtree.
2. **Nested `AGENTS.md` for subtree detail** (`traefik-rules/`, `dolt/`). Each directory also has a `CLAUDE.md`
   containing `@AGENTS.md` (`ds-nhh.8` records that Claude Code reads `CLAUDE.md`, not `AGENTS.md`) and a `GEMINI.md`
   symlink to its `AGENTS.md`. Paths in nested docs are repo-root-relative.
3. **Explanations go to the human docs** (`README.md`, `REBUILD.md`, `docs/`), with a link back.
4. **Size is tested**, not remembered. `scripts/ci/test-agent-docs.sh` (run by `lint.yml`) caps root `AGENTS.md` at
   16 KiB, caps each `CLAUDE.md` at 2 KiB, checks the pointer files, checks that every backticked repo path in the
   docs is tracked, and caps root plus ancestors plus the nested file at 28 KiB.
5. **The 28 KiB chain cap** leaves margin under Codex's default `project_doc_max_bytes` of 32 KiB, which
   `ds-nhh.8` describes as one budget across the root-to-directory chain with silent truncation. That description
   comes from third-party sources and a GitHub issue, and `ds-nhh.8` asked for it to be checked against Codex's
   source; this ADR does not record that check. Do not raise the limit in a Codex config.
6. **Claude Beads block removed** (PR #55): Claude gets `bd prime` from a SessionStart hook in
   `.claude/settings.json`. The Codex block stays.

## Alternatives considered

- **Trim the one file once.** `ds-nhh.8`: that only buys time; the planned additions would not fit.
- **`CLAUDE.md` as the source** (the layout before PR #43), with other tools pointed at it. Replaced by PR #43 so
  one file serves every tool.
- **Raise the Codex limit in `.codex/config.toml`.** Rejected: other users' Codex configs would still truncate, and
  it costs context every session (`ds-nhh.8`).

## Consequences

- Rules for a subtree load only when an agent works there (for Claude Code, per `ds-nhh.8`: on demand). Cursor's
  nested behaviour was to be verified; this ADR does not record the result.
- Every new nested `AGENTS.md` needs the `CLAUDE.md` and `GEMINI.md` siblings, or the test fails.
