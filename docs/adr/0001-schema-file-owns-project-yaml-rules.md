# ADR-0001: The schema file owns what project.yaml may contain

**Decision:** Every rule about what `project.yaml` may contain MUST live in `schema/project.schema.yaml`; `scripts/check_project_yaml.py` MUST NOT add rules of its own and only loads files, runs the schema and words its errors.

**Reason:** The alternative was writing the rules directly in Python. That splits "what is allowed" across code paths nobody reviews as a whole. A JSON Schema written in YAML is one file a reviewer can read top to bottom, the guide can point at, and editor autocomplete can use later.

**Consequence:** A change to what `project.yaml` supports edits the schema, and the guide in the same PR. A custom message in the checker is keyed on a schema error (its path and kind), never on a condition the schema doesn't express. A rule that exists only in the checker is a breach.

**Scope:** `schema/project.schema.yaml`, `scripts/check_project_yaml.py`

**Date:** 2026-10-14
