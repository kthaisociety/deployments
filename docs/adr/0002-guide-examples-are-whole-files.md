# ADR-0002: The guide has one checked reference example, and excerpts of it

**Decision:** `docs/project-yaml.md` MUST hold exactly one ```` ```yaml ```` block, a complete `project.yaml` that passes the schema and uses every key it allows; every other YAML example MUST be fenced ```` ```yaml excerpt ```` and be consecutive lines of that reference, compared without leading indentation.

**Reason:** Every example as a whole file made each section repeat the skeleton, and review asked for one reference covering every option, like an API spec. Unchecked excerpts were weighed and lost: they are the snippets people copy most, and nothing would stop them drifting. Fragments validated against the part of the schema they sit under lost again, as before, because they need a tagging scheme and checker code to validate part of a file against part of a schema. Matching lines against the reference needs neither.

**Consequence:** A new key in the schema fails the check until the reference uses it. An excerpt can only show what the reference already says, so changing an example means changing the reference. A deliberately wrong example uses another fence, such as ```` ```text ````.

**Scope:** `docs/project-yaml.md`, `scripts/check_project_yaml.py`

**Date:** 2026-10-15
