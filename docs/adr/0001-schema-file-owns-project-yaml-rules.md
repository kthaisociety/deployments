# ADR-0001: The schema file owns what project.yaml may contain

**Decision:** Every rule about what `project.yaml` may contain that JSON Schema can express MUST live in `docs/project.schema.yaml`; `scripts/check_project_yaml.py` MUST NOT add rules of its own beyond cross-field rules JSON Schema can't express, each documented in `check()`'s docstring and the guide.

**Reason:** The alternative was writing the rules directly in Python. That splits "what is allowed" across code paths nobody reviews as a whole. A JSON Schema written in YAML is one file a reviewer can read top to bottom, the guide can point at, and editor autocomplete can use later. Some rules compare values across fields, such as one name in two of `env`, `secrets` and `shared`, and JSON Schema has no way to say that, so those are the only rules the checker holds.

**Consequence:** A change to what `project.yaml` supports edits the schema, and the guide in the same PR. A custom message in the checker is keyed on a schema error (its path and kind), never on a condition the schema doesn't express. A rule in the checker that the schema could express, or one missing from `check()`'s docstring, is a breach.

**Scope:** `docs/project.schema.yaml`, `scripts/check_project_yaml.py`

**Date:** 2026-10-15
