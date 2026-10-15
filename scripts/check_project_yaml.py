"""Checks every project.yaml, the guide and the template against docs/project.schema.yaml.

The schema is the list of what project.yaml may contain: closed at every level, so an unknown key
fails. It is stricter than modules/project, which still accepts per-environment secrets, shared secrets,
volumes and other environment names. The one rule JSON Schema can't express, a name in two of env,
secrets and shared, lives here (ADR-0001).
"""

import ast
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from jsonschema import Draft202012Validator
from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap, CommentedSeq
from ruamel.yaml.error import MarkedYAMLError

REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = REPO_ROOT / "schema" / "project.schema.yaml"
TEMPLATE = "templates/project.yaml"
GUIDE = "docs/project-yaml.md"
PLAIN_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
TYPE_NAMES = {"array": "list", "object": "map"}
SECRET_KEYS = ("secrets", "shared", "volumes")


@dataclass(frozen=True)
class Problem:
    """One thing wrong in one file.

    file: the file's path relative to the checked root, with forward slashes
      (projects/<project>/project.yaml, docs/project.template.yaml or docs/project-yaml.md).
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


def _yq(steps) -> str:
    """The yq-style path for a list of keys and indexes, such as .defaults.env or .environments.staging.domains["a.b"]."""
    out = ""
    for step in steps:
        if isinstance(step, int):
            out += f"[{step}]"
        elif PLAIN_WORD.match(step):
            out += f".{step}"
        else:
            out += f"[{json.dumps(step)}]"
    return out or "."


def _line_at(doc, steps) -> int:
    """The 1-based line of the node at steps, or of the last key that exists on the way there."""
    line, node = 1, doc
    for step in steps:
        if isinstance(node, CommentedMap) and step in node:
            line = node.lc.key(step)[0] + 1
            node = node[step]
        elif isinstance(node, CommentedSeq) and isinstance(step, int) and step < len(node):
            line = node.lc.item(step)[0] + 1
            node = node[step]
        else:
            break
    return line


def _or_list(words) -> str:
    words = list(words)
    if len(words) == 1:
        return words[0]
    return f"{', '.join(words[:-1])} or {words[-1]}"


def _expected(types) -> str:
    names = [types] if isinstance(types, str) else types
    return _or_list(TYPE_NAMES.get(name, name) for name in names)


def _got(value) -> str:
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, str):
        return "string"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, list):
        return "list"
    if isinstance(value, dict):
        return "map"
    return type(value).__name__


def _blank_message(types) -> str:
    names = [types] if isinstance(types, str) else types
    if "object" in names:
        return "is blank; write {} if unused"
    if "array" in names:
        return "is blank; write [] if unused"
    return "is blank; a value is required"


def _unknown_key_message(parent, key, allowed) -> str:
    if parent == ["defaults"] and key == "domains":
        return "domains belong under an environment, not under defaults. A default domain gives every environment the same host."
    if len(parent) == 2 and parent[0] == "environments" and key in SECRET_KEYS:
        return f"{key} is declared under defaults, and each environment sets its values in OpenBao. Remove it here."
    return f"unknown key. Allowed here: {', '.join(allowed)}"


def _errors_to_findings(error, doc) -> list[tuple[list, int, str]]:
    """Turn one schema error into (path, line, message) findings, one per offending key."""
    parent = list(error.absolute_path)
    if error.validator == "required":
        name = ast.literal_eval(error.message.removesuffix(" is a required property"))
        return [(parent + [name], _line_at(doc, parent), f"missing required key '{name}'")]
    if error.validator == "additionalProperties":
        allowed = list(error.schema.get("properties", {}))
        findings = []
        for key in error.instance:
            if key not in allowed:
                path = parent + [key]
                findings.append((path, _line_at(doc, path), _unknown_key_message(parent, key, allowed)))
        return findings

    if error.validator == "type":
        if error.instance is None:
            message = _blank_message(error.validator_value)
        else:
            message = f"expected {_expected(error.validator_value)}, got {_got(error.instance)}"
    elif error.validator in ("minimum", "maximum"):
        schema = error.schema
        if "minimum" in schema and "maximum" in schema:
            bounds = f"from {schema['minimum']} to {schema['maximum']}"
        elif "minimum" in schema:
            bounds = f"at least {schema['minimum']}"
        else:
            bounds = f"at most {schema['maximum']}"
        message = f"must be {bounds}, got {error.instance}"
    elif error.validator == "enum":
        message = f"must be {_or_list(error.validator_value)}, got {error.instance!r}"
    elif error.validator == "pattern" and error.validator_value == "^/":
        message = f"must start with /, got {error.instance!r}"
    elif error.validator == "not":
        # custom_cert_resolver is `not: {}` under a certificate_type other than custom.
        message = "only allowed with certificate_type custom"
    else:
        message = error.message
    return [(parent, _line_at(doc, parent), message)]


def _check_text(file, text, validator, offset=0) -> list[Problem]:
    """Parse one YAML document and return its problems. offset moves lines, for a block inside a guide."""
    try:
        doc = YAML(typ="rt").load(text)
    except MarkedYAMLError as err:
        mark = err.problem_mark
        line = mark.line + 1 + offset if mark else None
        return [Problem(file, line, None, f"not valid YAML: {err.problem}")]
    if doc is None:
        doc = CommentedMap()
    problems, seen = [], set()
    for error in validator.iter_errors(doc):
        for steps, line, message in _errors_to_findings(error, doc):
            path = _yq(steps)
            if path in seen:
                continue
            seen.add(path)
            problems.append(Problem(file, line + offset, path, message))
    return problems


def _check_guide(path, validator) -> list[Problem]:
    """Check every ```yaml block in the guide. Other fences, such as ```text, are not checked."""
    problems = []
    lines = path.read_text(encoding="utf-8").splitlines()
    start = None
    for number, line in enumerate(lines, start=1):
        if start is None and line.strip() == "```yaml":
            start = number
        elif start is not None and line.strip() == "```":
            block = "\n".join(lines[start : number - 1]) + "\n"
            problems += _check_text(GUIDE, block, validator, offset=start)
            start = None
    return problems


def check(root: Path) -> list[Problem]:
    """Validate every file the check covers under root, and return every problem in it.

    Covers projects/*/project.yaml, docs/project.template.yaml and docs/project-yaml.md. Always
    validates against this repo's docs/project.schema.yaml, wherever root is.

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
    - A missing or null skeleton key (repo; defaults with env, secrets and shared; environments
      with staging and production) is named, and a null one says to write {} or []. volumes is
      optional under defaults.
    - An environment other than staging or production names the two allowed.
    - A wrong type names the expected type. An env value must be a string with no newline; a
      number or boolean says to quote it.
    - Within one environment, with its env merged over defaults.env, a name in two of env, secrets
      and shared is a Problem at the env key when env is one of the two, otherwise at the shared
      entry, and its message gives the other one's path.
    - A domain needs port, an integer from 1 to 65535. certificate_type is letsencrypt, none or
      custom (the message lists them). custom_cert_resolver is required with certificate_type
      custom and rejected otherwise. https: false allows only certificate_type none. path and
      internal_path start with /.
    - The guide has exactly one reference example, fenced ```yaml: a complete project.yaml that
      passes and uses every key the schema allows. No reference, or more than one, is a Problem,
      and so is each key the reference leaves out, named in the message. Each ```yaml excerpt
      block must be consecutive lines of the reference, compared without leading indentation; one
      that isn't is a Problem at its opening fence's line. Other fences, such as ```text, aren't checked.
    """
    validator = Draft202012Validator(YAML(typ="safe").load(SCHEMA_PATH.read_text(encoding="utf-8")))
    problems = []
    for project in sorted(root.glob("projects/*/project.yaml")):
        rel = project.relative_to(root).as_posix()
        problems += _check_text(rel, project.read_text(encoding="utf-8"), validator)
    template = root / TEMPLATE
    if template.is_file():
        problems += _check_text(TEMPLATE, template.read_text(encoding="utf-8"), validator)
    else:
        problems.append(Problem(TEMPLATE, None, None, "file is missing"))
    guide = root / GUIDE
    if guide.is_file():
        problems += _check_guide(guide, validator)
    else:
        problems.append(Problem(GUIDE, None, None, "file is missing"))
    return problems


def main(argv: list[str]) -> int:
    """scripts/check-project-yaml [root]: print every problem under root (default: the repo root).

    One line per problem, then a count line such as "3 problems in 2 files". With
    GITHUB_ACTIONS=true each problem is a workflow command,
    ::error file=<file>,line=<line>::<path>: <message>, so it shows as a PR annotation; otherwise
    <file>:<line>: <path>: <message>. Returns the exit code: 0 with no problems, 1 otherwise.
    """
    root = Path(argv[0]) if argv else REPO_ROOT
    problems = check(root)
    in_ci = os.environ.get("GITHUB_ACTIONS") == "true"
    for problem in problems:
        text = f"{problem.path}: {problem.message}" if problem.path else problem.message
        if in_ci:
            where = f",line={problem.line}" if problem.line is not None else ""
            print(f"::error file={problem.file}{where}::{text}")
        else:
            where = f":{problem.line}" if problem.line is not None else ""
            print(f"{problem.file}{where}: {text}")
    if not problems:
        print("no problems")
        return 0
    count = len(problems)
    files = len({problem.file for problem in problems})
    print(f"{count} problem{'' if count == 1 else 's'} in {files} file{'' if files == 1 else 's'}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
