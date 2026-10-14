# PCR-0002: Test tooling with pytest under tests/

**Decision:** Tests for repo tooling MUST be pytest tests in `tests/` at the repo root, importing scripts through `pytest.ini`'s `pythonpath = scripts`.

**Reason:** Before this, the only tests were OpenTofu's `.tftest.hcl` files, which can't exercise a Python script. pytest was chosen over `unittest` because it is the runner most contributors already know and its fixtures and parametrized tests keep one-rule-per-test files short.

**Consequence:** Every Python script in `scripts/` gets its tests in `tests/`, run with `pytest` from the repo root. OpenTofu module tests stay in `terraform/modules/*/tests/` and are untouched by this.

**Date:** 2026-10-14
