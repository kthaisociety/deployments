"""Acceptance tests for #15: the project.yaml schema, guide and check."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from check_project_yaml import check

REPO = Path(__file__).resolve().parent.parent
COMMAND = REPO / "scripts" / "check-project-yaml"
PROJECT = "projects/demo/project.yaml"
TEMPLATE = "templates/project.yaml"
GUIDE = "docs/project-yaml.md"

MINIMAL = """\
repo: example/demo
defaults:
  env: {}
  secrets: []
  shared: {}
  volumes: {}
environments:
  staging: {}
  production: {}
"""


def project_yaml(*, top="", defaults="", staging=" {}", production=" {}"):
    """MINIMAL with extra lines at the top level and under defaults, and each environment's body."""
    return (
        f"repo: example/demo\n{top}"
        "defaults:\n  env: {}\n  secrets: []\n  shared: {}\n  volumes: {}\n"
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
    """A root that passes: one minimal project, the template, and a guide with one example."""
    write(tmp_path, PROJECT, MINIMAL)
    write(tmp_path, TEMPLATE, MINIMAL)
    write(tmp_path, GUIDE, f"# project.yaml\n\n```yaml\n{MINIMAL}```\n")
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


def test_env_scalar_values_pass(repo):
    """env values may be strings, numbers or booleans, under defaults and under an environment."""
    write(
        repo,
        PROJECT,
        project_yaml(staging="\n    env:\n      MODE: release\n      PORT: 8080\n      DEBUG: true\n"),
    )
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
    [("secrets", " [A]"), ("shared", " {s: [A]}"), ("volumes", " {/data: data}")],
    ids=["secrets", "shared", "volumes"],
)
def test_per_environment_secrets_point_to_defaults_and_openbao(repo, key, body):
    """secrets, shared or volumes under an environment says: names under defaults, values in OpenBao."""
    write(repo, PROJECT, project_yaml(staging=f"\n    {key}:{body}\n"))
    message = message_at(check(repo), f".environments.staging.{key}")
    assert "defaults" in message and "OpenBao" in message


@pytest.mark.parametrize(
    "removed, path, name",
    [
        ("repo: example/demo\n", ".repo", "repo"),
        ("defaults:\n  env: {}\n  secrets: []\n  shared: {}\n  volumes: {}\n", ".defaults", "defaults"),
        ("  env: {}\n", ".defaults.env", "env"),
        ("  secrets: []\n", ".defaults.secrets", "secrets"),
        ("  shared: {}\n", ".defaults.shared", "shared"),
        ("  volumes: {}\n", ".defaults.volumes", "volumes"),
        ("environments:\n  staging: {}\n  production: {}\n", ".environments", "environments"),
        ("  staging: {}\n", ".environments.staging", "staging"),
        ("  production: {}\n", ".environments.production", "production"),
    ],
    ids=["repo", "defaults", "env", "secrets", "shared", "volumes", "environments", "staging", "production"],
)
def test_missing_skeleton_key_is_named(repo, removed, path, name):
    """A missing skeleton key fails at the path it should have, and the message names it."""
    write(repo, PROJECT, MINIMAL.replace(removed, ""))
    assert name in message_at(check(repo), path)


@pytest.mark.parametrize(
    "line, path, empty",
    [("  env: {}\n", ".defaults.env", "{}"), ("  secrets: []\n", ".defaults.secrets", "[]")],
    ids=["env", "secrets"],
)
def test_null_skeleton_key_says_write_empty(repo, line, path, empty):
    """A skeleton key left blank (null) says to write {} or [] when unused."""
    write(repo, PROJECT, MINIMAL.replace(line, line.split(":")[0] + ":\n"))
    assert empty in message_at(check(repo), path)


def test_domain_without_port_names_port(repo):
    """A domain without port fails, and the message names port."""
    write(repo, PROJECT, project_yaml(staging=staging_domain(["https: true"])))
    assert "port" in message_at(check(repo), f"{DOMAIN}.port")


def test_extra_environment_names_the_two_allowed(repo):
    """An environment other than staging or production fails, naming the two allowed."""
    write(repo, PROJECT, MINIMAL + "  dev: {}\n")
    message = message_at(check(repo), ".environments.dev")
    assert "staging" in message and "production" in message


# Values


def test_wrong_type_names_expected_type(repo):
    """port: "8080" fails, and the message names the expected type."""
    write(repo, PROJECT, project_yaml(staging=staging_domain(['port: "8080"'])))
    assert "integer" in message_at(check(repo), f"{DOMAIN}.port")


def test_env_non_scalar_value_fails(repo):
    """An env value that is a list fails."""
    write(repo, PROJECT, project_yaml(staging="\n    env:\n      HOSTS: [a, b]\n"))
    assert ".environments.staging.env.HOSTS" in paths(check(repo))


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


def test_invalid_yaml_reports_parser_line_and_reason(repo):
    """A file that isn't valid YAML gives one problem with no path, at the parser's line."""
    write(repo, PROJECT, "repo: example/demo\ndefaults:\n  env: {}\n\tsecrets: []\n")
    assert [(p.path, p.line) for p in check(repo) if p.file == PROJECT] == [(None, 4)]


def test_invalid_yaml_does_not_stop_other_files(repo):
    """A file that isn't valid YAML doesn't stop the other files being checked."""
    write(repo, PROJECT, "repo: [unclosed\n")
    write(repo, "projects/other/project.yaml", project_yaml(top="name: other\n"))
    assert "projects/other/project.yaml" in {p.file for p in check(repo)}


def test_duplicate_key_fails_with_its_line(repo):
    """A key written twice in one map fails at the second one's line."""
    write(repo, PROJECT, MINIMAL.replace("  env: {}\n", "  env: {}\n  env: {}\n"))
    assert 4 in {p.line for p in check(repo) if p.file == PROJECT}


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


def test_guide_text_fence_is_not_checked(repo):
    """A guide block fenced as text, not yaml, isn't checked."""
    write(
        repo,
        GUIDE,
        f"# project.yaml\n\n```yaml\n{MINIMAL}```\n\nNot this:\n\n```text\n{project_yaml(top='name: x\n')}```\n",
    )
    assert check(repo) == []


def test_empty_template_fails(repo):
    """An empty template fails the check."""
    write(repo, TEMPLATE, "")
    assert TEMPLATE in {p.file for p in check(repo)}


@pytest.mark.parametrize("rel", [GUIDE, TEMPLATE])
def test_missing_guide_or_template_is_a_problem(repo, rel):
    """Deleting the guide or the template fails the check instead of skipping it."""
    (repo / rel).unlink()
    assert rel in {p.file for p in check(repo)}


# Command


def test_command_exits_zero_when_clean(repo):
    """The command exits 0 when nothing is wrong."""
    assert run_command(repo).returncode == 0


def test_command_exits_one_on_problems(repo):
    """The command exits 1 when anything is wrong."""
    write(repo, PROJECT, project_yaml(defaults="  secret: []\n"))
    assert run_command(repo).returncode == 1


def test_command_prints_problem_count(repo):
    """The command ends with a count of problems and files."""
    write(repo, PROJECT, project_yaml(defaults="  secret: []\n"))
    assert run_command(repo).stdout.splitlines()[-1:] == ["1 problem in 1 file"]


def test_command_prints_workflow_commands_in_ci(repo):
    """With GITHUB_ACTIONS=true each problem prints as a ::error workflow command."""
    write(repo, PROJECT, project_yaml(defaults="  secret: []\n"))
    out = run_command(repo, GITHUB_ACTIONS="true").stdout
    assert f"::error file={PROJECT},line=7::.defaults.secret: " in out


def test_command_prints_file_line_locally(repo):
    """Outside GitHub Actions each problem prints as <file>:<line>: <path>: <message>."""
    write(repo, PROJECT, project_yaml(defaults="  secret: []\n"))
    assert f"{PROJECT}:7: .defaults.secret: " in run_command(repo).stdout
