# ADR-0003: The schema rejects domain settings that have no effect or contradict

**Decision:** The schema MUST reject a domain setting that Dokploy would accept but ignore or contradict: `certificate_type` outside `letsencrypt`, `none` and `custom`; `port` outside 1 to 65535; `custom_cert_resolver` without `certificate_type: custom`, or `custom` without it; any certificate with `https: false`; `path` or `internal_path` not starting with `/`.

**Reason:** Checking types only, and leaving these to the plan or to Dokploy, was weighed and lost. A setting that silently does nothing is the failure the closed schema exists to stop, and the plan only runs after a reviewer approves it, so the mistake would surface late or not at all.

**Consequence:** The schema is stricter than `modules/project` for domains, as it already is for environments and per-environment secrets. A new domain setting in the module comes with its allowed values or its dependency on other settings in the schema. Naming conventions (secret names, volume paths) are not part of this and stay out of the schema.

**Scope:** `schema/project.schema.yaml`, the domain settings

**Date:** 2026-10-14
