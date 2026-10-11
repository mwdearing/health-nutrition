from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = (
    ".github/workflows/catalog.yml",
    ".github/workflows/ios.yml",
    ".github/workflows/swift-lint.yml",
    ".github/workflows/docs-consistency.yml",
    ".github/workflows/design-system-tests.yml",
)
SETUP_UV = "astral-sh/setup-uv@1c37ad07a6a961277cf70c0d37d6f313000f5884 # v10.3.0"


def workflow(path: str) -> str:
    return (ROOT / path).read_text()


def test_catalog_ci_installs_the_frozen_test_lock():
    text = workflow(WORKFLOWS[0])
    assert SETUP_UV in text
    assert re.search(r"version:\s*['\"]?0\.12\.19", text)
    assert "uv sync --frozen --extra test" in text
    assert "pip install" not in text
    assert '"catalog/uv.lock"' in text or '"catalog/**"' in text


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
