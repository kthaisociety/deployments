# ADR-0005: The schema is written by hand and tested against the module's domain settings

**Decision:** `docs/project.schema.yaml` MUST be written by hand, not generated from `terraform/modules/project`, and a test MUST fail when its domain settings differ from the module's allowed list in `variables.tf`.

**Reason:** Generating the schema from tofu was weighed and lost. The module types `config` as `any` and reads fields with `try()`, so it has nothing to generate from without retyping `config` as an `object({...})`. That change touches the module, and tofu drops unknown keys on the conversion, which would undo the module's own unknown-setting check. The domain settings list is the one place the module names its keys, and the first place the two would drift.

**Consequence:** A domain setting added to or removed from the module changes the schema in the same PR, or the test fails. Keys outside domain settings have no automated guard; the `AGENTS.md` instruction to update the schema and guide together is the only one.

**Scope:** `docs/project.schema.yaml`, `tests/`

**Date:** 2026-10-15
