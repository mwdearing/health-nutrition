"""The committed Supabase config must keep the hosted Auth settings the app depends on.

`supabase config push` applies the file to the live project at once, so a regenerated or edited file that
restores a local-development default would weaken the live project.
"""
import re
import tomllib
from pathlib import Path

CONFIG = Path(__file__).resolve().parents[2] / "supabase" / "config.toml"


def _config() -> dict:
    with CONFIG.open("rb") as handle:
        return tomllib.load(handle)


def test_anonymous_sign_ins_stay_off() -> None:
    assert _config()["auth"]["enable_anonymous_sign_ins"] is False


def test_email_sign_in_needs_confirmation_and_a_six_digit_code() -> None:
    email = _config()["auth"]["email"]
    assert email["enable_confirmations"] is True
    assert email["otp_length"] == 6


def test_apple_sign_in_stays_on_and_reads_its_values_from_the_environment() -> None:
    apple = _config()["auth"]["external"]["apple"]
    assert apple["enabled"] is True
    # The bundle identifier is kept out of this public file, like the secret.
    assert re.fullmatch(r"env\(SUPABASE_AUTH_EXTERNAL_APPLE_CLIENT_ID\)", apple["client_id"])
    assert re.fullmatch(r"env\(SUPABASE_AUTH_EXTERNAL_APPLE_SECRET\)", apple["secret"])


def test_mfa_totp_stays_as_hosted() -> None:
    totp = _config()["auth"]["mfa"]["totp"]
    assert totp["enroll_enabled"] is True and totp["verify_enabled"] is True


def test_no_bundle_identifier_or_key_is_committed() -> None:
    text = CONFIG.read_text(encoding="utf-8")
    assert "com.mwdearing" not in text
    assert not re.search(r"eyJ[A-Za-z0-9_-]{10,}|hash:[0-9a-f]{20,}", text)
