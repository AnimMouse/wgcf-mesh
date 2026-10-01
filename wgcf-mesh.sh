#!/usr/bin/env bash
# Register a Cloudflare Mesh node and write its WireGuard configuration and a device profile,
# or delete a registration using its device profile. See API.md for the protocol.
set -euo pipefail

api=https://api.devices.cloudflare.com/v1

die() {
  echo "Error: $*" >&2
  exit 1
}

# Print a string field from the registration response, failing if it is missing, null or empty.
field() {
  jq -er "$1 | strings | select(. != \"\")" <<< "$response" || die "$1 missing from the API response"
}

# Print the API's error messages from a response body, or the HTTP status if it has none.
api_error() {
  jq -er '[.errors[]? | "\(.code): \(.message)"] | select(length > 0) | join(", ")' <<< "$1" 2> /dev/null || echo "HTTP $2"
}

# Delete the registration $id. The API answers 204 on success; the HTTP status is left in $delete_status.
delete_registration() {
  delete_status=
  # Send the bearer token on standard input so it doesn't show up in the process list.
  delete_status=$(printf 'Authorization: Bearer %s\n' "$api_token" |
    curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -X DELETE -H @- "$api/accounts/$account/reg/$id") &&
    [ "$delete_status" = 204 ]
}

# Remove temporary and partly written files, and delete the registration so a failed run doesn't leave a device behind.
cleanup() {
  rm -f "${tmp_conf:-}" "${tmp_profile:-}"
  if ${armed:-false}; then
    rm -f "${saved_profile:-}"
    delete_registration || echo "Warning: could not delete registration $id, remove it in the Cloudflare dashboard" >&2
  fi
}
trap cleanup EXIT

usage() {
  echo "Usage: $0 [--delete-after] <token>" >&2
  echo "       $0 [--delete-after] - < token-file" >&2
  echo "       $0 --delete <profile>" >&2
  echo "  --delete-after      delete the registration after writing the configuration, for testing" >&2
  echo "  --delete <profile>  delete the registration saved in a wgcf-mesh-<id>.json device profile" >&2
  exit 2
}

# Print a field from the device profile, failing unless it matches the pattern $2.
profile_field() {
  jq -er --arg pattern "$2" ".$1 | strings | select(test(\$pattern))" "$profile" 2> /dev/null ||
    die "$profile is not a valid wgcf-mesh device profile"
}

# Delete the registration saved in the device profile $profile. The profile and the config are left in place.
delete_from_profile() {
  [ -f "$profile" ] || die "$profile not found"
  account=$(profile_field account '^[0-9a-f]{32}$')
  id=$(profile_field id '^[A-Za-z0-9._-]+$')
  [[ $id != *..* ]] || die "$profile is not a valid wgcf-mesh device profile"
  api_token=$(profile_field api_token '^[A-Za-z0-9._-]+$')
  if ! delete_registration; then
    case $delete_status in
      401 | 404) die "could not delete registration $id (HTTP $delete_status). It was probably already deleted, check the Cloudflare dashboard." ;;
      *) die "could not delete registration $id${delete_status:+ (HTTP $delete_status)}" ;;
    esac
  fi
  echo "Deleted registration $id. $profile and wgcf-mesh-$id.conf are kept, but no longer work."
}

delete_after=false
profile=
while [ $# -gt 0 ]; do
  case $1 in
    --delete-after) delete_after=true ;;
    --delete)
      [ $# -ge 2 ] || usage
      profile=$2
      shift
      ;;
    --)
      shift
      break
      ;;
    -?*) usage ;;
    *) break ;;
  esac
  shift
done
if [ -n "$profile" ]; then
  if [ $# -ne 0 ] || $delete_after; then usage; fi
else
  [ $# -eq 1 ] || usage
fi
for cmd in curl jq; do
  command -v "$cmd" > /dev/null || die "$cmd is required"
done

if [ -n "$profile" ]; then
  delete_from_profile
  exit 0
fi

token=$1
if [ "$token" = - ]; then
  IFS= read -r token || [ -n "$token" ] || die "no token on standard input"
fi
account=$(jq -Rer '@base64d | fromjson | .a | strings | select(test("^[0-9a-f]{32}$"))' <<< "$token" 2> /dev/null) ||
  die "invalid token, copy the whole Cloudflare Mesh token that starts with eyJhIjoi"

# Generate a WireGuard key pair. macOS's LibreSSL lacks X25519, so prefer wg, then try Homebrew's OpenSSL.
if command -v wg > /dev/null; then
  private_key=$(wg genkey)
  public_key=$(wg pubkey <<< "$private_key")
else
  pem=
  for openssl in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    pem=$("$openssl" genpkey -algorithm X25519 2> /dev/null) && break
  done
  [ -n "$pem" ] || die "wg or OpenSSL with X25519 support is required. Install wireguard-tools, on macOS with: brew install wireguard-tools"
  private_key=$("$openssl" pkey -outform DER <<< "$pem" | tail -c 32 | base64)
  public_key=$("$openssl" pkey -pubout -outform DER <<< "$pem" | tail -c 32 | base64)
  unset pem
fi
key_pattern='^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$'
[[ $private_key =~ $key_pattern && $public_key =~ $key_pattern ]] || die "could not generate a WireGuard key pair"

body=$(jq -nc --arg key "$public_key" --arg token "$token" \
  '{type: "linux", name: "wgcf-mesh", key: $key, tos: (now | todate), warp_connector_token: $token}')
# Send the token on standard input so it doesn't show up in the process list.
response=$(curl -sS --max-time 30 -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @- \
  "$api/accounts/$account/warp_connector" <<< "$body") || die "could not reach the Cloudflare API"
status=${response##*$'\n'}
response=${response%$'\n'*}
if [ "$status" != 200 ] || ! jq -e '.success == true' <<< "$response" > /dev/null 2>&1; then
  die "registration failed: $(api_error "$response" "$status")"
fi

# The registration exists from here on, and cleanup deletes it if anything fails.
id=$(field .result.id)
[[ $id =~ ^[A-Za-z0-9._-]+$ && $id != *..* ]] ||
  die "registration ID $id is invalid, remove the new device in the Cloudflare dashboard"
api_token=$(field .result.token)
[[ $api_token =~ ^[A-Za-z0-9._-]+$ ]] || die "API token is invalid, remove the new device in the Cloudflare dashboard"
armed=true
[ "$(field .result.key)" = "$public_key" ] || die "the API did not accept our public key"
peer_key=$(field '.result.config.peers[0].public_key')
[[ $peer_key =~ $key_pattern ]] || die "peer public key is not a WireGuard key"
organization=$(field .result.account.organization)
v4=$(field .result.config.interface.addresses.v4)
[[ $v4 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "interface IPv4 address $v4 is invalid"
v6=$(field .result.config.interface.addresses.v6)
[[ $v6 =~ ^[0-9a-fA-F:]+$ && $v6 == *:* ]] || die "interface IPv6 address $v6 is invalid"

# Endpoints come as "ip:0" plus a list of ports, so list every address with every port.
endpoints=$(jq -r '.result.config.peers[0].endpoint as $e | $e.ports[]? as $port |
  ($e.v4, $e.v6) | strings | sub(":0$"; "") | "\(.):\($port)"' <<< "$response")
endpoint=$(head -n 1 <<< "$endpoints")
[[ $endpoint =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+$ ]] || die "endpoint ${endpoint:-(none)} is invalid"
other_endpoints=$(tail -n +2 <<< "$endpoints" | sed 's/^/#Endpoint = /')

file=wgcf-mesh-$id.conf
profile_file=wgcf-mesh-$id.json
umask 077
tmp_conf=$(mktemp ".$file.XXXXXX")
cat > "$tmp_conf" << EOL
# Registration ID: $id
# Organization: $organization
[Interface]
PrivateKey = $private_key
Address = $v6/128, $v4/32
DNS = 2606:4700:4700::1111, 2606:4700:4700::1001, 1.1.1.1, 1.0.0.1
MTU = 1420

[Peer]
PublicKey = $peer_key
AllowedIPs = ::/0, 0.0.0.0/0
PersistentKeepalive = 60
Endpoint = $endpoint
$other_endpoints
EOL
if $delete_after; then
  mv "$tmp_conf" "$file"
  tmp_conf=
  echo "Saved $file"
  armed=false
  delete_registration || die "could not delete registration $id, remove it in the Cloudflare dashboard"
  echo "Deleted registration $id, so $file no longer works"
  exit 0
fi

# The device profile holds the API token that can delete this device later, so it stays out of the WireGuard config.
tmp_profile=$(mktemp ".$profile_file.XXXXXX")
jq -n --arg account "$account" --arg id "$id" --arg api_token "$api_token" \
  '{version: 1, account: $account, id: $id, api_token: $api_token}' > "$tmp_profile"
mv "$tmp_profile" "$profile_file"
tmp_profile=
saved_profile=$profile_file
mv "$tmp_conf" "$file"
tmp_conf=
armed=false
echo "Saved $file"
echo "Saved $profile_file, keep it to delete this device later with: $0 --delete $profile_file"
