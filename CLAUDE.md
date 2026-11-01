# CLAUDE.md

@AGENTS.md

## Claude Code only

- Persistent project notes go in Beads (`bd remember`), not Claude Code's auto-memory or a MEMORY.md file.
- The SessionStart hook in `.claude/settings.json` already runs `bd prime`; rerun it only if Beads context is stale.
- Shared hooks and permissions go in `.claude/settings.json`. Per-user permissions go in settings.local.json, which is
  gitignored: never commit it.
