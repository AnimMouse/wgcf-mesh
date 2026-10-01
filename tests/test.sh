#!/usr/bin/env bash
# Offline tests for wgcf-mesh.sh, with curl replaced by tests/stub/curl.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PATH="$root/tests/stub:$PATH" STUB_LOG="$work/curl.log"
# A well-formed token with made-up values.
token=$(printf '{"a":"%s","t":"%s","s":"%s"}' 0123456789abcdef0123456789abcdef \
  11111111-2222-3333-4444-555555555555 c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MDA= | base64 | tr -d '\n')
conf=wgcf-mesh-t.00000000-0000-4000-8000-000000000001.conf
profile=wgcf-mesh-t.00000000-0000-4000-8000-000000000001.json
# The API token in tests/fixtures/register.json.
api_token=00000000-0000-4000-8000-000000000002
failures=0

# run <name> <expected exit code> [args...]: run the script in a clean directory.
run() {
  name=$1 expected=$2
  shift 2
  rm -rf "$work/out" && mkdir "$work/out" && : > "$STUB_LOG" && : > "$STUB_LOG.stdin"
  (cd "$work/out" && "$root/wgcf-mesh.sh" "$@" > "$work/stdout" 2> "$work/stderr" < "${STDIN:-/dev/null}")
  code=$?
  if [ "$code" -ne "$expected" ]; then
    fail "exit code $code, expected $expected"
  fi
}

fail() {
  echo "FAIL $name: $*"
  sed 's/^/  stderr: /' "$work/stderr"
  failures=$((failures + 1))
}

# expect_no_file and expect_deleted check what the last run left behind.
expect_no_file() {
  [ -z "$(ls -A "$work/out")" ] || fail "left files behind: $(ls -A "$work/out")"
}
expect_deleted() {
  grep -q '^DELETE .*/v1/accounts/0123456789abcdef0123456789abcdef/reg/t.00000000-0000-4000-8000-000000000001$' "$STUB_LOG" ||
    fail "registration was not deleted"
}
expect_not_deleted() {
  ! grep -q '^DELETE' "$STUB_LOG" || fail "registration was deleted"
}

run "usage" 2
expect_no_file

run "invalid token" 1 eyJhIjoiaW52YWxpZCJ9
expect_no_file
[ ! -s "$STUB_LOG" ] || fail "called the API"

run "success" 0 "$token"
if [ -f "$work/out/$conf" ]; then
  private_key=$(sed -n 's/^PrivateKey = //p' "$work/out/$conf")
  [[ $private_key =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$ ]] || fail "PrivateKey is not a WireGuard key"
  sed "s|^PrivateKey = .*|PrivateKey = PRIVATE_KEY|" "$work/out/$conf" | diff -u "$root/tests/fixtures/expected.conf" - || fail "config differs"
  mode=$(stat -c %a "$work/out/$conf" 2> /dev/null || stat -f %Lp "$work/out/$conf")
  [ "$mode" = 600 ] || fail "mode is $mode, expected 600"
else
  fail "$conf not written"
fi
if [ -f "$work/out/$profile" ]; then
  jq -e --arg token "$api_token" '. == {version: 1, account: "0123456789abcdef0123456789abcdef",
    id: "t.00000000-0000-4000-8000-000000000001", api_token: $token}' "$work/out/$profile" > /dev/null ||
    fail "profile differs: $(cat "$work/out/$profile")"
  mode=$(stat -c %a "$work/out/$profile" 2> /dev/null || stat -f %Lp "$work/out/$profile")
  [ "$mode" = 600 ] || fail "profile mode is $mode, expected 600"
else
  fail "$profile not written"
fi
files=$(cd "$work/out" && printf '%s ' .[!.]* *)
[ "$files" = ".[!.]* $conf $profile " ] || fail "unexpected files: $files"
grep -q "^POST .*/v1/accounts/0123456789abcdef0123456789abcdef/warp_connector$" "$STUB_LOG" || fail "wrong registration URL"
expect_not_deleted

run "unknown option" 2 --bogus "$token"
expect_no_file

run "--delete without a profile" 2 --delete
run "--delete with a token too" 2 --delete "$work/x.json" "$token"
run "--delete with --delete-after" 2 --delete-after --delete "$work/x.json"

run "--delete-after" 0 --delete-after "$token"
[ -f "$work/out/$conf" ] || fail "$conf not written"
expect_deleted
grep -q "^Deleted registration" "$work/stdout" || fail "deletion not reported"
[ ! -e "$work/out/$profile" ] || fail "wrote a profile"

STUB_DELETE_STATUS=401 run "--delete-after, delete fails" 1 --delete-after "$token"
grep -q "could not delete registration" "$work/stderr" || fail "failed deletion not reported"
[ "$(grep -c '^DELETE' "$STUB_LOG")" -eq 1 ] || fail "expected exactly one DELETE, got $(grep -c '^DELETE' "$STUB_LOG")"

# A file, not <(...): Bash 3.2 closes a process substitution before the function reads it.
printf '%s\n' "$token" > "$work/token"
STDIN=$work/token run "token on stdin" 0 -
[ -f "$work/out/$conf" ] || fail "$conf not written"

STUB_STATUS=400 STUB_FILTER='{result: null, success: false, errors: [{code: 3004, message: "invalid warp_connector_token"}]}' \
  run "API error" 1 "$token"
grep -q "3004: invalid warp_connector_token" "$work/stderr" || fail "API error not shown"
expect_no_file
expect_not_deleted

# write_profile [jq filter]: write a device profile to $work/profile.json, as a registration would.
write_profile() {
  jq -n --arg token "$api_token" '{version: 1, account: "0123456789abcdef0123456789abcdef",
    id: "t.00000000-0000-4000-8000-000000000001", api_token: $token}' | jq "${1:-.}" > "$work/profile.json"
}

write_profile
run "--delete" 0 --delete "$work/profile.json"
expect_deleted
grep -qx "Authorization: Bearer $api_token" "$STUB_LOG.stdin" || fail "did not send the profile's API token"
[ -e "$work/profile.json" ] || fail "profile removed"
grep -q "^Deleted registration" "$work/stdout" || fail "deletion not reported"

write_profile
STUB_DELETE_STATUS=401 run "--delete, already deleted" 1 --delete "$work/profile.json"
grep -q "probably already deleted" "$work/stderr" || fail "already deleted not reported"
[ -e "$work/profile.json" ] || fail "profile removed after a failed delete"

run "--delete, missing profile" 1 --delete "$work/missing.json"
[ ! -s "$STUB_LOG" ] || fail "called the API"

while IFS='|' read -r name filter; do
  write_profile "$filter"
  run "--delete, $name" 1 --delete "$work/profile.json"
  grep -q "not a valid wgcf-mesh device profile" "$work/stderr" || fail "invalid profile not reported"
  [ ! -s "$STUB_LOG" ] || fail "called the API"
done << 'CASES'
unsafe registration ID|.id = "../x"
missing API token|del(.api_token)
invalid account|.account = "nope"
CASES
printf 'not json' > "$work/profile.json"
run "--delete, not JSON" 1 --delete "$work/profile.json"
[ ! -s "$STUB_LOG" ] || fail "called the API"

# Each of these fails after the registration was created, so it must be deleted.
while IFS='|' read -r name filter; do
  STUB_FILTER=$filter run "$name" 1 "$token"
  expect_no_file
  expect_deleted
done << 'CASES'
missing peer key|del(.result.config.peers[0].public_key)
null IPv4 address|.result.config.interface.addresses.v4 = null
invalid IPv6 address|.result.config.interface.addresses.v6 = "nope"
key not accepted|.result.key = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
no ports|.result.config.peers[0].endpoint.ports = []
missing organization|del(.result.account.organization)
CASES

STUB_FILTER='.result.id = "../x"' run "invalid registration ID" 1 "$token"
expect_no_file
expect_not_deleted

if [ "$failures" -eq 0 ]; then
  echo "All tests passed"
else
  echo "$failures failed"
  exit 1
fi
