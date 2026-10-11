from pathlib import Path
import re
import tomllib


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = (
    ".github/workflows/catalog.yml",
    ".github/workflows/ios.yml",
    ".github/workflows/swift-lint.yml",
    ".github/workflows/docs-consistency.yml",
    ".github/workflows/design-system-tests.yml",
)
SETUP_UV = "astral-sh/setup-uv@1c37ad07a6a961277cf70c0d37d6f313000f5884 # v10.3.0"
XCODEGEN_SCRIPT = '.github/scripts/install-xcodegen.sh'
XCODEGEN_WORKFLOWS = (
    ".github/workflows/ios.yml",
    ".github/workflows/screenshots.yml",
    ".github/workflows/signed-beta.yml",
)
POSTGRES_16_DIGEST = "ca0bd484cb98bf4b24eb1010e73fb3fcbd6714d240fbc1a10eea5b7dbecb641d"
POSTGRES_17_ALPINE_DIGEST = "b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24"


def workflow(path: str) -> str:
    return (ROOT / path).read_text()


def test_catalog_ci_installs_the_frozen_test_lock():
    text = workflow(WORKFLOWS[0])
    assert SETUP_UV in text
    assert re.search(r"version:\s*['\"]?0\.12\.19", text)
    assert "uv sync --frozen --extra test" in text
    assert "uv run --frozen python -m pytest -q tests ../scripts/tests/test_dependency_workflow_locks.py" in text
    assert "pip install" not in text
    assert '"catalog/uv.lock"' in text or '"catalog/**"' in text


def test_catalog_build_backend_is_hash_locked():
    project = tomllib.loads((ROOT / "catalog/pyproject.toml").read_text())
    assert project["build-system"]["requires"] == ["setuptools>=68"]

    constraints = project["tool"]["uv"]["build-constraint-dependencies"]
    assert constraints == [
        {
            "requirement": "setuptools==84.0.0",
            "hashes": [
                "sha256:51a52592b3b99e102b609654876bd65f19f999935166d1352678931132b0c670",
                "sha256:f4695c21257f0d9b537ec2692c941d02ee143b7cc1276941349a546573b2ef73",
            ],
        }
    ]

    lock = tomllib.loads((ROOT / "catalog/uv.lock").read_text())
    assert lock["manifest"]["build-constraints"] == [
        {
            "name": "setuptools",
            "specifier": "==84.0.0",
            "hashes": constraints[0]["hashes"],
        }
    ]


def test_script_workflows_use_one_hash_locked_requirements_file():
    for path in WORKFLOWS[1:]:
        text = workflow(path)
        assert SETUP_UV in text, path
        assert "uv pip sync" in text, path
        assert "--require-hashes" in text, path
        assert "scripts/ci-requirements.txt" in text, path
        assert "pip install" not in text, path
        assert '"scripts/ci-requirements.in"' in text, path
        assert '"scripts/ci-requirements.txt"' in text, path


def test_ci_requirements_are_hash_locked_for_pytest_and_pyyaml():
    requirements = (ROOT / "scripts/ci-requirements.txt").read_text()
    assert re.search(r"(?m)^pytest==[^\s]+", requirements)
    assert re.search(r"(?m)^pyyaml==[^\s]+", requirements)
    assert requirements.count("--hash=sha256:") >= 2


def test_all_script_workflows_trigger_on_the_guard_test():
    assert '"scripts/tests/test_dependency_workflow_locks.py"' in workflow(WORKFLOWS[2])


def test_all_app_workflows_reuse_the_checksum_verified_xcodegen_bootstrap():
    installer = ROOT / XCODEGEN_SCRIPT
    text = installer.read_text()
    assert 'XCODEGEN_VERSION="2.46.0"' in text
    assert 'XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"' in text
    assert "releases/download/$XCODEGEN_VERSION/xcodegen.zip" in text
    assert "shasum -a 256 -c -" in text
    assert text.index("shasum -a 256 -c -") < text.index("unzip -q")

    for path in XCODEGEN_WORKFLOWS:
        workflow_text = workflow(path)
        assert XCODEGEN_SCRIPT in workflow_text, path
        assert "brew install xcodegen" not in workflow_text, path
        assert 'xcodegen-dist/xcodegen/bin/xcodegen' in workflow_text, path


def test_postgres_ci_images_keep_their_major_version_and_pin_the_verified_index_digest():
    catalog = workflow(".github/workflows/catalog.yml")
    sql_runner = (ROOT / "supabase/tests/run.sh").read_text()

    assert f"docker.io/library/postgres:16@sha256:{POSTGRES_16_DIGEST}" in catalog
    assert f"docker.io/library/postgres:17-alpine@sha256:{POSTGRES_17_ALPINE_DIGEST}" in sql_runner


def test_catalog_workflow_runs_the_tool_and_image_pin_guards_when_they_change():
    catalog = workflow(".github/workflows/catalog.yml")
    for path in (
        '"scripts/tests/test_dependency_workflow_locks.py"',
        '"supabase/tests/run.sh"',
    ):
        assert path in catalog


def test_ios_and_swift_lint_run_the_pin_guards_when_bootstrap_workflows_change():
    ios = workflow(".github/workflows/ios.yml")
    swift_lint = workflow(".github/workflows/swift-lint.yml")
    for workflow_text in (ios, swift_lint):
        assert '".github/scripts/install-xcodegen.sh"' in workflow_text
        assert '".github/workflows/screenshots.yml"' in workflow_text
        assert '".github/workflows/signed-beta.yml"' in workflow_text
        assert "scripts/tests/test_dependency_workflow_locks.py" in workflow_text
