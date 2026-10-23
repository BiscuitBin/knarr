"""The Helm chart under charts/knarr (Decision 0015), rendered with the pinned helm.

The install's invariants are asserted on the chart's default render after
kustomize has canonicalised it: kustomize sorts keys and drops helm's
`# Source:` comments, so the expected text is stable.
"""

import json
import os
import re
import subprocess
import sys
import tomllib

import pytest

import chart

ROOT = chart.ROOT
DIGEST = "sha256:" + "ab" * 32
# The chart follows gleam.toml (the lockstep test holds it), so a release bumps no test.
VERSION = tomllib.loads((ROOT / "gleam.toml").read_text())["version"]


def canonical(*arguments, namespace="default"):
    return chart.canonical(chart.render(*arguments, namespace=namespace))


@pytest.fixture(scope="module")
def default():
    return canonical()


def documents(text):
    return [document for document in text.split("---\n") if document.strip()]


def erl_flags(rendered):
    """The ERL_FLAGS value from helm's own render, which writes it as JSON."""
    after = rendered.split("name: ERL_FLAGS\n", 1)[1]
    return json.loads(re.match(r"\s*value: (.*)\n", after).group(1))


def installed_keys():
    """The install-wide keys application_ffi.erl reads, in its order."""
    source = (ROOT / "src/knarr/application_ffi.erl").read_text()
    return re.findall(r'\{<<"(\w+)">>, (?:text\()?application:get_env', source)


def schema():
    return json.loads((chart.CHART / "values.schema.json").read_text())


def test_the_chart_renders_the_four_resources_and_nothing_else(default):
    kinds = re.findall(r"^kind: (\S+)$", default, re.MULTILINE)
    assert kinds == ["ServiceAccount", "Role", "RoleBinding", "Deployment"]
    for absent in ("ClusterRole", "PodDisruptionBudget", "Service", "ServiceMonitor", "Lease"):
        assert f"kind: {absent}\n" not in default
    assert "coordination.k8s.io" not in default
    assert "replicaCount" not in (chart.CHART / "values.yaml").read_text()


def test_the_names_are_knarr_and_the_selector_is_the_name_label_alone(default):
    names = [
        re.search(r"^metadata:\n(?:  .*\n)*?  name: (\S+)$", document, re.MULTILINE).group(1)
        for document in documents(default)
    ]
    assert names == ["knarr"] * 4
    assert "  selector:\n    matchLabels:\n      app.kubernetes.io/name: knarr\n  strategy:\n" in (
        default
    )
    assert "serviceAccountName: knarr\n" in default


def test_the_role_grants_exactly_the_verbs_the_client_uses(default):
    assert (
        "rules:\n"
        '- apiGroups:\n  - ""\n  resources:\n  - pods\n  verbs:\n  - list\n  - patch\n'
        '- apiGroups:\n  - ""\n  resources:\n  - events\n  verbs:\n  - create\n'
        "- apiGroups:\n  - apps\n  resources:\n  - deployments\n  - replicasets\n"
        "  verbs:\n  - list\n---\n"
    ) in default
    assert (
        "roleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: Role\n  name: knarr\n"
        "subjects:\n- kind: ServiceAccount\n  name: knarr\n  namespace: default\n---\n"
    ) in default


def test_one_replica_under_recreate(default):
    assert "spec:\n  replicas: 1\n" in default
    assert "  strategy:\n    type: Recreate\n" in default


def test_the_token_is_projected_with_the_shortest_expiry_and_read_only(default):
    # Automount stays off at both levels: the projected volume is the only token.
    service_account = documents(default)[0]
    assert service_account.startswith("apiVersion: v1\nautomountServiceAccountToken: false\n")
    assert "kind: ServiceAccount\n" in service_account
    deployment = next(d for d in documents(default) if "\nkind: Deployment\n" in d)
    assert "      automountServiceAccountToken: false\n" in deployment
    assert (
        "        - mountPath: /var/run/secrets/kubernetes.io/serviceaccount\n"
        "          name: kube-api-access\n          readOnly: true\n"
    ) in default
    assert (
        "      - name: kube-api-access\n        projected:\n          sources:\n"
        "          - serviceAccountToken:\n              expirationSeconds: 600\n"
        "              path: token\n"
        "          - configMap:\n              items:\n              - key: ca.crt\n"
        "                path: ca.crt\n              name: kube-root-ca.crt\n"
        "          - downwardAPI:\n              items:\n              - fieldRef:\n"
        "                  fieldPath: metadata.namespace\n                path: namespace\n"
    ) in default


def test_erl_flags_is_exactly_discovery_by_default(default):
    assert (
        "      - env:\n        - name: ERL_FLAGS\n          value: -knarr discovery true\n"
        "        image: knarr:local\n        imagePullPolicy: Never\n"
    ) in default
    assert erl_flags(chart.render()) == "-knarr discovery true"


def test_the_security_contexts_hold(default):
    assert (
        "        securityContext:\n          allowPrivilegeEscalation: false\n"
        "          capabilities:\n            drop:\n            - ALL\n"
        "          readOnlyRootFilesystem: true\n"
    ) in default
    assert (
        "      securityContext:\n        runAsGroup: 10001\n        runAsNonRoot: true\n"
        "        runAsUser: 10001\n        seccompProfile:\n          type: RuntimeDefault\n"
    ) in default


def test_the_probes_are_readyz_and_healthz(default):
    assert (
        "        livenessProbe:\n          httpGet:\n            path: /healthz\n"
        "            port: http\n"
    ) in default
    assert (
        "        readinessProbe:\n          httpGet:\n            path: /readyz\n"
        "            port: http\n"
    ) in default


def test_the_wrong_ca_patch_only_redirects_the_ca_file():
    # Ticket 14's wrong-CA case: an env var, its mount and its ConfigMap, nothing else.
    patch = json.loads((ROOT / "fixtures/wrong-ca/patch.json").read_text())
    assert set(patch) == {"apiVersion", "kind", "metadata", "spec"}
    assert set(patch["spec"]) == {"template"}
    assert set(patch["spec"]["template"]) == {"spec"}
    pod = patch["spec"]["template"]["spec"]
    assert set(pod) == {"containers", "volumes"}
    assert [set(container) for container in pod["containers"]] == [{"name", "env", "volumeMounts"}]
    assert pod["containers"][0]["env"] == [
        {"name": "KNARR_CA_FILE", "value": "/etc/knarr/wrong-ca/ca.crt"}
    ]
    assert pod["containers"][0]["volumeMounts"] == [
        {"name": "wrong-ca", "mountPath": "/etc/knarr/wrong-ca", "readOnly": True}
    ]
    assert pod["volumes"] == [{"name": "wrong-ca", "configMap": {"name": "knarr-wrong-ca"}}]


def test_several_knarr_values_keep_discovery_first():
    rendered = chart.render(
        "--set",
        "knarr.log_level=debug",
        "--set",
        "knarr.poll_interval=5",
        "--set",
        "knarr.thresholds={300,900}",
        "--set-string",
        "knarr.status_path=/x",
    )
    assert erl_flags(rendered) == (
        "-knarr discovery true -knarr status_path '\"/x\"' -knarr thresholds [300,900]"
        " -knarr poll_interval 5 -knarr log_level '\"debug\"'"
    )


def test_every_knarr_value_renders_in_application_ffi_order(tmp_path):
    keys = installed_keys()
    assert len(keys) == 18
    values = tmp_path / "values.yaml"
    values.write_text(
        "knarr:\n"
        + "".join(
            f"  {key}: "
            + {
                "status_path": '"/s"',
                "log_level": "warning",
                "thresholds": "[300, 2147483647]",
            }.get(key, "2147483647")
            + "\n"
            for key in keys
        )
    )
    flags = erl_flags(chart.render("-f", str(values)))
    assert re.findall(r"-knarr (\w+)", flags) == ["discovery", *keys]
    # A values file's numbers reach helm as floats; none renders as 2.147483647e+09.
    assert "-knarr thresholds [300,2147483647] " in flags
    assert "-knarr patch_burst 2147483647 " in flags
    assert flags.endswith(" -knarr log_level '\"warning\"'")


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("status_path", "/it's"),
        ("status_path", '/say"hi'),
        ("log_level", "in\\fo"),
    ],
    ids=["a single quote", "a double quote", "a backslash"],
)
def test_a_string_erl_flags_cannot_quote_is_refused_naming_the_key(tmp_path, key, value):
    # ERL_FLAGS wraps a string as '"..."' with no escape, so one of these
    # characters would end the token and run later flags into the value.
    values = tmp_path / "values.yaml"
    values.write_text(f"knarr:\n  {key}: {json.dumps(value)}\n")
    with pytest.raises(subprocess.CalledProcessError) as failure:
        chart.render("-f", str(values))
    assert f"knarr.{key}" in failure.value.stderr


def test_the_schema_is_0015s_surface_no_more_and_no_less():
    document = schema()
    assert document["additionalProperties"] is False
    assert set(document["properties"]) == {
        "image",
        "knarr",
        "resources",
        "nodeSelector",
        "tolerations",
        "affinity",
        "priorityClassName",
        "podAnnotations",
        "podLabels",
    }
    image = document["properties"]["image"]
    assert image["additionalProperties"] is False
    assert set(image["properties"]) == {"repository", "tag", "digest", "pullPolicy", "pullSecrets"}
    settings = document["properties"]["knarr"]
    assert settings["additionalProperties"] is False
    assert list(settings["properties"]) == installed_keys()
    values = (chart.CHART / "values.yaml").read_text()
    assert set(re.findall(r"^(\w+):", values, re.MULTILINE)) == set(document["properties"])


def test_the_schema_checks_types_only():
    """Decision 0015: knarr's startup refusal is the one range check."""
    text = json.dumps(schema())
    for word in ("minimum", "maximum", "enum", "pattern", "minItems", "maxLength"):
        assert word not in text


def test_the_open_maps_take_string_values_under_any_key():
    for name in ("podAnnotations", "podLabels", "nodeSelector"):
        assert schema()["properties"][name] == {
            "type": "object",
            "additionalProperties": {"type": "string"},
        }


@pytest.mark.parametrize(
    ("arguments", "message"),
    [
        (["--set", "replicaCount=2"], "replicaCount"),
        (["--set", "knarr.pollInterval=5"], "pollInterval"),
        (["--set", "image.registry=example.com"], "registry"),
        (["--set", "knarr.poll_interval=five"], "poll_interval"),
        (["--set", "podLabels.team=1"], "team"),
    ],
    ids=["top level", "the knarr settings", "image", "a wrong type", "a non-string label"],
)
def test_an_unknown_key_or_a_wrong_type_is_rejected(arguments, message):
    with pytest.raises(subprocess.CalledProcessError) as failure:
        chart.render(*arguments)
    assert message in failure.value.stderr


def test_an_arbitrary_annotation_key_renders():
    rendered = canonical("--set-string", "podAnnotations.knarr\\.dev/local-image-id=x")
    assert "    metadata:\n      annotations:\n        knarr.dev/local-image-id: x\n" in rendered


def test_pod_labels_join_the_template_but_never_the_selector():
    rendered = canonical(
        "--set-string",
        "podLabels.team=a",
        "--set-string",
        "podLabels.app\\.kubernetes\\.io/name=b",
    )
    assert "        team: a\n" in rendered
    assert "app.kubernetes.io/name: b" not in rendered
    assert "    matchLabels:\n      app.kubernetes.io/name: knarr\n  strategy:\n" in rendered


@pytest.mark.parametrize(
    "key",
    [
        "podLabels",
        "podAnnotations",
        "nodeSelector",
        "tolerations",
        "affinity",
        "resources",
        "image.pullSecrets",
    ],
)
def test_an_optional_value_set_to_null_renders(key):
    # Helm's documented way to drop a chart default is `--set <key>=null`.
    rendered = canonical("--set", f"{key}=null")
    labels = "    metadata:\n      labels:\n        app.kubernetes.io/instance: knarr\n"
    assert labels in rendered
    assert "        app.kubernetes.io/name: knarr\n" in rendered.split(labels, 1)[1]


@pytest.mark.parametrize(
    ("arguments", "image"),
    [
        ([], "knarr:local"),
        (["--set", "image.tag=null"], f"knarr:{VERSION}"),
        (["--set", "image.tag=1.2.3"], "knarr:1.2.3"),
        (["--set", f"image.digest={DIGEST}"], f"knarr@{DIGEST}"),
        (
            [
                "--set",
                "image.repository=ghcr.io/biscuitbin/knarr",
                "--set",
                f"image.digest={DIGEST}",
            ],
            f"ghcr.io/biscuitbin/knarr@{DIGEST}",
        ),
    ],
    ids=["local", "appVersion", "a tag", "a digest", "the published image"],
)
def test_the_image_is_the_digest_else_the_tag_else_app_version(arguments, image):
    assert f"        image: {image}\n" in canonical(*arguments)


def test_every_scheduling_and_metadata_value_renders_and_validates():
    values = chart.CHART / "ci/every-value.yaml"
    rendered = chart.render("-f", str(values))
    chart.validate(rendered)
    text = chart.canonical(rendered)
    for line in (
        "      imagePullSecrets:\n      - name: registry\n",
        "      priorityClassName: system-cluster-critical\n",
        "      nodeSelector:\n        kubernetes.io/os: linux\n",
        "      tolerations:\n      - effect: NoSchedule\n",
        "      affinity:\n        nodeAffinity:\n",
        "            cpu: 100m\n",
        "        imagePullPolicy: IfNotPresent\n",
    ):
        assert line in text


def test_a_non_default_namespace_holds_every_resource_and_the_subject():
    rendered = canonical(namespace="other")
    assert re.findall(r"^\s*namespace: (\S+)$", rendered, re.MULTILINE) == ["other"] * 5
    assert "subjects:\n- kind: ServiceAccount\n  name: knarr\n  namespace: other\n" in rendered


def rendered_values(rendered, key):
    """Each value of `key` in helm's own render, read as JSON: a quoted string
    reads back as that string, a bare 123, true or null as a number, a boolean or
    None."""
    return [
        json.loads(value)
        for value in re.findall(rf"^\s*{re.escape(key)}: (.*)$", rendered, re.MULTILINE)
    ]


# Valid release names and namespaces, and a valid class name, that YAML reads as
# a number, a boolean (YAML 1.1's yes) or null unless the template quotes them.
UNTYPED = ["123", "true", "yes", "null"]


@pytest.mark.parametrize("name", UNTYPED)
def test_a_release_name_yaml_would_retype_stays_a_string_label(name):
    rendered = chart.render(release=name)
    chart.validate(rendered)
    # Four resources' metadata and the pod template, after its fromYaml round trip.
    assert rendered_values(rendered, "app.kubernetes.io/instance") == [name] * 5


@pytest.mark.parametrize("name", UNTYPED)
def test_a_namespace_yaml_would_retype_stays_a_string(name):
    rendered = chart.render(namespace=name)
    chart.validate(rendered)
    # Each resource's metadata and the RoleBinding's subject.
    assert rendered_values(rendered, "namespace") == [name] * 5


@pytest.mark.parametrize("name", UNTYPED)
def test_a_priority_class_name_yaml_would_retype_stays_a_string(name):
    rendered = chart.render("--set-string", f"priorityClassName={name}")
    chart.validate(rendered)
    assert rendered_values(rendered, "priorityClassName") == [name]


def test_the_labels_are_helms_recommended_set(default):
    assert (
        "metadata:\n  labels:\n    app.kubernetes.io/instance: knarr\n"
        "    app.kubernetes.io/managed-by: Helm\n    app.kubernetes.io/name: knarr\n"
        f"    app.kubernetes.io/version: {VERSION}\n    helm.sh/chart: knarr-{VERSION}\n"
        "  name: knarr\n"
    ) in default
    assert default.count(f"helm.sh/chart: knarr-{VERSION}\n") == 5


def test_notes_name_the_namespace_the_opt_in_label_and_the_install_guide():
    result = subprocess.run(
        ["helm", "install", "knarr", str(chart.CHART), "--dry-run=client", "--namespace", "other"],
        env={**os.environ, "KUBECONFIG": "/nonexistent"},
        capture_output=True,
        text=True,
        check=True,
    )
    notes = result.stdout.split("\nNOTES:\n", 1)[1]
    assert "namespace other" in notes
    assert "knarr.io/enabled=true" in notes
    assert f"https://github.com/biscuitbin/knarr/blob/v{VERSION}/docs/how-to/install.md" in notes


# The version lockstep.

CHART_YAML = 'apiVersion: v2\nname: knarr\nversion: 0.1.0\nappVersion: "0.1.0"\n'
GLEAM_TOML = 'name = "knarr"\nversion = "0.1.0"\n'


def test_the_committed_chart_is_in_lockstep_with_gleam_toml():
    assert (
        chart.version((chart.CHART / "Chart.yaml").read_text(), (ROOT / "gleam.toml").read_text())
        == VERSION
    )
    assert chart.version(CHART_YAML, GLEAM_TOML) == "0.1.0"


@pytest.mark.parametrize(
    "chart_yaml",
    [
        CHART_YAML.replace("version: 0.1.0", "version: 0.1.1"),
        CHART_YAML.replace('appVersion: "0.1.0"', 'appVersion: "0.2.0"'),
        CHART_YAML.replace('appVersion: "0.1.0"\n', ""),
    ],
    ids=["version", "appVersion", "no appVersion"],
)
def test_a_version_mismatch_fails(chart_yaml):
    with pytest.raises(ValueError, match=r"gleam\.toml"):
        chart.version(chart_yaml, GLEAM_TOML)


def test_a_failed_render_shows_helms_message(tmp_path, monkeypatch, capsys):
    values = tmp_path / "values.yaml"
    values.write_text("replicaCount: 2\n")
    monkeypatch.setattr(chart, "values_files", lambda: [values])
    with pytest.raises(SystemExit) as failure:
        chart.main(["render"])
    assert failure.value.code != 0
    assert "replicaCount" in capsys.readouterr().err


def test_the_checker_runs_every_check():
    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts/checks/chart.py")],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    for check in ("lint", "render", "version"):
        assert f"chart {check}: ok" in result.stdout


def test_the_e2e_fast_values_only_shorten_the_intervals():
    # The KEDA harness's comparison phase (ticket 33) installs the chart with these
    # values (helm-chart ticket 03). Rate and burst are not named, so they stay at
    # the defaults budget's 5·W + 10 bound is stated for.
    got = erl_flags(chart.render("--values", str(ROOT / "fixtures/chart-values/e2e-fast.yaml")))
    # Exactly the four intervals, each once, in application_ffi.erl's key order.
    assert got == (
        "-knarr discovery true -knarr poll_interval 5 -knarr poll_timeout 4"
        " -knarr patch_interval 10 -knarr list_interval 10"
    )


def test_a_patch_applies_in_any_namespace():
    # A patch file names no namespace; it still lands on its kind and name.
    rendered = chart.canonical(
        chart.render(namespace="other"), patches=[ROOT / "fixtures/wrong-ca/patch.json"]
    )
    assert (
        "        - name: KNARR_CA_FILE\n          value: /etc/knarr/wrong-ca/ca.crt\n" in rendered
    )
    assert (
        "      - configMap:\n          name: knarr-wrong-ca\n        name: wrong-ca\n" in rendered
    )
    assert re.findall(r"^\s*namespace: (\S+)$", rendered, re.MULTILINE) == ["other"] * 5


def test_annotations_mark_each_resource_and_never_the_pod_template():
    marks = {"meta.helm.sh/release-name": "knarr", "meta.helm.sh/release-namespace": "other"}
    rendered = chart.canonical(chart.render(namespace="other"), annotations=marks)
    block = (
        "metadata:\n  annotations:\n    meta.helm.sh/release-name: knarr\n"
        "    meta.helm.sh/release-namespace: other\n"
    )
    assert [document.count(block) for document in documents(rendered)] == [1, 1, 1, 1]
    assert rendered.count("meta.helm.sh/") == 8
