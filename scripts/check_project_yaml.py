"""Checks every project.yaml, the guide and the template against docs/project.schema.yaml.

The schema is the list of what project.yaml may contain: closed at every level, so an unknown key
fails. It is stricter than modules/project, which still accepts per-environment secrets, shared secrets,
volumes and other environment names. The rules JSON Schema can't express live here (ADR-0001): a name
in two of env, secrets and shared, and a domain's host and path declared twice across projects.
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
SCHEMA_PATH = REPO_ROOT / "docs" / "project.schema.yaml"
TEMPLATE = "docs/project.template.yaml"
GUIDE = "docs/project-yaml.md"
PLAIN_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
TYPE_NAMES = {"array": "list", "object": "map"}
DEFAULTS_ONLY_KEYS = ("secrets", "shared", "volumes")
MUST_SHOW_ENTRY = ("env", "secrets", "shared", "volumes")
REFERENCE_FENCE = "yaml"
EXCERPT_FENCE = "yaml excerpt"


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


def _type_list(types) -> list[str]:
    return [types] if isinstance(types, str) else types


def _expected(types) -> str:
    return _or_list(TYPE_NAMES.get(name, name) for name in _type_list(types))


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
    names = _type_list(types)
    if "object" in names:
        return "is blank; write {} if unused"
    if "array" in names:
        return "is blank; write [] if unused"
    return "is blank; a value is required"


def _unknown_key_message(parent, key, allowed) -> str:
    if parent == ["defaults"] and key == "domains":
        return "domains belong under an environment, not under defaults. A default domain gives every environment the same host."
    if len(parent) == 2 and parent[0] == "environments" and key in DEFAULTS_ONLY_KEYS:
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
    return [(parent, _line_at(doc, parent), _value_message(error, parent))]


def _value_message(error, parent) -> str:
    """The message for a schema error about the value at parent, rather than about its keys."""
    if error.validator == "type":
        if error.instance is None:
            return _blank_message(error.validator_value)
        if "env" in parent and isinstance(error.instance, (bool, int, float)):
            return f"expected string, got {_got(error.instance)}; quote this value"
        return f"expected {_expected(error.validator_value)}, got {_got(error.instance)}"
    if error.validator in ("minimum", "maximum"):
        return f"must be {_bounds(error.schema)}, got {error.instance}"
    if error.validator == "enum":
        return f"must be {_or_list(error.validator_value)}, got {error.instance!r}"
    if error.validator == "pattern" and error.validator_value == "^/":
        return f"must start with /, got {error.instance!r}"
    if error.validator == "pattern" and "\\r\\n" in error.validator_value:
        return "must be a string without a newline"
    if error.validator == "not" and parent[-1:] == ["custom_cert_resolver"]:
        return "only allowed with certificate_type custom"
    if error.validator == "uniqueItems":
        repeated = sorted({item for i, item in enumerate(error.instance) if item in error.instance[:i]}, key=str)
        return f"lists {_or_list(str(item) for item in repeated)} more than once"
    return error.message


def _bounds(schema) -> str:
    if "minimum" in schema and "maximum" in schema:
        return f"from {schema['minimum']} to {schema['maximum']}"
    if "minimum" in schema:
        return f"at least {schema['minimum']}"
    return f"at most {schema['maximum']}"


def _load(text):
    """Parse one YAML document, keeping line numbers. None for an empty one. Raises MarkedYAMLError."""
    return YAML(typ="rt").load(text)


def _not_yaml(file, error, offset=0) -> Problem:
    """The one Problem for text that isn't valid YAML, at the parser's line and with its reason."""
    mark = error.problem_mark
    line = mark.line + 1 + offset if mark else None
    return Problem(file, line, None, f"not valid YAML: {error.problem}")


def _yaml_text(key) -> str:
    """A non-string key as YAML writes it: 1.5, true, null, 2024-01-01."""
    if key is None:
        return "null"
    if isinstance(key, bool):
        return str(key).lower()
    return key.isoformat() if hasattr(key, "isoformat") else str(key)


def _key_problems(file, doc, offset=0, steps=(), above=frozenset()) -> list[Problem]:
    """A Problem at each map key YAML didn't read as a string. The schema can't see these, and _yq can't name them.

    Also a Problem at each alias back to a map or list that contains it (&loop [*loop]). The parser keeps
    that loop, and the scan and the schema would recurse until they crash. above holds the ids of doc's containers.
    """
    above |= {id(doc)}
    children = doc.items() if isinstance(doc, dict) else enumerate(doc) if isinstance(doc, list) else ()
    problems = []
    for step, child in children:
        if isinstance(doc, dict) and not isinstance(step, str):
            text = _yaml_text(step)
            message = f"key {text} isn't a string to YAML. Quote it: \"{text}\""
            problems.append(Problem(file, _line_at(doc, [step]) + offset, f"{_yq(steps) if steps else ''}[{text}]", message))
        elif id(child) in above:
            message = "alias refers to a map or list that contains it. Write the value out instead"
            problems.append(Problem(file, _line_at(doc, [step]) + offset, _yq(steps + (step,)), message))
        else:
            problems += _key_problems(file, child, offset, steps + (step,), above)
    return problems


def _schema_problems(file, doc, validator, offset=0) -> list[Problem]:
    """One Problem per offending path in doc. offset moves lines, for a block inside a guide."""
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


def _check_text(file, text, validator) -> list[Problem]:
    """Parse one YAML file and return its schema problems."""
    try:
        doc = _load(text)
    except MarkedYAMLError as err:
        return [_not_yaml(file, err)]
    return _key_problems(file, doc) or _schema_problems(file, doc, validator)


def _check_project(file, text, validator) -> tuple[list[Problem], object]:
    """Parse one project.yaml and return its schema problems, then its collisions, and the parsed file.
    The file is None when it isn't YAML or has a key the other checks wait on."""
    try:
        doc = _load(text)
    except MarkedYAMLError as err:
        return [_not_yaml(file, err)], None
    problems = _key_problems(file, doc)
    if problems:
        return problems, None
    return _schema_problems(file, doc, validator) + _collision_problems(file, doc), doc


def _as_map(value) -> dict:
    return value if isinstance(value, dict) else {}


def _as_list(value) -> list:
    return value if isinstance(value, list) else []


def _resolve_schema(schema, root_schema):
    ref = schema.get("$ref")
    if ref:
        for part in ref.removeprefix("#/").split("/"):
            root_schema = root_schema[part]
        return root_schema
    return schema


def _missing_reference_keys(doc, schema, root_schema):
    """Return (path, message) for each property never demonstrated in any matching object in the reference,
    and for each map whose entries have properties but that the reference never gives an entry."""
    first_seen, present = {}, {}

    def visit(value, candidate, path=()):
        candidate = _resolve_schema(candidate, root_schema)
        if not isinstance(value, dict) or candidate.get("type") != "object":
            return
        properties = candidate.get("properties", {})
        if properties:
            first_seen.setdefault(id(candidate), (candidate, path))
            present.setdefault(id(candidate), set()).update(key for key in value if key in properties)
        for key, child_schema in properties.items():
            if key in value:
                visit(value[key], child_schema, path + (key,))
        additional = candidate.get("additionalProperties")
        if isinstance(additional, dict):
            for key, child_value in value.items():
                if key not in properties:
                    visit(child_value, additional, path + (key,))

    unshown = {}

    def walk(candidate, path=()):
        """Find entry schemas that visit never reached, since an empty map instantiates none."""
        candidate = _resolve_schema(candidate, root_schema)
        if candidate.get("type") != "object":
            return
        for key, child_schema in candidate.get("properties", {}).items():
            walk(child_schema, path + (key,))
        additional = candidate.get("additionalProperties")
        if isinstance(additional, dict):
            entry = _resolve_schema(additional, root_schema)
            if id(entry) in first_seen:
                walk(entry, first_seen[id(entry)][1])
            elif entry.get("properties"):
                unshown.setdefault(id(entry), path)

    visit(doc, schema)
    walk(schema)
    missing = [
        (path + (key,), f"reference example is missing allowed key '{key}'")
        for schema_id, (candidate, path) in first_seen.items()
        for key in candidate["properties"]
        if key not in present[schema_id]
    ]
    return missing + [(path, f"reference example's {path[-1]} must show an entry") for path in unshown.values()]


def _yaml_blocks(lines) -> tuple[list[tuple[str, int, str]], int | None]:
    """Each ```yaml and ```yaml excerpt block as (fence, opening line, body), and the opening line of a last
    block the guide never closes. Other fences are skipped."""
    blocks, start, fence = [], None, None
    for number, line in enumerate(lines, start=1):
        if start is None and line.strip() in (f"```{REFERENCE_FENCE}", f"```{EXCERPT_FENCE}"):
            start, fence = number, line.strip()[3:]
        elif start is not None and line.strip() == "```":
            blocks.append((fence, start, "\n".join(lines[start : number - 1]) + "\n"))
            start = None
    return blocks, start


def _check_guide(path, validator, schema) -> list[Problem]:
    """Check the one complete reference example and every excerpt in the guide, and that each block closes."""
    blocks, unclosed = _yaml_blocks(path.read_text(encoding="utf-8").splitlines())
    problems = [] if unclosed is None else [Problem(GUIDE, unclosed, None, "yaml block has no closing ``` fence")]
    references = [(line, body) for fence, line, body in blocks if fence == REFERENCE_FENCE]
    excerpts = [(line, body) for fence, line, body in blocks if fence == EXCERPT_FENCE]
    if len(references) != 1:
        problem = Problem(GUIDE, 1, None, "guide must contain exactly one ```yaml reference example")
        return problems + [problem] + _excerpt_problems(excerpts, "")
    ref_line, reference = references[0]
    return (
        problems
        + _reference_problems(reference, ref_line, validator, schema)
        + _excerpt_problems(excerpts, reference)
    )


def _reference_problems(reference, ref_line, validator, schema) -> list[Problem]:
    """The reference's schema problems, each allowed key it leaves out, and each defaults key it leaves empty."""
    try:
        doc = _load(reference)
    except MarkedYAMLError as err:
        return [_not_yaml(GUIDE, err, ref_line)]
    problems = _key_problems(GUIDE, doc, ref_line)
    if problems:
        return problems
    problems = _schema_problems(GUIDE, doc, validator, ref_line)
    if doc is None:
        return problems
    for steps, message in _missing_reference_keys(doc, schema, schema):
        problems.append(Problem(GUIDE, ref_line, _yq(list(steps)), message))
    defaults = _as_map(_as_map(doc).get("defaults"))
    for key in MUST_SHOW_ENTRY:
        if key in defaults and defaults[key] in ({}, []):
            message = f"reference example's {key} must show an entry"
            problems.append(Problem(GUIDE, ref_line, _yq(["defaults", key]), message))
    return problems


def _unindented(text) -> list[str]:
    return [line.lstrip() for line in text.splitlines()]


def _is_run_of(part, whole) -> bool:
    """Whether part is a non-empty run of consecutive items in whole."""
    return bool(part) and any(whole[i : i + len(part)] == part for i in range(len(whole) - len(part) + 1))


def _excerpt_problems(excerpts, reference) -> list[Problem]:
    """A Problem at the opening fence of each excerpt that isn't consecutive lines of the reference."""
    ref_lines = _unindented(reference)
    return [
        Problem(GUIDE, line, None, "yaml excerpt must be consecutive lines from the reference example")
        for line, body in excerpts
        if not _is_run_of(_unindented(body), ref_lines)
    ]


def _collision_problems(file, doc) -> list[Problem]:
    """A Problem for each name in two of env, secrets and shared, per environment, at the env key or shared entry.

    A collision within defaults alone is reported once, as in defaults.
    """
    defaults = _as_map(_as_map(doc).get("defaults"))
    secrets, shared = (
        {name: ["defaults", key, i] for i, name in enumerate(_as_list(defaults.get(key))) if isinstance(name, str)}
        for key in ("secrets", "shared")
    )
    problems, seen = [], set()
    for label, env in _env_scopes(doc, defaults):
        for name, target, other in _clashes(env, secrets, shared):
            finding = (tuple(target), tuple(other))
            if finding in seen:
                continue
            seen.add(finding)
            message = f"{name} is also declared at {_yq(other)} in {label}"
            problems.append(Problem(file, _line_at(doc, target), _yq(target), message))
    return problems


def _env_scopes(doc, defaults):
    """Yield (label, env name to path): defaults.env alone, then each environment's env merged over it."""
    base = {name: ["defaults", "env", name] for name in _as_map(defaults.get("env"))}
    yield "defaults", base
    for env_name, config in _as_map(_as_map(doc).get("environments")).items():
        override = _as_map(_as_map(config).get("env")) if env_name is not None else {}
        yield env_name or "defaults", {**base, **{name: ["environments", env_name, "env", name] for name in override}}


def _clashes(env, secrets, shared):
    """Yield (name, where the problem sits, the other place) for each name declared in two places."""
    places = {}
    for kind, paths in (("env", env), ("secrets", secrets), ("shared", shared)):
        for name, path in paths.items():
            places.setdefault(name, {})[kind] = path
    for name, found in places.items():
        if len(found) < 2:
            continue
        if "env" in found:
            target, others = found["env"], [found[kind] for kind in ("secrets", "shared") if kind in found]
        else:
            target, others = found["shared"], [found["secrets"]]
        for other in others:
            yield name, target, other


def _domain_problems(docs) -> list[Problem]:
    """A Problem at each domain whose host and path another domain also has, in any project or environment,
    naming the others. Hosts compare without case, and a domain with no path is at /."""
    places = {}
    for file, doc in docs:
        for env_name, config in _as_map(_as_map(doc).get("environments")).items():
            for host, settings in _as_map(_as_map(config).get("domains")).items():
                path = _as_map(settings).get("path") or "/"
                if isinstance(host, str) and isinstance(path, str):
                    steps = ["environments", env_name, "domains", host]
                    places.setdefault((host.lower(), path), []).append((file, doc, steps))
    problems = []
    for (host, path), found in places.items():
        for file, doc, steps in found:
            others = [f"{_yq(o_steps)} in {o_file}" for o_file, _, o_steps in found if o_steps is not steps]
            if others:
                message = f"{host} at {path} is also declared at {'; '.join(others)}"
                problems.append(Problem(file, _line_at(doc, steps), _yq(steps), message))
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
    - A key YAML reads as a number, boolean, null or date says to quote it, and the file's other
      checks wait until it's fixed: the schema sees every key as a string and can't catch these.
    - So does an alias to a map or list that contains it (&loop [*loop]), at the alias.
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
    - A name listed twice in secrets, or twice in shared, is a Problem naming it.
    - A domain needs port, an integer from 1 to 65535. certificate_type is letsencrypt, none or
      custom (the message lists them). custom_cert_resolver is required with certificate_type
      custom and rejected otherwise. https: false allows only certificate_type none. path and
      internal_path start with /.
    - A domain's host and path are unique across every project and environment, comparing hosts
      without case and reading a missing path as /. Each place is a Problem naming the others. The
      template and the guide aren't compared, since they use example hosts.
    - The guide has exactly one reference example, fenced ```yaml: a complete project.yaml that
      passes and uses every key the schema allows. No reference, or more than one, is a Problem,
      and so is each key the reference leaves out, named in the message. Its defaults env, secrets,
      shared and volumes must each show an entry; an empty one is a Problem naming it. Each ```yaml excerpt
      block must be consecutive lines of the reference, compared without leading indentation; one
      that isn't is a Problem at its opening fence's line. Other fences, such as ```text, aren't checked.
    """
    schema = YAML(typ="safe").load(SCHEMA_PATH.read_text(encoding="utf-8"))
    validator = Draft202012Validator(schema)
    problems, docs = [], []
    for project in sorted(root.glob("projects/*/project.yaml")):
        file = project.relative_to(root).as_posix()
        found, doc = _check_project(file, project.read_text(encoding="utf-8"), validator)
        problems += found
        docs.append((file, doc))
    problems += _domain_problems(docs)
    template = root / TEMPLATE
    if template.is_file():
        problems += _check_text(TEMPLATE, template.read_text(encoding="utf-8"), validator)
    else:
        problems.append(Problem(TEMPLATE, None, None, "file is missing"))
    guide = root / GUIDE
    if guide.is_file():
        problems += _check_guide(guide, validator, schema)
    else:
        problems.append(Problem(GUIDE, None, None, "file is missing"))
    return problems


def _count(number, noun) -> str:
    return f"{number} {noun}{'' if number == 1 else 's'}"


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
    files = {problem.file for problem in problems}
    print(f"{_count(len(problems), 'problem')} in {_count(len(files), 'file')}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
