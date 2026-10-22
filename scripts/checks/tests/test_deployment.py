"""The vendored Kubernetes schemas kubeconform validates against."""

import json
import shutil

import pytest

import deployment


def test_vendored_schemas_are_plain_upstream_json():
    provenance = json.loads((deployment.SCHEMAS / "sources.json").read_text())
    for name, hashes in provenance["files"].items():
        assert set(hashes) == {"sha256"}
        json.loads((deployment.SCHEMAS / name).read_text())
    deployment.verify()


def test_changed_schema_is_refused(tmp_path):
    shutil.copytree(deployment.SCHEMAS, tmp_path, dirs_exist_ok=True)
    with (tmp_path / "role-rbac-v1.json").open("ab") as schema:
        schema.write(b" ")
    with pytest.raises(ValueError, match=r"role-rbac-v1\.json"):
        deployment.verify(tmp_path)
