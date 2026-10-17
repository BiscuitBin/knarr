"""Selection must skip unrelated work without losing affected tests."""

import pytest

import checker_suite as suite


def test_every_module_has_exactly_one_owner():
    suite.validate()


@pytest.mark.parametrize(
    ("paths", "regressions", "runtime", "clusters"),
    [
        (["docs/reference/testing.md"], [], [], []),
        (["scripts/checks/coverage.py"], ["coverage"], [], []),
        (["scripts/checks/tests/test_validate_docs.py"], ["docs"], [], []),
        (["src/knarr/config.gleam"], [], ["controller-process"], ["kind"]),
        (["fixtures/fake_worker/src/server.gleam"], [], ["worker-process"], ["worker"]),
        (
            ["deploy/base/deployment.yaml"],
            ["chart", "cluster", "deployment"],
            [],
            ["kind", "kwok"],
        ),
        (["charts/knarr/templates/deployment.yaml"], ["chart", "release"], [], []),
    ],
)
def test_selection(paths, regressions, runtime, clusters):
    result = suite.select(paths)
    assert result["regressions"] == regressions
    assert result["runtime"] == runtime
    assert [name for name in suite.CLUSTERS if result[name]] == clusters


@pytest.mark.parametrize(
    "paths",
    [None, ["pixi.lock"], ["justfile"], ["new-script.sh"], ["scripts/checks/tests/conftest.py"]],
)
def test_unknown_and_shared_inputs_run_everything(paths):
    result = suite.select(paths)
    assert set(result["regressions"]) == set(suite.GROUPS) - suite.RUNTIME - {"policy"}
    assert set(result["runtime"]) == suite.RUNTIME
    assert all(result[name] for name in suite.CLUSTERS)


def test_missing_history_selects_everything():
    assert suite.changed_paths("0" * 40, "HEAD", False) is None


def test_deleted_and_renamed_paths_are_both_selected(monkeypatch):
    monkeypatch.setattr(suite.subprocess, "run", lambda *_a, **_kw: None)

    def output(command, **_kwargs):
        assert "--no-renames" in command
        assert "-z" in command
        return b"scripts/checks/coverage.py\0scripts/checks/validate_docs.py\0"

    monkeypatch.setattr(suite.subprocess, "check_output", output)
    paths = suite.changed_paths("base", "head", False)
    assert suite.select(paths)["regressions"] == ["coverage", "docs"]


def test_pull_requests_compare_from_the_merge_base(monkeypatch):
    monkeypatch.setattr(suite.subprocess, "run", lambda *_a, **_kw: None)

    def output(command, **_kwargs):
        if command[1] == "merge-base":
            return "ancestor\n"
        assert command[-3:] == ["ancestor", "head", "--"]
        return b"docs/README.md\0"

    monkeypatch.setattr(suite.subprocess, "check_output", output)
    assert suite.changed_paths("base", "head", True) == ["docs/README.md"]


@pytest.mark.parametrize(
    "unowned",
    [
        "scripts/checks/tests/test_unowned.py",
        "scripts/checks/tests/nested/test_unowned.py",
        "scripts/release/test_unowned.py",
        "scripts/release/unowned_test.py",
    ],
)
def test_unowned_test_module_fails(tmp_path, monkeypatch, unowned):
    monkeypatch.setattr(suite, "ROOT", tmp_path)
    tests = tmp_path / "scripts/checks/tests"
    tests.mkdir(parents=True)
    for path in suite.modules(set(suite.GROUPS)):
        (tmp_path / path).touch()
    extra = tmp_path / unowned
    extra.parent.mkdir(parents=True, exist_ok=True)
    extra.touch()
    with pytest.raises(ValueError, match="ownership mismatch"):
        suite.validate()


@pytest.mark.parametrize(
    ("path", "required"),
    [
        ("fixtures/fake_worker/Dockerfile", "packaging"),
        ("deploy/base/resources.json", "packaging"),
        ("fixtures/fake_worker/deploy/resources.json", "packaging"),
        (".scratch/bootstrap/evidence/01/tls/tls_check.escript", "packaging"),
        ("deploy/release/README.md", "release"),
        ("deploy/base/resources.json", "chart"),
        ("charts/knarr/values.schema.json", "chart"),
        # stamp-chart_test.sh stamps and packages the tracked chart.
        ("charts/knarr/values.yaml", "release"),
        ("src/knarr/application_ffi.erl", "chart"),
        ("scripts/checks/deployment.py", "chart"),
        ("deploy/base/resources.json", "cluster"),
        ("deploy/wrong-ca/kustomization.yaml", "cluster"),
        ("fixtures/fake_worker/deploy/resources.json", "cluster"),
        ("docs/specs/observability.allium", "cluster"),
        ("src/knarr/metrics_ffi.erl", "cluster"),
    ],
)
def test_changes_select_regressions_that_read_the_changed_file(path, required):
    assert required in suite.select([path])["regressions"]


def test_tls_runtime_probe_changes_select_the_image_smoke():
    assert suite.select([".scratch/bootstrap/evidence/01/tls/run.sh"])["kind"]
