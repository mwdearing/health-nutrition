import os

import psycopg
import pytest


@pytest.mark.db
def test_select_one():
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        assert conn.execute("SELECT 1").fetchone() == (1,)
