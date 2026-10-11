"""Guard the checked-in Auth intent and its documented limits.

These checks read only the committed TOML. They do not inspect or attest the hosted project's settings.
"""
import re
from pathlib import Path

import tomllib

CONFIG = Path(__file__).resolve().parents[2] / "supabase" / "config.toml"
README = CONFIG.with_name("README.md")


def _config() -> dict:
    with CONFIG.open("rb") as handle:
        return tomllib.load(handle)


def test_checked_in_auth_intent_keeps_anonymous_sign_ins_off() -> None:
    assert _config()["auth"]["enable_anonymous_sign_ins"] is False


def test_checked_in_email_auth_intent_requires_confirmation_and_six_digit_codes() -> None:
    email = _config()["auth"]["email"]
    assert email["enable_confirmations"] is True
    assert email["otp_length"] == 6


def test_checked_in_apple_auth_intent_is_enabled_and_uses_environment_values() -> None:
    apple = _config()["auth"]["external"]["apple"]
    assert apple["enabled"] is True
    # The bundle identifier is kept out of this public file, like the secret.
    assert re.fullmatch(r"env\(SUPABASE_AUTH_EXTERNAL_APPLE_CLIENT_ID\)", apple["client_id"])
    assert re.fullmatch(r"env\(SUPABASE_AUTH_EXTERNAL_APPLE_SECRET\)", apple["secret"])


def test_checked_in_totp_settings_are_enabled() -> None:
    totp = _config()["auth"]["mfa"]["totp"]
    assert totp["enroll_enabled"] is True and totp["verify_enabled"] is True


def test_no_bundle_identifier_or_key_is_committed() -> None:
    text = CONFIG.read_text(encoding="utf-8")
    assert "com.mwdearing" not in text
    assert not re.search(r"eyJ[A-Za-z0-9_-]{10,}|hash:[0-9a-f]{20,}", text)


def test_readme_distinguishes_repository_intent_from_hosted_evidence() -> None:
    text = README.read_text(encoding="utf-8").lower()
    assert "does not prove" in text or "does not establish" in text
    assert "hosted" in text and "unknown" in text


def test_readme_warns_config_push_is_live_and_not_a_preview() -> None:
    text = README.read_text(encoding="utf-8").lower()
    assert "applies" in text and "immediately" in text
    assert "preview" in text


def test_comment_only_captcha_block_is_not_treated_as_hosted_enforcement() -> None:
    # TOML ignores the commented [auth.captcha] template; only a separate hosted read can
    # establish whether CAPTCHA is required by the live Auth service.
    assert "captcha" not in _config()["auth"]
    text = README.read_text(encoding="utf-8").lower()
    assert "commented" in text and "captcha" in text and "hosted" in text
