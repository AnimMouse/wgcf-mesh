#!/usr/bin/env bash
# Register a Cloudflare Mesh node (with a Mesh token) or a headless client device (with a service token),
# and write its WireGuard configuration and a device profile, or update or delete a registration using
# its device profile. See API.md for the protocol.
set -euo pipefail

api_base=https://api.devices.cloudflare.com
api=$api_base/v1

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
  echo "Usage: $0 [options] <token>" >&2
  echo "       $0 [options] - < token-file" >&2
  echo "       $0 [options] --organization <team> --client-id <id> --client-secret <secret>" >&2
  echo "       $0 --update <profile> <metadata options>" >&2
  echo "       $0 --delete <profile>" >&2
  echo "Device metadata, shown in the Cloudflare dashboard (each 1 to 100 bytes):" >&2
  echo "  --name <name>            device name, wgcf-mesh by default" >&2
  echo "  --model <model>          device model" >&2
  echo "  --os-version <version>   OS version (Cloudflare keeps only the version number if it finds one)" >&2
  echo "  --serial-number <serial> serial number" >&2
  echo "Service token, to register a headless client device instead of a Mesh node:" >&2
  echo "  --organization <team>    Zero Trust team name" >&2
  echo "  --client-id <id>         service token Client ID" >&2
  echo "  --client-secret <secret> service token Client Secret, or - to read it from standard input" >&2
  echo "Other options:" >&2
  echo "  --update <profile>       change the metadata of the device saved in a wgcf-mesh-<id>.json device profile" >&2
  echo "  --delete <profile>       delete the device saved in a device profile" >&2
  echo "  --delete-after           delete the registration after writing the configuration, for testing" >&2
  exit 2
}

# add_metadata <field> <option> <value>: validate a metadata value and add it to $metadata.
add_metadata() {
  local bytes
  [[ $3 != *[[:cntrl:]]* ]] || die "$2 must not contain control characters"
  bytes=$(jq -nr --arg v "$3" '$v | utf8bytelength')
  [ "$bytes" -ge 1 ] && [ "$bytes" -le 100 ] || die "$2 must be 1 to 100 bytes long, not $bytes"
  metadata=$(jq -c --arg field "$1" --arg v "$3" '.[$field] = $v' <<< "$metadata")
}

# strip_header <name> <value>: print the value without a leading "<name>: ", as the dashboard copies it.
strip_header() {
  local value=$2
  shopt -s nocasematch
  if [[ $value == "$1:"* ]]; then
    value=${value:${#1}+1}
    value=${value# }
  fi
  shopt -u nocasematch
  printf %s "$value"
}

# Exchange the service token for a short-lived Access JWT, and read the account tag from it.
access_jwt() {
  local result status location payload
  [[ $organization_name =~ ^[A-Za-z0-9-]{1,63}$ ]] || die "--organization must be your Zero Trust team name"
  client_id=$(strip_header CF-Access-Client-Id "$client_id")
  client_secret=$(strip_header CF-Access-Client-Secret "$client_secret")
  [[ $client_id =~ ^[0-9a-f]{32}\.access$ ]] || die "--client-id must be a service token Client ID, like <32 hex digits>.access"
  [[ -n $client_secret && $client_secret != *[[:cntrl:]]* ]] || die "--client-secret is empty or invalid"
  # Send the credentials on standard input so they don't show up in the process list.
  result=$(printf 'CF-Access-Client-Id: %s\nCF-Access-Client-Secret: %s\n' "$client_id" "$client_secret" |
    curl -sS --max-time 30 -o /dev/null -w '%{http_code} %{redirect_url}' -H @- \
      "https://$organization_name.cloudflareaccess.com/warp") || die "could not reach $organization_name.cloudflareaccess.com"
  status=${result%% *}
  location=${result#* }
  case $status in
    302) ;;
    403) die "Cloudflare Access rejected the service token (HTTP 403). Check the Client ID and Secret, and that a device enrollment rule with the Service Auth action allows this token." ;;
    *) die "unexpected answer from $organization_name.cloudflareaccess.com (HTTP $status)" ;;
  esac
  jwt=${location#*[?&]token=}
  jwt=${jwt%%&*}
  [[ $location == *token=* && $jwt =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] ||
    die "Cloudflare Access did not return a token"
  payload=${jwt#*.}
  payload=${payload%%.*}
  account=$(jq -Rer 'gsub("-"; "+") | gsub("_"; "/") | . + ("=" * ((4 - length % 4) % 4)) | @base64d | fromjson
    | .account_id | strings | select(test("^[0-9a-f]{32}$"))' <<< "$payload" 2> /dev/null) ||
    die "the token from Cloudflare Access has no account ID"
}

# Print a field from the device profile, failing unless it matches the pattern $2.
profile_field() {
  jq -er --arg pattern "$2" ".$1 | strings | select(test(\$pattern))" "$profile" 2> /dev/null ||
    die "$profile is not a valid wgcf-mesh device profile"
}

# Read the account, registration ID and API token from the device profile $profile.
load_profile() {
  [ -f "$profile" ] || die "$profile not found"
  account=$(profile_field account '^[0-9a-f]{32}$')
  id=$(profile_field id '^[A-Za-z0-9._-]+$')
  [[ $id != *..* ]] || die "$profile is not a valid wgcf-mesh device profile"
  api_token=$(profile_field api_token '^[A-Za-z0-9._-]+$')
}

# Change the registration's metadata to $metadata, and keep the profile's name in sync.
update_from_profile() {
  local response status tmp
  load_profile
  # Send the bearer token on standard input so it doesn't show up in the process list.
  response=$(printf 'Authorization: Bearer %s\n' "$api_token" |
    curl -sS --max-time 30 -w '\n%{http_code}' -X PATCH -H @- -H 'Content-Type: application/json' \
      --data-binary "$metadata" "$api/accounts/$account/reg/$id") || die "could not reach the Cloudflare API"
  status=${response##*$'\n'}
  response=${response%$'\n'*}
  if [ "$status" != 200 ] || ! jq -e '.success == true' <<< "$response" > /dev/null 2>&1; then
    die "could not update registration $id: $(api_error "$response" "$status")"
  fi
  if jq -e 'has("name")' <<< "$metadata" > /dev/null; then
    tmp=$(mktemp "$(dirname "$profile")/.wgcf-mesh-profile.XXXXXX")
    if ! jq --argjson metadata "$metadata" '.name = $metadata.name' "$profile" > "$tmp" || ! mv "$tmp" "$profile"; then
      rm -f "$tmp"
      die "updated registration $id, but could not save the new name in $profile"
    fi
  fi
  echo "Updated registration $id: $(jq -r 'to_entries | map("\(.key) = \(.value)") | join(", ")' <<< "$metadata")"
}

# Delete the registration saved in the device profile $profile. The profile and the config are left in place.
delete_from_profile() {
  load_profile
  if ! delete_registration; then
    case $delete_status in
      401 | 404) die "could not delete registration $id (HTTP $delete_status). It was probably already deleted, check the Cloudflare dashboard." ;;
      *) die "could not delete registration $id${delete_status:+ (HTTP $delete_status)}" ;;
    esac
  fi
  echo "Deleted registration $id. $profile and wgcf-mesh-$id.conf are kept, but no longer work."
}

mode=register
delete_after=false
profile=
unset name model os_version serial_number organization_name client_id client_secret
while [ $# -gt 0 ]; do
  case $1 in
    --delete-after) delete_after=true ;;
    --delete | --update)
      [ $# -ge 2 ] && [ "$mode" = register ] || usage
      mode=${1#--}
      profile=$2
      shift
      ;;
    --name | --model | --os-version | --serial-number | --organization | --client-id | --client-secret)
      [ $# -ge 2 ] || usage
      case $1 in
        --organization) organization_name=$2 ;;
        --client-id) client_id=$2 ;;
        --client-secret) client_secret=$2 ;;
        --name) name=$2 ;;
        --model) model=$2 ;;
        --os-version) os_version=$2 ;;
        --serial-number) serial_number=$2 ;;
      esac
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
has_metadata=false
if [ -n "${name+x}${model+x}${os_version+x}${serial_number+x}" ]; then has_metadata=true; fi
service_token=false
st_options=${organization_name+x}${client_id+x}${client_secret+x}
if [ "$st_options" = xxx ]; then service_token=true; elif [ -n "$st_options" ]; then usage; fi
case $mode in
  register) if { $service_token && [ $# -ne 0 ]; } || { ! $service_token && [ $# -ne 1 ]; }; then usage; fi ;;
  update) if [ $# -ne 0 ] || $delete_after || ! $has_metadata || $service_token; then usage; fi ;;
  delete) if [ $# -ne 0 ] || $delete_after || $has_metadata || $service_token; then usage; fi ;;
esac
for cmd in curl jq; do
  command -v "$cmd" > /dev/null || die "$cmd is required"
done

metadata='{}'
if [ "$mode" = register ] && [ -z "${name+x}" ]; then name=wgcf-mesh; fi
if [ -n "${name+x}" ]; then add_metadata name --name "$name"; fi
if [ -n "${model+x}" ]; then add_metadata model --model "$model"; fi
if [ -n "${os_version+x}" ]; then add_metadata os_version --os-version "$os_version"; fi
if [ -n "${serial_number+x}" ]; then add_metadata serial_number --serial-number "$serial_number"; fi

case $mode in
  delete)
    delete_from_profile
    exit 0
    ;;
  update)
    update_from_profile
    exit 0
    ;;
esac

if $service_token; then
  if [ "$client_secret" = - ]; then
    IFS= read -r client_secret || [ -n "$client_secret" ] || die "no Client Secret on standard input"
  fi
else
  token=$1
  if [ "$token" = - ]; then
    IFS= read -r token || [ -n "$token" ] || die "no token on standard input"
  fi
  account=$(jq -Rer '@base64d | fromjson | .a | strings | select(test("^[0-9a-f]{32}$"))' <<< "$token" 2> /dev/null) ||
    die "invalid token, copy the whole Cloudflare Mesh token that starts with eyJhIjoi"
fi

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

if $service_token; then
  # The Access JWT lasts only 60 seconds, so get it right before registering.
  access_jwt
  body=$(jq -nc --arg key "$public_key" --argjson metadata "$metadata" \
    '{type: "linux", key: $key, tos: (now | todate)} + $metadata')
  response=$(printf 'Cf-Access-Jwt-Assertion: %s\nContent-Type: application/json\n' "$jwt" |
    curl -sS --max-time 30 -w '\n%{http_code}' -X POST -H @- --data-binary "$body" "$api_base/v0/reg") ||
    die "could not reach the Cloudflare API"
  unset jwt client_secret
else
  # Mesh nodes must be "linux": the API rejects every other type with error 2082.
  body=$(jq -nc --arg key "$public_key" --arg token "$token" --argjson metadata "$metadata" \
    '{type: "linux", key: $key, tos: (now | todate), warp_connector_token: $token} + $metadata')
  # Send the token on standard input so it doesn't show up in the process list.
  response=$(curl -sS --max-time 30 -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @- \
    "$api/accounts/$account/warp_connector" <<< "$body") || die "could not reach the Cloudflare API"
fi
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
device_name=$(field .result.name)
[[ $device_name != *[[:cntrl:]]* ]] || die "device name from the API contains control characters"
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
# Device name: $device_name
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
jq -n --arg account "$account" --arg id "$id" --arg api_token "$api_token" --arg name "$device_name" \
  '{version: 1, account: $account, id: $id, api_token: $api_token, name: $name}' > "$tmp_profile"
mv "$tmp_profile" "$profile_file"
tmp_profile=
saved_profile=$profile_file
mv "$tmp_conf" "$file"
tmp_conf=
armed=false
echo "Saved $file"
echo "Saved $profile_file, keep it to update or delete this device later, e.g. $0 --delete $profile_file"
