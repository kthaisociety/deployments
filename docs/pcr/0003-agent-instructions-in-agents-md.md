# PCR-0003: Agent instructions live in AGENTS.md

**Decision:** Instructions for coding agents MUST be written in `AGENTS.md` at the repo root, and `CLAUDE.md` MUST contain only the line `@AGENTS.md`.

**Reason:** `AGENTS.md` alone was weighed and lost because Claude Code reads `CLAUDE.md`, not `AGENTS.md`. `CLAUDE.md` alone lost because other agents read `AGENTS.md`. Keeping the text in one file and importing it from the other means every agent gets the same rules and nobody edits two copies.

**Consequence:** A new agent rule goes in `AGENTS.md`. Text added to `CLAUDE.md` beyond the import reaches only Claude and is a breach.

**Date:** 2026-10-14
