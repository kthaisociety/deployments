"""Tests for check_project_yaml and scripts/check-project-yaml: project files, the guide and the template."""

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

from check_project_yaml import check

REPO = Path(__file__).resolve().parent.parent
COMMAND = REPO / "scripts" / "check-project-yaml"
PROJECT = "projects/demo/project.yaml"
TEMPLATE = "docs/project.template.yaml"
GUIDE = "docs/project-yaml.md"

MINIMAL = """\
repo: example/demo
defaults:
  env: {}
  secrets: []
  shared: []
  volumes: {}
environments:
  staging: {}
  production: {}
"""


FULL = """\
repo: example/demo
image: ghcr.io/example/other
defaults:
  env:
    MODE: release
  secrets:
    - TOKEN
  shared:
    - SHARED_TOKEN
  volumes:
    /data: data
environments:
  staging:
    env:
      MODE: debug
    domains:
      demo.example.com:
        port: 3000
        https: true
        certificate_type: custom
        custom_cert_resolver: myresolver
        path: /api
        internal_path: /
        strip_path: true
        enabled: true
        forward_auth_enabled: false
        custom_entrypoint: websecure
  production: {}
"""


def guide(*blocks):
    """A guide holding the given blocks, each (info string, body), in order."""
    return "# project.yaml\n" + "".join(f"\n```{info}\n{body}```\n" for info, body in blocks)


def project_yaml(*, top="", defaults="", staging=" {}", production=" {}"):
    """MINIMAL with extra lines at the top level and under defaults, and each environment's body."""
    return (
        f"repo: example/demo\n{top}"
        "defaults:\n  env: {}\n  secrets: []\n  shared: []\n  volumes: {}\n"
        f"{defaults}"
        f"environments:\n  staging:{staging}\n  production:{production}\n"
    )


def staging_domain(settings):
    """A staging body with one domain, demo.example.com, whose settings are the given lines."""
    lines = "".join(f"        {s}\n" for s in settings)
    return f"\n    domains:\n      demo.example.com:\n{lines}"


DOMAIN = '.environments.staging.domains["demo.example.com"]'


def write(root, rel, text):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


@pytest.fixture
def repo(tmp_path):
    """A root that passes: one minimal project, the template, and a guide whose reference is FULL."""
    write(tmp_path, PROJECT, MINIMAL)
    write(tmp_path, TEMPLATE, MINIMAL)
    write(tmp_path, GUIDE, guide(("yaml", FULL)))
    return tmp_path


def message_at(problems, path):
    """The message of the one problem at path."""
    matches = [p for p in problems if p.path == path]
    assert len(matches) == 1, problems
    return matches[0].message


def paths(problems):
    return {p.path for p in problems}


def run_command(root, **env):
    environ = {k: v for k, v in os.environ.items() if k != "GITHUB_ACTIONS"}
    return subprocess.run(
        [str(COMMAND), str(root)], capture_output=True, text=True, env={**environ, **env}
    )


# Passing input


def test_minimal_valid_repo_has_no_problems(repo):
    """The skeleton with every unused key written as {} or [] passes."""
    assert check(repo) == []


def test_onboarding_service_passes_unchanged(repo):
    """The existing onboarding-service project.yaml passes as it is."""
    write(
        repo,
        "projects/onboarding-service/project.yaml",
        (REPO / "projects/onboarding-service/project.yaml").read_text(),
    )
    assert check(repo) == []


def test_optional_settings_pass(repo):
    """A top-level image and a domain using every optional setting with valid values pass."""
    write(
        repo,
        PROJECT,
        project_yaml(
            top="image: ghcr.io/example/other\n",
            staging=staging_domain(
                [
                    "port: 3000",
                    "https: true",
                    "certificate_type: custom",
                    "custom_cert_resolver: myresolver",
                    "path: /api",
                    "internal_path: /",
                    "strip_path: true",
                    "enabled: true",
                    "forward_auth_enabled: false",
                    "custom_entrypoint: websecure",
                ]
            ),
        ),
    )
    assert check(repo) == []


def test_env_string_values_pass(repo):
    """env values that are strings pass, including quoted numbers and booleans."""
    write(
        repo,
        PROJECT,
        project_yaml(staging='\n    env:\n      MODE: release\n      PORT: "8080"\n      DEBUG: "true"\n'),
    )
    assert check(repo) == []


def test_skeleton_without_volumes_passes(repo):
    """volumes is optional under defaults."""
    write(repo, PROJECT, MINIMAL.replace("  volumes: {}\n", ""))
    assert check(repo) == []


def test_env_override_is_not_a_collision(repo):
    """An environment's env setting a name defaults.env also sets is an override, not a collision."""
    write(repo, PROJECT, MINIMAL.replace("  env: {}", "  env:\n    MODE: release").replace(
        "  staging: {}", "  staging:\n    env:\n      MODE: debug"
    ))
    assert check(repo) == []


# Keys


@pytest.mark.parametrize(
    "text, path, allowed",
    [
        (project_yaml(top="name: demo\n"), ".name", ["repo", "image", "defaults", "environments"]),
        (
            project_yaml(defaults="  secret: []\n"),
            ".defaults.secret",
            ["env", "secrets", "shared", "volumes"],
        ),
        (
            project_yaml(staging="\n    port: 3000\n"),
            ".environments.staging.port",
            ["env", "domains"],
        ),
        (
            project_yaml(staging=staging_domain(["port: 3000", "prot: 3000"])),
            f"{DOMAIN}.prot",
            [
                "port",
                "https",
                "certificate_type",
                "custom_cert_resolver",
                "path",
                "internal_path",
                "strip_path",
                "enabled",
                "forward_auth_enabled",
                "custom_entrypoint",
            ],
        ),
    ],
    ids=["top-level", "defaults", "environment", "domain"],
)
def test_unknown_key_lists_allowed_keys(repo, text, path, allowed):
    """An unknown key fails, and its message lists every key allowed at that path."""
    write(repo, PROJECT, text)
    message = message_at(check(repo), path)
    assert [k for k in allowed if k not in message] == []


def test_domains_under_defaults_says_where_it_belongs(repo):
    """domains under defaults fails and says it goes under an environment."""
    write(repo, PROJECT, project_yaml(defaults="  domains:\n    demo.example.com:\n      port: 3000\n"))
    assert "environment" in message_at(check(repo), ".defaults.domains")


@pytest.mark.parametrize(
    "key, body",
    [("secrets", " [A]"), ("shared", " [A]"), ("volumes", " {/data: data}")],
    ids=["secrets", "shared", "volumes"],
)
def test_per_environment_secrets_point_to_defaults_and_openbao(repo, key, body):
    """secrets, shared or volumes under an environment says: names under defaults, values in OpenBao."""
    write(repo, PROJECT, project_yaml(staging=f"\n    {key}:{body}\n"))
    message = message_at(check(repo), f".environments.staging.{key}")
    assert [w for w in ["defaults", "OpenBao"] if w not in message] == []


@pytest.mark.parametrize(
    "removed, path, name",
    [
        ("repo: example/demo\n", ".repo", "repo"),
        ("defaults:\n  env: {}\n  secrets: []\n  shared: []\n  volumes: {}\n", ".defaults", "defaults"),
        ("  env: {}\n", ".defaults.env", "env"),
        ("  secrets: []\n", ".defaults.secrets", "secrets"),
        ("  shared: []\n", ".defaults.shared", "shared"),
        ("environments:\n  staging: {}\n  production: {}\n", ".environments", "environments"),
        ("  staging: {}\n", ".environments.staging", "staging"),
        ("  production: {}\n", ".environments.production", "production"),
    ],
    ids=["repo", "defaults", "env", "secrets", "shared", "environments", "staging", "production"],
)
def test_missing_skeleton_key_is_named(repo, removed, path, name):
    """A missing skeleton key fails at the path it should have, and the message names it."""
    write(repo, PROJECT, MINIMAL.replace(removed, ""))
    assert name in message_at(check(repo), path)


@pytest.mark.parametrize(
    "line, path, empty",
    [
        ("  env: {}\n", ".defaults.env", "{}"),
        ("  secrets: []\n", ".defaults.secrets", "[]"),
        ("  shared: []\n", ".defaults.shared", "[]"),
        ("  volumes: {}\n", ".defaults.volumes", "{}"),
        ("  staging: {}\n", ".environments.staging", "{}"),
    ],
    ids=["env", "secrets", "shared", "volumes", "staging"],
)
def test_null_skeleton_key_says_write_empty(repo, line, path, empty):
    """A skeleton key left blank (null) says to write {} or [] when unused."""
    write(repo, PROJECT, MINIMAL.replace(line, line.split(":")[0] + ":\n"))
    assert empty in message_at(check(repo), path)


def test_blank_repo_says_a_value_is_required(repo):
    """repo left blank (null) says a value is required."""
    write(repo, PROJECT, MINIMAL.replace("repo: example/demo\n", "repo:\n"))
    assert "a value is required" in message_at(check(repo), ".repo")


def test_domain_without_port_names_port(repo):
    """A domain without port fails, and the message names port."""
    write(repo, PROJECT, project_yaml(staging=staging_domain(["https: true"])))
    assert "port" in message_at(check(repo), f"{DOMAIN}.port")


def test_extra_environment_names_the_two_allowed(repo):
    """An environment other than staging or production fails, naming the two allowed."""
    write(repo, PROJECT, MINIMAL + "  dev: {}\n")
    message = message_at(check(repo), ".environments.dev")
    assert [e for e in ["staging", "production"] if e not in message] == []


# Values


def test_wrong_type_names_expected_type(repo):
    """port: "8080" fails, and the message names the expected type."""
    write(repo, PROJECT, project_yaml(staging=staging_domain(['port: "8080"'])))
    assert "integer" in message_at(check(repo), f"{DOMAIN}.port")


def test_env_non_scalar_value_fails(repo):
    """An env value that is a list fails."""
    write(repo, PROJECT, project_yaml(staging="\n    env:\n      HOSTS: [a, b]\n"))
    assert ".environments.staging.env.HOSTS" in paths(check(repo))


@pytest.mark.parametrize(
    "value, got",
    [("8080", "number"), ("true", "boolean"), ("2024-01-01", "date")],
    ids=["number", "boolean", "date"],
)
def test_env_non_string_value_says_quote_it(repo, value, got):
    """An env value YAML reads as a number, boolean or date fails, names what YAML read, and says to quote it."""
    write(repo, PROJECT, project_yaml(staging=f"\n    env:\n      PORT: {value}\n"))
    message = message_at(check(repo), ".environments.staging.env.PORT")
    assert "quote" in message.lower() and f"got {got}" in message


def test_env_that_isnt_a_map_says_expected_map(repo):
    """env: 5 says env must be a map, not to quote the 5: quoting it would still fail."""
    write(repo, PROJECT, MINIMAL.replace("  env: {}", "  env: 5"))
    message = message_at(check(repo), ".defaults.env")
    assert "expected map" in message and "quote" not in message


def test_env_multiline_value_fails(repo):
    """An env value with a newline in it fails."""
    write(repo, PROJECT, project_yaml(staging='\n    env:\n      NOTE: "a\\nb"\n'))
    assert ".environments.staging.env.NOTE" in paths(check(repo))


@pytest.mark.parametrize(
    "text, path, other",
    [
        (
            MINIMAL.replace("  env: {}", "  env:\n    TOKEN: x").replace("  secrets: []", "  secrets: [TOKEN]"),
            ".defaults.env.TOKEN",
            ".defaults.secrets[0]",
        ),
        (
            MINIMAL.replace("  env: {}", "  env:\n    TOKEN: x").replace("  shared: []", "  shared: [TOKEN]"),
            ".defaults.env.TOKEN",
            ".defaults.shared[0]",
        ),
        (
            MINIMAL.replace("  secrets: []", "  secrets: [TOKEN]").replace("  shared: []", "  shared: [TOKEN]"),
            ".defaults.shared[0]",
            ".defaults.secrets[0]",
        ),
        (
            MINIMAL.replace("  secrets: []", "  secrets: [TOKEN]").replace(
                "  staging: {}", "  staging:\n    env:\n      TOKEN: x"
            ),
            ".environments.staging.env.TOKEN",
            ".defaults.secrets[0]",
        ),
    ],
    ids=["env-secrets", "env-shared", "secrets-shared", "environment-env-secrets"],
)
def test_name_in_two_places_fails_naming_the_other(repo, text, path, other):
    """A name in two of env, secrets and shared fails at the env key or the shared entry, naming the other path."""
    write(repo, PROJECT, text)
    assert other in message_at(check(repo), path)


def test_shared_as_groups_says_expected_list(repo):
    """shared written as groups, the old shape, fails: it's a list of names."""
    write(repo, PROJECT, MINIMAL.replace("  shared: []", "  shared:\n    group: [TOKEN]"))
    assert "expected list" in message_at(check(repo), ".defaults.shared")


@pytest.mark.parametrize("key", ["secrets", "shared"])
def test_name_twice_in_one_list_fails(repo, key):
    """The same name twice in secrets or in shared fails: the app would get two lines for one variable."""
    write(repo, PROJECT, MINIMAL.replace(f"  {key}: []", f"  {key}: [TOKEN, TOKEN]"))
    assert "TOKEN more than once" in message_at(check(repo), f".defaults.{key}")


def test_unknown_certificate_type_lists_allowed(repo):
    """A certificate_type other than letsencrypt, none or custom fails, listing the three."""
    write(repo, PROJECT, project_yaml(staging=staging_domain(["port: 3000", "certificate_type: wildcard"])))
    message = message_at(check(repo), f"{DOMAIN}.certificate_type")
    assert [v for v in ["letsencrypt", "none", "custom"] if v not in message] == []


@pytest.mark.parametrize("port", [0, 65536])
def test_port_out_of_range_fails(repo, port):
    """A port outside 1 to 65535 fails."""
    write(repo, PROJECT, project_yaml(staging=staging_domain([f"port: {port}"])))
    assert f"{DOMAIN}.port" in paths(check(repo))


def test_custom_certificate_requires_resolver(repo):
    """certificate_type: custom without custom_cert_resolver fails at custom_cert_resolver."""
    write(repo, PROJECT, project_yaml(staging=staging_domain(["port: 3000", "certificate_type: custom"])))
    assert f"{DOMAIN}.custom_cert_resolver" in paths(check(repo))


def test_resolver_without_custom_certificate_fails(repo):
    """custom_cert_resolver with a certificate_type other than custom fails."""
    write(
        repo,
        PROJECT,
        project_yaml(
            staging=staging_domain(
                ["port: 3000", "certificate_type: letsencrypt", "custom_cert_resolver: myresolver"]
            )
        ),
    )
    assert f"{DOMAIN}.custom_cert_resolver" in paths(check(repo))


def test_https_off_allows_only_no_certificate(repo):
    """https: false with certificate_type letsencrypt fails at certificate_type."""
    write(
        repo,
        PROJECT,
        project_yaml(staging=staging_domain(["port: 3000", "https: false", "certificate_type: letsencrypt"])),
    )
    assert f"{DOMAIN}.certificate_type" in paths(check(repo))


@pytest.mark.parametrize("key", ["path", "internal_path"])
def test_path_without_leading_slash_fails(repo, key):
    """path and internal_path must start with /."""
    write(repo, PROJECT, project_yaml(staging=staging_domain(["port: 3000", f"{key}: api"])))
    assert f"{DOMAIN}.{key}" in paths(check(repo))


# Files and reporting


NOT_YAML = "repo: example/demo\ndefaults:\n  env: {}\n\tsecrets: []\n"


def test_invalid_yaml_reports_parser_line(repo):
    """A file that isn't valid YAML gives one problem with no path, at the parser's line."""
    write(repo, PROJECT, NOT_YAML)
    assert [(p.path, p.line) for p in check(repo) if p.file == PROJECT] == [(None, 4)]


def test_invalid_yaml_reports_parser_reason(repo):
    """A file that isn't valid YAML gives the parser's reason."""
    write(repo, PROJECT, NOT_YAML)
    assert "cannot start any token" in message_at(check(repo), None)


def test_invalid_yaml_does_not_stop_other_files(repo):
    """A file that isn't valid YAML doesn't stop the other files being checked."""
    write(repo, PROJECT, "repo: [unclosed\n")
    write(repo, "projects/other/project.yaml", project_yaml(top="name: other\n"))
    assert "projects/other/project.yaml" in {p.file for p in check(repo)}


def test_duplicate_key_fails_with_its_line(repo):
    """A key written twice in one map fails at the second one's line."""
    write(repo, PROJECT, MINIMAL.replace("  env: {}\n", "  env: {}\n  env: {}\n"))
    assert 4 in {p.line for p in check(repo) if p.file == PROJECT}


@pytest.mark.parametrize("key", ["1.5", "15", "true", "null", "2024-01-01"])
def test_non_string_key_says_quote_it(repo, key):
    """A key YAML reads as a number, boolean, null or date fails at its line and says to quote it."""
    write(repo, PROJECT, project_yaml(staging=f"\n    env:\n      {key}: x\n"))
    problems = [p for p in check(repo) if p.file == PROJECT]
    assert [(p.path, p.line) for p in problems] == [(f".environments.staging.env[{key}]", 10)]
    assert "quote" in problems[0].message.lower()


def test_non_string_key_in_guide_reported_at_guide_line(repo):
    """A non-string key in the reference example fails at its line in the markdown."""
    write(repo, GUIDE, guide(("yaml", FULL.replace("    MODE: release\n", "    1.5: release\n"))))
    assert [(p.path, p.line) for p in check(repo)] == [(".defaults.env[1.5]", 8)]


@pytest.mark.parametrize(
    "text, path",
    [
        ("&loop [*loop]\n", "[0]"),
        ("&loop {repo: *loop}\n", ".repo"),
        ("&loop\nrepo: example/demo\ndefaults: {env: {}, loop: *loop}\n", ".defaults.loop"),
    ],
)
def test_alias_loop_is_a_problem_not_a_crash(repo, text, path):
    """An alias to a map or list that contains it is a problem at the alias, and the other files are still checked.

    The parser keeps an alias to the document root as a real loop. Aliases to anything deeper load as null.
    """
    write(repo, PROJECT, text)
    write(repo, "projects/other/project.yaml", project_yaml(top="name: other\n"))
    problems = check(repo)
    assert "contains it" in message_at([p for p in problems if p.file == PROJECT], path)
    assert "projects/other/project.yaml" in {p.file for p in problems}


# Domains across projects

OTHER = "projects/other/project.yaml"


def domain_body(host, settings=("port: 3000",)):
    """An environment body with one domain."""
    lines = "".join(f"        {s}\n" for s in settings)
    return f"\n    domains:\n      {host}:\n{lines}"


def test_same_host_in_two_projects_fails_at_each_naming_the_other(repo):
    """A host and path in two projects is a Problem at each place, naming the other file and path."""
    write(repo, PROJECT, project_yaml(staging=domain_body("app.example.com")))
    write(repo, OTHER, project_yaml(production=domain_body("app.example.com")))
    problems = check(repo)
    here = message_at([p for p in problems if p.file == PROJECT], '.environments.staging.domains["app.example.com"]')
    there = message_at([p for p in problems if p.file == OTHER], '.environments.production.domains["app.example.com"]')
    assert OTHER in here and ".environments.production" in here
    assert PROJECT in there and ".environments.staging" in there


def test_same_host_in_both_environments_of_one_project_fails(repo):
    """staging and production on the same host fail too."""
    write(repo, PROJECT, project_yaml(staging=domain_body("app.example.com"), production=domain_body("app.example.com")))
    assert paths(check(repo)) == {
        '.environments.staging.domains["app.example.com"]',
        '.environments.production.domains["app.example.com"]',
    }


def test_hosts_compare_without_case(repo):
    """App.Example.com and app.example.com are the same host."""
    write(repo, PROJECT, project_yaml(staging=domain_body("App.Example.com")))
    write(repo, OTHER, project_yaml(staging=domain_body("app.example.com")))
    assert {p.file for p in check(repo)} == {PROJECT, OTHER}


@pytest.mark.parametrize(
    "first, second, clash",
    [
        (["port: 3000", "path: /api"], ["port: 3000"], False),
        (["port: 3000", "path: /api"], ["port: 3000", "path: /api"], True),
        (["port: 3000", "path: /"], ["port: 3000"], True),
    ],
    ids=["different-path", "same-path", "missing-path-is-root"],
)
def test_same_host_on_another_path_passes(repo, first, second, clash):
    """The same host passes on different paths, and a domain with no path is at /."""
    write(repo, PROJECT, project_yaml(staging=domain_body("app.example.com", first)))
    write(repo, OTHER, project_yaml(staging=domain_body("app.example.com", second)))
    assert bool(check(repo)) == clash


def test_template_and_guide_domains_are_not_compared(repo):
    """The template and the guide use example hosts, so a project on the same host passes."""
    write(repo, TEMPLATE, project_yaml(staging=domain_body("demo.example.com")))
    write(repo, PROJECT, project_yaml(staging=domain_body("demo.example.com")))
    assert check(repo) == []


def test_problems_across_files_all_reported(repo):
    """Problems in several files are all reported in one run."""
    write(repo, PROJECT, project_yaml(top="name: demo\n"))
    write(repo, "projects/other/project.yaml", project_yaml(top="name: other\n"))
    assert {p.file for p in check(repo)} == {PROJECT, "projects/other/project.yaml"}


def test_problem_line_points_at_offending_key(repo):
    """A problem's line is the line of the offending key."""
    write(repo, PROJECT, project_yaml(defaults="  secret: []\n"))
    assert [p.line for p in check(repo) if p.path == ".defaults.secret"] == [7]


def test_broken_guide_example_reported_at_guide_line(repo):
    """A guide example that breaks the schema fails at its line in the markdown."""
    write(repo, GUIDE, f"# project.yaml\n\nIntro.\n\n```yaml\n{project_yaml(defaults='  secret: []\n')}```\n")
    assert (GUIDE, 12) in {(p.file, p.line) for p in check(repo)}


def test_guide_reference_not_yaml_reported_at_guide_line(repo):
    """A reference example that isn't valid YAML fails at the parser's line, counted in the markdown."""
    write(repo, GUIDE, guide(("yaml", NOT_YAML)))
    assert [(p.file, p.line) for p in check(repo)] == [(GUIDE, 7)]


def test_guide_text_fence_is_not_checked(repo):
    """A guide block fenced as text, not yaml, isn't checked."""
    write(repo, GUIDE, guide(("yaml", FULL), ("text", project_yaml(top="name: x\n"))))
    assert check(repo) == []


def test_guide_without_reference_fails(repo):
    """A guide with no ```yaml reference example fails."""
    write(repo, GUIDE, guide(("text", FULL)))
    assert GUIDE in {p.file for p in check(repo)}


def test_guide_with_two_references_fails(repo):
    """A guide with more than one ```yaml reference example fails."""
    write(repo, GUIDE, guide(("yaml", FULL), ("yaml", FULL)))
    assert GUIDE in {p.file for p in check(repo)}


@pytest.mark.parametrize(
    "line, key",
    [
        ("image: ghcr.io/example/other\n", "image"),
        ("    env:\n      MODE: debug\n", "env"),
        ("        strip_path: true\n", "strip_path"),
    ],
    ids=["image", "environment-env", "strip_path"],
)
def test_reference_missing_key_is_named(repo, line, key):
    """A reference example that leaves out a key the schema allows fails, naming the key."""
    write(repo, GUIDE, guide(("yaml", FULL.replace(line, ""))))
    assert any(key in p.message for p in check(repo) if p.file == GUIDE)


@pytest.mark.parametrize(
    "filled, empty, path, key",
    [
        ("  env:\n    MODE: release\n", "  env: {}\n", ".defaults.env", "env"),
        ("  secrets:\n    - TOKEN\n", "  secrets: []\n", ".defaults.secrets", "secrets"),
        ("  shared:\n    - SHARED_TOKEN\n", "  shared: []\n", ".defaults.shared", "shared"),
        ("  volumes:\n    /data: data\n", "  volumes: {}\n", ".defaults.volumes", "volumes"),
    ],
    ids=["env", "secrets", "shared", "volumes"],
)
def test_reference_empty_map_or_list_is_named(repo, filled, empty, path, key):
    """A reference example that leaves env, secrets, shared or volumes empty fails, naming the key, so the guide shows an entry."""
    write(repo, GUIDE, guide(("yaml", FULL.replace(filled, empty))))
    assert key in message_at([p for p in check(repo) if p.file == GUIDE], path)


def test_reference_without_domain_entry_is_named(repo):
    """A reference example whose environments all leave domains empty fails, so the guide shows every domain key."""
    no_domains = FULL.split("    domains:\n")[0] + "    domains: {}\n  production:\n    domains: {}\n"
    write(repo, GUIDE, guide(("yaml", no_domains)))
    problems = [p for p in check(repo) if p.file == GUIDE]
    assert "domains" in message_at(problems, ".environments.staging.domains")


def test_excerpt_of_reference_passes(repo):
    """A ```yaml excerpt block that is consecutive lines of the reference, at any indentation, passes."""
    excerpt = "domains:\n  demo.example.com:\n    port: 3000\n"
    write(repo, GUIDE, guide(("yaml", FULL), ("yaml excerpt", excerpt)))
    assert check(repo) == []


def test_excerpt_not_in_reference_fails_at_its_fence(repo):
    """A ```yaml excerpt block that isn't consecutive lines of the reference fails at its opening fence's line."""
    write(repo, GUIDE, guide(("yaml", FULL), ("yaml excerpt", "port: 4000\n")))
    fence = 1 + 1 + 1 + FULL.count("\n") + 1 + 1 + 1
    assert [(p.file, p.line) for p in check(repo)] == [(GUIDE, fence)]


def test_unclosed_excerpt_fails_at_its_fence(repo):
    """A ```yaml excerpt block with no closing fence before the guide ends fails at its opening fence's line."""
    write(repo, GUIDE, guide(("yaml", FULL)) + "\n```yaml excerpt\nport: 4000\n")
    fence = 1 + 1 + 1 + FULL.count("\n") + 1 + 1 + 1
    assert [(p.file, p.line) for p in check(repo)] == [(GUIDE, fence)]


def test_template_breaking_schema_fails(repo):
    """A template that breaks the schema fails at the offending key."""
    write(repo, TEMPLATE, project_yaml(defaults="  secret: []\n"))
    assert [(p.file, p.path) for p in check(repo)] == [(TEMPLATE, ".defaults.secret")]


def test_empty_template_fails(repo):
    """An empty template fails the check."""
    write(repo, TEMPLATE, "")
    assert TEMPLATE in {p.file for p in check(repo)}


@pytest.mark.parametrize("rel", [GUIDE, TEMPLATE])
def test_missing_guide_or_template_is_a_problem(repo, rel):
    """Deleting the guide or the template fails the check instead of skipping it."""
    (repo / rel).unlink()
    assert rel in {p.file for p in check(repo)}


# Input the parser or the line lookup choke on


def test_merged_domain_key_is_a_problem_not_a_crash(repo):
    """An unknown key that comes in through a merge (<<: *anchor) has no line of its own: it's reported at the domain."""
    text = project_yaml(top="x: &d {port: 1, bogus: 2}\n", staging="\n    domains:\n      a.com: {<<: *d}\n")
    write(repo, PROJECT, text)
    problems = check(repo)
    bogus = [p for p in problems if p.path == '.environments.staging.domains["a.com"].bogus']
    assert [p.line for p in bogus] == [text.splitlines().index("      a.com: {<<: *d}") + 1]


@pytest.mark.parametrize("rel", [PROJECT, TEMPLATE], ids=["project", "template"])
def test_control_character_is_not_valid_yaml(repo, rel):
    """A control character is a not-valid-YAML Problem at its line, and the other files are still checked."""
    write(repo, rel, MINIMAL + "# \x07\n")
    write(repo, OTHER, project_yaml(top="name: other\n"))
    problems = check(repo)
    assert [(p.line, "not valid YAML" in p.message) for p in problems if p.file == rel] == [(MINIMAL.count("\n") + 1, True)]
    assert OTHER in {p.file for p in problems}


def test_control_character_in_guide_reference_is_not_valid_yaml(repo):
    """A control character in the guide's reference example is a not-valid-YAML Problem."""
    write(repo, GUIDE, guide(("yaml", FULL + "# \x07\n")))
    assert any("not valid YAML" in p.message for p in check(repo) if p.file == GUIDE)


@pytest.mark.parametrize("rel", [PROJECT, TEMPLATE, GUIDE], ids=["project", "template", "guide"])
def test_file_that_isnt_utf8_is_a_problem(repo, rel):
    """A byte that isn't UTF-8 is a Problem at its line, and the other files are still checked."""
    path = repo / rel
    path.write_bytes(path.read_bytes() + b"# caf\xe9\n")
    write(repo, OTHER, project_yaml(top="name: other\n"))
    problems = check(repo)
    lines = path.read_bytes().count(b"\n")
    assert [(p.line, "UTF-8" in p.message) for p in problems if p.file == rel] == [(lines, True)]
    assert OTHER in {p.file for p in problems}


def test_template_name_in_two_places_fails(repo):
    """The template gets the collision check too: every project copied from it would fail."""
    write(repo, TEMPLATE, MINIMAL.replace("  env: {}", "  env:\n    TOKEN: x").replace("  secrets: []", "  secrets: [TOKEN]"))
    assert [(p.file, p.path) for p in check(repo)] == [(TEMPLATE, ".defaults.env.TOKEN")]


# Command


def test_command_exits_zero_when_clean(repo):
    """The command exits 0 when nothing is wrong."""
    assert run_command(repo).returncode == 0


def test_command_prints_no_problems_when_clean(repo):
    """The command says so when nothing is wrong."""
    assert run_command(repo).stdout.splitlines() == ["no problems"]


def test_command_exits_one_on_problems(repo):
    """The command exits 1 when anything is wrong."""
    write(repo, PROJECT, project_yaml(defaults="  secret: []\n"))
    assert run_command(repo).returncode == 1


def test_command_prints_problem_count(repo):
    """The command ends with a count of problems and files."""
    write(repo, PROJECT, project_yaml(defaults="  secret: []\n"))
    assert run_command(repo).stdout.splitlines()[-1:] == ["1 problem in 1 file"]


def test_command_prints_plural_count(repo):
    """The count line uses plurals for more than one problem or file."""
    write(repo, PROJECT, project_yaml(defaults="  secret: []\n"))
    write(repo, "projects/other/project.yaml", project_yaml(top="name: other\n"))
    assert run_command(repo).stdout.splitlines()[-1:] == ["2 problems in 2 files"]


def test_command_prints_workflow_commands_in_ci(repo):
    """With GITHUB_ACTIONS=true each problem prints as a ::error workflow command."""
    write(repo, PROJECT, project_yaml(defaults="  secret: []\n"))
    out = run_command(repo, GITHUB_ACTIONS="true").stdout
    assert f"::error file={PROJECT},line=7::.defaults.secret: " in out


def test_command_escapes_workflow_commands_in_ci(repo):
    """With GITHUB_ACTIONS=true, %, CR and LF are escaped in the text, and , and : too in file=."""
    rel = "projects/a,b:c/project.yaml"
    write(repo, rel, project_yaml(top='"50%": x\n'))
    out = run_command(repo, GITHUB_ACTIONS="true").stdout
    assert '::error file=projects/a%2Cb%3Ac/project.yaml,line=2::["50%25"]: unknown key' in out


def test_command_omits_line_in_ci_when_problem_has_none(repo):
    """With GITHUB_ACTIONS=true a problem with no line prints without line=."""
    (repo / TEMPLATE).unlink()
    out = run_command(repo, GITHUB_ACTIONS="true").stdout
    assert f"::error file={TEMPLATE}::file is missing" in out.splitlines()


def test_command_prints_file_line_locally(repo):
    """Outside GitHub Actions each problem prints as <file>:<line>: <path>: <message>."""
    write(repo, PROJECT, project_yaml(defaults="  secret: []\n"))
    assert f"{PROJECT}:7: .defaults.secret: " in run_command(repo).stdout


def test_command_omits_line_locally_when_problem_has_none(repo):
    """Outside GitHub Actions a problem with no line prints as <file>: <message>."""
    (repo / TEMPLATE).unlink()
    assert f"{TEMPLATE}: file is missing" in run_command(repo).stdout.splitlines()


# This repo


GUIDE_AREAS = [
    "top level",
    "defaults",
    "env",
    "secrets",
    "shared secrets",
    "volumes",
    "environments",
    "domains",
]


def guide_sections():
    """The repo guide's ## headings, lowercased, each mapped to the lines under it up to the next ## heading."""
    path = REPO / GUIDE
    assert path.is_file(), f"{GUIDE} is missing"
    sections, current = {}, None
    for line in path.read_text().splitlines():
        if line.startswith("## "):
            current = line[3:].strip().lower()
            sections[current] = []
        elif current is not None:
            sections[current].append(line)
    return sections


def test_repo_passes_check():
    """This repo's projects, guide and template pass the check as committed."""
    assert check(REPO) == []


@pytest.mark.parametrize("area", GUIDE_AREAS)
def test_guide_has_section_per_area(area):
    """The guide has a ## section for each project.yaml area."""
    sections = guide_sections()
    assert area in sections, sorted(sections)


@pytest.mark.parametrize("area", GUIDE_AREAS)
def test_guide_section_shows_yaml(area):
    """Each area's section holds a yaml reference or excerpt."""
    assert any(line.strip().startswith("```yaml") for line in guide_sections().get(area, []))


def test_schema_domain_settings_match_module(repo):
    """The domain settings the check allows are exactly the ones terraform/modules/project lists."""
    variables = (REPO / "terraform/modules/project/variables.tf").read_text()
    module = re.search(r"unknown setting\. Allowed: ([a-z_, ]+)\.", variables).group(1).split(", ")
    write(repo, PROJECT, project_yaml(staging=staging_domain(["port: 3000", "bogus: 1"])))
    allowed = message_at(check(repo), f"{DOMAIN}.bogus").split("Allowed here: ")[1].split(", ")
    assert sorted(allowed) == sorted(module)
