# ADR-0002: Guide examples are whole project.yaml files

**Decision:** Every ```` ```yaml ```` block in `docs/project-yaml.md` MUST be a complete `project.yaml` that passes the schema; a deliberately wrong example MUST use another fence, such as ```` ```text ````.

**Reason:** Fragments, each tagged with the schema path they sit under, were weighed and lost. They need a tagging scheme and checker code to validate a part of a file against a part of the schema. Whole files need neither, the skeleton is about ten lines, and an author or agent can copy any example and know it passes.

**Consequence:** A guide section shows its field inside a full skeleton, not alone. The check validates every `yaml` block as a file, so a fragment fails CI. The guide's examples can't drift from the schema without the required check failing.

**Scope:** `docs/project-yaml.md`, `scripts/check_project_yaml.py`

**Date:** 2026-10-14
