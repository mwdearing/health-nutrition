#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This synthetic keychain test requires macOS." >&2
  exit 2
fi
[[ -n "${RUNNER_TEMP:-}" ]] || { echo "RUNNER_TEMP is required." >&2; exit 2; }
[[ $# -eq 1 && -x "$1" ]] || { echo "Pass the compiled signing identity import helper." >&2; exit 2; }

umask 077
HELPER="$1"
WORK="$(mktemp -d "$RUNNER_TEMP/signing-import.XXXXXXXX")"
KEYCHAIN="$WORK/synthetic.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
SYNTHETIC_PASSWORD="pr12-synthetic-passphrase"
WRONG_PASSWORD="pr12-wrong-synthetic-passphrase"
KEYCHAIN_CREATED=0
TRUST_ADDED=0

cleanup() {
  local failed=0
  if [[ "$TRUST_ADDED" -eq 1 ]]; then
    if security remove-trusted-cert "$WORK/root.crt" >"$WORK/keychain.log" 2>&1; then
      TRUST_ADDED=0
    else
      echo "Could not remove the synthetic certificate from user Trust Settings." >&2
      failed=1
    fi
  fi
  if [[ "$KEYCHAIN_CREATED" -eq 1 ]]; then
    if security delete-keychain "$KEYCHAIN" >/dev/null 2>&1; then
      KEYCHAIN_CREATED=0
    else
      echo "Could not delete the synthetic keychain." >&2
      failed=1
    fi
  fi
  if [[ "$failed" -eq 0 ]]; then
    case "$WORK" in
      "$RUNNER_TEMP"/signing-import.*)
        if ! rm -rf -- "$WORK"; then
          echo "Could not remove the synthetic signing test files." >&2
          failed=1
        fi
        ;;
      *)
        echo "Refusing to remove an unexpected synthetic test path." >&2
        failed=1
        ;;
    esac
  fi
  if [[ "$failed" -ne 0 ]]; then
    echo "Synthetic signing cleanup failed; remaining files were retained for recovery." >&2
    return 1
  fi
}
finish() {
  local status=$?
  trap - EXIT INT TERM
  if ! cleanup; then
    status=1
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

openssl genrsa -out "$WORK/root.key" 2048 >"$WORK/openssl.log" 2>&1 || {
  echo "Could not create the synthetic root key." >&2
  exit 1
}
openssl req -new -x509 -key "$WORK/root.key" -sha256 -days 1 \
  -subj "/CN=PR12 Synthetic Test Root" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -out "$WORK/root.crt" >"$WORK/openssl.log" 2>&1 || {
  echo "Could not create the synthetic test root." >&2
  exit 1
}
openssl genrsa -out "$WORK/synthetic.key" 2048 >"$WORK/openssl.log" 2>&1 || {
  echo "Could not create the synthetic signing key." >&2
  exit 1
}
openssl req -new -key "$WORK/synthetic.key" -sha256 \
  -subj "/CN=PR12 Synthetic Code Signing" \
  -out "$WORK/synthetic.csr" >"$WORK/openssl.log" 2>&1 || {
  echo "Could not create the synthetic signing request." >&2
  exit 1
}
cat >"$WORK/signing-extensions.cnf" <<'CNF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
CNF
openssl x509 -req -in "$WORK/synthetic.csr" -CA "$WORK/root.crt" -CAkey "$WORK/root.key" \
  -CAcreateserial -sha256 -days 1 -extfile "$WORK/signing-extensions.cnf" \
  -out "$WORK/synthetic.crt" >"$WORK/openssl.log" 2>&1 || {
  echo "Could not issue the synthetic signing certificate." >&2
  exit 1
}
SYNTHETIC_PASSWORD="$SYNTHETIC_PASSWORD" openssl pkcs12 -export \
  -inkey "$WORK/synthetic.key" -in "$WORK/synthetic.crt" -certfile "$WORK/root.crt" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout env:SYNTHETIC_PASSWORD -out "$WORK/synthetic.p12" \
  >"$WORK/openssl.log" 2>&1 || {
  echo "Could not package the synthetic identity." >&2
  exit 1
}

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >"$WORK/keychain.log" 2>&1 || {
  echo "Could not create the synthetic keychain." >&2
  exit 1
}
KEYCHAIN_CREATED=1
security set-keychain-settings -lut 21600 "$KEYCHAIN" >"$WORK/keychain.log" 2>&1
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >"$WORK/keychain.log" 2>&1
security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$WORK/root.crt" \
  >"$WORK/keychain.log" 2>&1 || {
  echo "Could not trust the synthetic certificate in its temporary keychain." >&2
  exit 1
}
TRUST_ADDED=1

cat >"$WORK/helper-wrapper.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$SYNTHETIC_ARGV_CAPTURE"
exec "$SYNTHETIC_REAL_HELPER" "$@"
SH
chmod 700 "$WORK/helper-wrapper.sh"
printf '%s\n' "$WORK/synthetic.p12" "$KEYCHAIN" >"$WORK/expected-argv.txt"

if ! SIGNING_CERT_PASSWORD="$SYNTHETIC_PASSWORD" \
  SYNTHETIC_REAL_HELPER="$HELPER" SYNTHETIC_ARGV_CAPTURE="$WORK/helper-argv.txt" \
  "$WORK/helper-wrapper.sh" "$WORK/synthetic.p12" "$KEYCHAIN" \
  >"$WORK/import.log" 2>&1; then
  echo "The helper rejected the synthetic P12." >&2
  exit 1
fi
cmp -s "$WORK/expected-argv.txt" "$WORK/helper-argv.txt" || {
  echo "The helper received arguments other than the two file paths." >&2
  exit 1
}
if grep -F -- "$SYNTHETIC_PASSWORD" "$WORK/helper-argv.txt" "$WORK/import.log" >/dev/null; then
  echo "The synthetic P12 password appeared in helper arguments or output." >&2
  exit 1
fi

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" \
  >"$WORK/keychain.log" 2>&1 || {
  echo "Could not allow codesign to use the synthetic identity." >&2
  exit 1
}
security find-identity -v -p codesigning "$KEYCHAIN" >"$WORK/identities.log" 2>&1 || {
  echo "Could not inspect the synthetic signing identity." >&2
  exit 1
}
IDENTITY="$(sed -nE 's/^[[:space:]]*[0-9]+\) ([0-9A-F]{40}) .*/\1/p' "$WORK/identities.log" | head -n 1)"
[[ -n "$IDENTITY" ]] || { echo "The imported identity is not usable for code signing." >&2; exit 1; }
grep -q "PR12 Synthetic Code Signing" "$WORK/identities.log" || {
  echo "The imported identity does not match the generated certificate." >&2
  exit 1
}

cat >"$WORK/probe.c" <<'C'
int main(void) { return 0; }
C
clang "$WORK/probe.c" -o "$WORK/probe" >"$WORK/clang.log" 2>&1 || {
  echo "Could not build the synthetic code-signing probe." >&2
  exit 1
}
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none \
  --identifier com.example.pr12synthetic "$WORK/probe" >"$WORK/codesign.log" 2>&1 || {
  echo "codesign could not use the imported synthetic identity." >&2
  exit 1
}
codesign --verify --strict "$WORK/probe" >"$WORK/codesign.log" 2>&1 || {
  echo "The synthetic probe did not verify after signing." >&2
  exit 1
}

if SIGNING_CERT_PASSWORD="$WRONG_PASSWORD" \
  SYNTHETIC_REAL_HELPER="$HELPER" SYNTHETIC_ARGV_CAPTURE="$WORK/helper-argv.txt" \
  "$WORK/helper-wrapper.sh" "$WORK/synthetic.p12" "$KEYCHAIN" \
  >"$WORK/wrong-password.log" 2>&1; then
  echo "The helper unexpectedly accepted the wrong synthetic password." >&2
  exit 1
fi
cmp -s "$WORK/expected-argv.txt" "$WORK/helper-argv.txt" || {
  echo "The wrong-password attempt passed arguments other than the two file paths." >&2
  exit 1
}
if grep -F -- "$WRONG_PASSWORD" "$WORK/helper-argv.txt" "$WORK/wrong-password.log" >/dev/null; then
  echo "The wrong synthetic password appeared in helper arguments or output." >&2
  exit 1
fi
security find-identity -v -p codesigning "$KEYCHAIN" >"$WORK/identities.log" 2>&1 || {
  echo "Could not recheck the synthetic identity after wrong-password rejection." >&2
  exit 1
}
[[ "$(grep -c 'PR12 Synthetic Code Signing' "$WORK/identities.log")" -eq 1 ]] || {
  echo "The wrong-password attempt changed the synthetic keychain." >&2
  exit 1
}

if ! cleanup; then
  exit 1
fi
trap - EXIT INT TERM
[[ ! -e "$WORK" && ! -e "$KEYCHAIN" ]] || {
  echo "The synthetic keychain or test files were not removed." >&2
  exit 1
}
echo "PASS: synthetic P12 import, restricted codesign use, wrong-password rejection, path-only argv, and cleanup."
