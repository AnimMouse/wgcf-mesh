#!/usr/bin/env bash
# Register a Cloudflare Mesh node and write its WireGuard configuration.
# See API.md for the protocol.
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

# Delete the registration so a failed run doesn't leave a device behind.
cleanup() {
  if [ -n "${tmp:-}" ]; then rm -f "$tmp"; fi
  if [ -n "${api_token:-}" ]; then
    printf 'Authorization: Bearer %s\n' "$api_token" |
      curl -sS -o /dev/null --max-time 30 -X DELETE -H @- "$api/accounts/$account/reg/$id" ||
      echo "Warning: could not delete registration $id, remove it in the Cloudflare dashboard" >&2
  fi
}
trap cleanup EXIT

if [ $# -ne 1 ]; then
  echo "Usage: $0 <token>" >&2
  echo "       $0 - < token-file" >&2
  exit 2
fi
for cmd in curl jq; do
  command -v "$cmd" > /dev/null || die "$cmd is required"
done

token=$1
if [ "$token" = - ]; then
  IFS= read -r token || [ -n "$token" ] || die "no token on standard input"
fi
account=$(jq -Rer '@base64d | fromjson | .a | strings | select(test("^[0-9a-f]{32}$"))' <<< "$token" 2> /dev/null) ||
  die "invalid token, copy the whole Cloudflare Mesh token that starts with eyJhIjoi"

# Generate a WireGuard key pair. macOS LibreSSL may lack X25519, so prefer wg.
if command -v wg > /dev/null; then
  private_key=$(wg genkey)
  public_key=$(wg pubkey <<< "$private_key")
elif pem=$(openssl genpkey -algorithm X25519 2> /dev/null); then
  private_key=$(openssl pkey -outform DER <<< "$pem" | tail -c 32 | base64)
  public_key=$(openssl pkey -pubout -outform DER <<< "$pem" | tail -c 32 | base64)
  unset pem
else
  die "wg or openssl with X25519 support is required"
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
umask 077
tmp=$(mktemp ".$file.XXXXXX")
cat > "$tmp" << EOL
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
Endpoint = $endpoint
$other_endpoints
EOL
mv "$tmp" "$file"
tmp=
api_token=
echo "Saved $file"
