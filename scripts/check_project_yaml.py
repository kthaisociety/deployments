"""Checks every project.yaml, every guide example and the template against schema/project.schema.yaml.

The schema is the one list of what project.yaml may contain: closed at every level, so an unknown key
fails. It is stricter than modules/project, which still accepts per-environment secrets, shared secrets,
volumes and other environment names.
"""

import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Problem:
    """One thing wrong in one file.

    file: the file's path relative to the checked root, with forward slashes
      (projects/<project>/project.yaml, templates/project.yaml or docs/project-yaml.md).
    line: the 1-based line in that file. For a guide example, the line in the markdown, not in the
      block. For a missing key, the line of the map it's missing from; 1 for a missing top-level key
      or an empty file. None only when there is no line.
    path: the YAML path, yq style: .environments.staging.domains["app.kthais.com"].port, with
      brackets only for keys that aren't plain words. For a missing key, the path the key should
      have. None for a file that isn't valid YAML.
    message: what's wrong and what's allowed there, readable without the schema.
    """

    file: str
    line: int | None
    path: str | None
    message: str


def check(root: Path) -> list[Problem]:
    """Validate every file the check covers under root, and return every problem in it.

    Covers projects/*/project.yaml, templates/project.yaml and every ```yaml block in
    docs/project-yaml.md (each one a complete project.yaml; other fences aren't checked). Always
    validates against this repo's schema/project.schema.yaml, wherever root is.

    Guarantees:
    - Never raises on bad input: every fault is a Problem. An empty list means everything passes.
    - Reports every problem in every file in one call. A file that isn't valid YAML (including a
      duplicate key) gives one Problem with the parser's line and reason, and the other files are
      still checked.
    - One Problem per offending key.
    - A missing guide or template is a Problem, and so is an empty template.
    - An unknown key's message lists the keys allowed at its path.
    - domains under defaults says it belongs under an environment.
    - secrets, shared or volumes under an environment says to declare the names under defaults
      and set per-environment values in OpenBao.
    - A missing or null skeleton key (repo; defaults with env, secrets, shared and volumes;
      environments with staging and production) is named, and a null one says to write {} or [].
    - An environment other than staging or production names the two allowed.
    - A wrong type names the expected type. env values may be strings, numbers or booleans.
    - A domain needs port, an integer from 1 to 65535. certificate_type is letsencrypt, none or
      custom (the message lists them). custom_cert_resolver is required with certificate_type
      custom and rejected otherwise. https: false allows only certificate_type none. path and
      internal_path start with /.
    """
    raise NotImplementedError


def main(argv: list[str]) -> int:
    """scripts/check-project-yaml [root]: print every problem under root (default: the repo root).

    One line per problem, then a count line such as "3 problems in 2 files". With
    GITHUB_ACTIONS=true each problem is a workflow command,
    ::error file=<file>,line=<line>::<path>: <message>, so it shows as a PR annotation; otherwise
    <file>:<line>: <path>: <message>. Returns the exit code: 0 with no problems, 1 otherwise.
    """
    raise NotImplementedError


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
