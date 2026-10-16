# PCR-0001: Write repo tooling in Python

**Decision:** Scripts that check or process this repo's files MUST be written in Python, with their dependencies pinned in `requirements.txt`.

**Reason:** The first checker (`scripts/check_project_yaml.py`) needed real code to turn schema errors into readable messages, which inline bash and `yq` in a workflow step can't do well. Node with `ajv` and `yaml` was weighed and lost: Python is on the GitHub runner already, reads plainly for whoever maintains this infrastructure next, and `jsonschema` with `ruamel.yaml` covers the same ground, line numbers included.

**Consequence:** A new check or helper script goes in `scripts/` as Python and adds any library to `requirements.txt`. Short glue inside a workflow step can stay bash, as the existing `tofu.yml` steps are. A second language for tooling needs this record challenged first.

**Date:** 2026-10-14
