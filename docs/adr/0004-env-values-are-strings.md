# ADR-0004: env values in project.yaml are strings

**Decision:** The schema MUST accept only strings without a newline as `env` values; a number or boolean MUST fail with a message saying to quote it.

**Reason:** The module writes each value as `NAME=value`, and YAML has already changed some values by then: `0755` becomes `755`, `1e3` becomes `1000`, and a multi-line string breaks the one-variable-per-line env. Allowing any scalar was weighed and lost. It saves typing quotes, but a leading zero is gone once the file is parsed, so no schema rule could catch it. Strings only means the file shows exactly what the app gets, the same rule Kubernetes has for `env`.

**Consequence:** Authors quote numbers and `true`/`false` in `env`. Loosening this to any scalar brings back silent changes the check can't see.

**Scope:** `docs/project.schema.yaml`, `env` under `defaults` and each environment

**Date:** 2026-10-15
