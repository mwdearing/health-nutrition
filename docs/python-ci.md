# Python support and CI matrix

The catalog declares `requires-python = ">=3.12"`; Python 3.12 is its supported minimum and the version CI exercises. The committed `catalog/uv.lock` resolves the catalog and its test extra for supported Python/platform markers. CI installs that lock with uv 0.12.19 in frozen mode.

| Gate | Runner and Python | Database | What it checks |
| --- | --- | --- | --- |
| Catalog tests | `ubuntu-latest`, Python 3.12 | PostgreSQL 16 service | Lock consistency, frozen catalog/test-extra install, and the full catalog test suite including database-marked tests |
| Catalog frozen portability | `macos-latest`, Python 3.12 | None | Lock consistency and frozen install, non-database catalog tests, and the hash-locked Python CI tools in a separate virtual environment |
| Supabase SQL behavior | `ubuntu-latest` | Throwaway PostgreSQL 17 Alpine container | Migration and database behavior tests through `supabase/tests/run.sh` |

`scripts/ci-requirements.txt` is the hash-locked tools input for script tests. The macOS gate installs it with `--require-hashes` into a separate environment so the catalog lock and the script-tool lock are both exercised there. The Python 3.12 CI-tools lock is generated with universal wheel hashes; it does not add a second supported Python version claim.

The macOS job is the portability gate for frozen installation and non-database tests. Claim macOS validation only after that hosted job has completed successfully. PostgreSQL integration coverage stays on Linux; macOS does not start or contact a database service.
