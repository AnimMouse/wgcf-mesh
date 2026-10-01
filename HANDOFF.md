# Handoff 2: wgcf-mesh

Working notes for starting the new `wgcf-mesh` repo. Written 2026-10-01, after wgcf-connector v1.0.3. Everything from `HANDOFF.md` is done except this project.

## Goal

Generate the Cloudflare Mesh WireGuard config by calling Cloudflare's registration API directly, without Docker or the WARP client, the way [ViRb3/wgcf](https://github.com/ViRb3/wgcf) and [poscat0x04/wgcf-teams](https://github.com/poscat0x04/wgcf-teams) do. wgcf-connector stays as the Docker-based fallback, and as the reference for what a correct config looks like.

## Decisions

- **Bash first:** `curl`, `jq`, and `wg genkey` or `openssl genpkey -algorithm X25519`. macOS LibreSSL may lack X25519, so fall back to `wg`. Not Go or Rust.
- **Browser app only if CORS allows it.** Check with `curl -i -X OPTIONS -H 'Origin: https://example.com' <endpoint>`. If it would need a proxy, don't build it: every user's Mesh token would pass through our server.
- **`API.md` documents the protocol.** The Bash script is the canonical implementation.
- **Scheduled CI smoke test** with a dedicated test token stored as a repository secret. It must delete the registration it creates (see open questions).
- **Output must match wgcf-connector exactly:** filename `wgcf-mesh-<id>.conf` (decided; see open questions), same `[Interface]`/`[Peer]` layout, and the same failure rules: fail fast, validate every value, never write a partial file, mode 600.
- **Read Cloudflare's terms before publishing.** The API is undocumented and can change without notice.

## What we learned from wgcf-connector (verified 2026-10-01)

### The token

- Base64 JSON starting with `eyJhIjoi` (`{"a":"`). The test token ended in `fQ==`, not the `In0=` the README mentions, so the ending varies.
- Not decoded yet. Probably account ID, tunnel ID and secret, like `cloudflared` tokens, but unverified.
- `warp-cli connector new` exits 1 with `Failed to parse WARP Connector token` for invalid JSON. For a well-formed token with made-up `a`, `t` and `s` fields, it exits 1 with `Error(400): Bad Request` from the API. That doesn't prove those are the real field names.

### Registration is two steps: MASQUE keys first, then WireGuard keys

This is the most important finding for the protocol work. After `connector new` prints `Success`:

| Time | `tunnel_key_data.tunnel_type` | `key_type` | `reg.json` key lengths | Peer `public_key` |
| --- | --- | --- | --- | --- |
| 0 s | `masque` | `secp256r1` | public 124, secret 184 | 178 chars, not the WireGuard key |
| about 2 s | `wireguard` | `curve25519` | public 44, secret 44 | `bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=` |

`policy.tunnel_protocol` was `wireguard` the whole time. So the client registers with a P-256 key, reads the device profile policy, then makes a second call that replaces the key with a locally generated Curve25519 key. `reg.json` and `conf.json` are both rewritten.

For wgcf-mesh this means one of two things. Either the registration call accepts a WireGuard key directly, as consumer WARP does in ViRb3/wgcf, which would be one call. Or we must copy both calls: register, then update the key. Find out which first.

### Files in `/var/lib/cloudflare-warp/`

Field names and types from a real registration, no values. `[]` marks arrays.

`reg.json`: the local state, including our keys and the API credentials.
```
account_id: string
api_token: string                  <- probably the bearer token for later calls (key update, delete)
auth_method.type: string
compliance_environment: string
override_codes.disable_for_time.seconds: number
override_codes.disable_for_time.secret: string
public_key: string
registration_id[]: string
registration_persistence: string
secret_key: string                 <- WireGuard private key once the switch has happened
```

`conf.json`: the API response.
```
account.{account_type, id, managed, organization}: string      (account_type was "team")
connector_config.additional_interface_ips[]: string
device_identifiers: string
dex_tests[].{created, data.host, data.kind, data.method, enabled, interval, name, test_id, updated}
endpoints[].{v4, v6}: string       <- host:port; ports 2408, 500, 1701, 4500
interface.{v4, v6}: string         <- e.g. 100.96.0.18 and 2606:4700:cf1:1000::12
own_public_key: string
policy.{allow_updates, allowed_to_leave, auto_connect, captive_portal, gateway_id, lan_allow_subnet_size,
        operation_mode, organization, profile_id, register_interface_ip_with_dns, support_url, tunnel_protocol, ...}
policy.{always_exclude, always_include, exclude, fallback_domains, dns.doh_ips, speed_test_settings}
public_key: string                 <- peer (Cloudflare) key
registration_id[]: string
time_created.{secs_since_epoch, nanos_since_epoch}: number
tunnel_key_data.{key_type, tunnel_type}: string
valid_until: string
```

`connector_config.additional_interface_ips` isn't used by wgcf-connector yet. Check whether it belongs in `Address`.

### Other facts

- The **`warp-svc` logs are in `/var/lib/cloudflare-warp/`** (`cfwarp_service_log.txt` and others), not `/var/log/cloudflare-warp/` as HANDOFF.md guessed. `warp-svc` also writes DEBUG-level logs to stdout. That's step 2 of the plan below.
- **Every `connector new` creates a new registration** on the node (IDs `01a0f425…`, `01a0f428…`, …). Delete test nodes afterwards, and find the delete call so CI can clean up.
- **The config works end to end:** the WireGuard handshake completes, and `https://1.1.1.1/cdn-cgi/trace` through the tunnel shows `warp=on` and `gateway=on`.

## Findings from logs and strings (2026-10-01, WARP 2026.7.1377.0, fake token only)

Method: `warp-svc` run in the wgcf-connector image with `RUST_LOG=debug`, then `warp-cli connector new` given a well-formed fake token (made-up `a`, `t`, `s`), then `strings` on `/bin/warp-svc`. `cfwarp_service_log.txt` logs the **full failed request, including the token**, so redact when reading it after a real run.

### Registration endpoint (confirmed with curl)

`POST https://api.devices.cloudflare.com/v1/accounts/{a}/warp_connector`, where `{a}` is the token's `a` field.

- The ZT API host is `api.devices.cloudflare.com` (162.159.137.105, 162.159.138.105). `zero-trust-client.cloudflareclient.com` resolves to the same IPs. `api.cloudflareclient.com` (consumer) answers the same path too.
- Plain curl with no special headers (no `CF-Client-Version`, no `Content-Type`) gets the same answer as `warp-svc` for a fake token: `400 {"success":false,"errors":[{"code":3004,"message":"invalid warp_connector_token"}]}`. An empty body gets `3006 missing key field`. The same path under `/v0/` returns 404.
- So the client version header doesn't seem to be required, at least up to token validation. Re-check with a real token.

Request body as logged by `warp-svc` (Rust debug names; the JSON names come from `conf.json`):
```
type: "linux"
model: "VirtualBox 1.2"               <- from SMBIOS, optional
name: "<hostname>"                    <- optional; probably the device name shown in the dashboard
key: "<public key>"
tos: "<RFC 3339 timestamp>"
gateway_device_id: "<uuid>"           <- optional
os_version: "6.18.48"                 <- optional
serial_number: null
warp_connector_token: "<the whole base64 token, unchanged>"
tunnel_key_data: { key_type: NistP256 -> "secp256r1", tunnel_type: Masque -> "masque" }
identifiers: SystemUser
mtls_csr: null
```
The client sends the **token unchanged** in the body and puts only `a` in the path.

### The token

- `strings` shows `struct WarpConnectorToken with 3 elements` with fields `account_tag`, `tunnel_id` and `tunnel_secret`, in `V0`/`V1` variants. That matches the `a`/`t`/`s` keys, like `cloudflared` tunnel tokens. The client reads `a` for the URL path.

### Other endpoints from `strings` (unverified)

Probably auth `Authorization: Bearer <api_token>` like consumer WARP:
- `/v1/accounts/{a}/reg/{reg_id}`: probably GET config, PATCH key rotation (the MASQUE→WireGuard switch; the binary has a `RotateKeysResponse` type) and DELETE (`DeleteRegistrationResponse`).
- `/v0/accounts/{a}/reg/{reg_id}/{check,posture,client_certificates,devicestate,dex_results,virtualnetworks}` and `/v1/accounts/{a}/reg/{reg_id}/metrics`: not needed.

### CORS: no browser app

`OPTIONS` returns 404 with no `Access-Control-*` headers, and neither does `POST` with an `Origin` header. A browser page can't call the API directly, so per the decisions **don't build a browser version**.

## Real-token results (2026-10-01): registration is one call

With a real throwaway token and plain curl (no `CF-Client-Version`, no user agent), one call produced a working WireGuard config. The handshake completed, and `cdn-cgi/trace` over both IPv4 and IPv6 showed `warp=on` and `gateway=on`. The registration was then deleted.

**Register:** `POST https://api.devices.cloudflare.com/v1/accounts/{a}/warp_connector` with `Content-Type: application/json` and this body:
```json
{"type":"linux","name":"<device name>","key":"<our Curve25519 public key>","tos":"<RFC 3339 now>","warp_connector_token":"<token>"}
```
- **Leave out `tunnel_key_data`.** With `{key_type:"curve25519",tunnel_type:"wireguard"}` the server returns `400 2004 bad device request`. Without it, the server accepts our Curve25519 key as-is (`result.key` equals our public key) and returns the WireGuard peer key `bmXOC+F1…`. `warp-svc`'s MASQUE-then-rotate dance comes from sending `secp256r1`/`masque` and isn't needed.
- Errors: `3004 invalid warp_connector_token`, `3006 missing key field`, `2004 bad device request`.

Response fields (`200`, `success: true`) that matter:
```
result.id                                 "t.<uuid>" (38 chars, includes the "t." prefix)
result.token                              api_token, a UUID used as the Bearer token for /reg/{id}
result.key                                our public key, echoed back
result.name                               device name we sent
result.account.organization               team name
result.config.interface.addresses.{v4,v6} e.g. 100.96.0.x and 2606:4700:cf1:1000::x (no prefix length)
result.config.peers[0].public_key         peer key
result.config.peers[0].endpoint.{v4,v6}   "162.159.193.5:0" and "[2606:4700:100::a29f:c105]:0", port 0
result.config.peers[0].endpoint.host      "engage.cloudflareclient.com:2408"
result.config.peers[0].endpoint.ports[]   [2408, 500, 1701, 4500]
result.connector.additional_interfaces.ipv6[]   one 21-char IPv6 string (probably a CIDR); cf. additional_interface_ips
result.policy.tunnel_protocol             the device profile's protocol: "" under a WireGuard profile, "masque" under a MASQUE one
```
The response shape differs from `warp-svc`'s `conf.json`, which is the client's own reshaped copy. Endpoints come back as `ip:0` plus a `ports` list, so build `ip:port` from `ports`. wgcf-connector's `conf.json` had one endpoint entry per port.

The response also has `override_codes` secrets, `physical_device_id`, `user.id`, `peer.*` and `dex_tests`. Don't print them.

**Get:** `GET /v1/accounts/{a}/reg/{id}` with `Authorization: Bearer <result.token>` returns `200` with the same `result`.

**Delete:** `DELETE /v1/accounts/{a}/reg/{id}` with the same Bearer token returns `204`. Afterwards GET returns `401 2016 unauthorized`. Still to check: whether the device also disappears from the dashboard.

## IPv6 CIDR route test (2026-10-02)

Two Mesh nodes in the same account, both on a MASQUE device profile, with CIDR routes and split tunnel entries set in the dashboard:

| Node | CIDR routes | Host addresses |
| --- | --- | --- |
| A (`~/.mesh-token`) | `192.168.11.0/24`, `fd04:900d:c0de:1::/64` | `192.168.11.1`, `fd04:900d:c0de:1::1` |
| B (`~/.mesh-token-2`) | `192.168.12.0/24`, `fd04:900d:c0de:2::/64` | `192.168.12.1`, `fd04:900d:c0de:2::1` |

Setup: each node in its own container, with the host addresses on a `dummy0` interface standing in for the LAN, and socat listening on TCP 8080. Each check runs both ways, sourced from the right address, as ICMP ping and a TCP connect, while tcpdump (`-l`) on the receiving tunnel counts arriving packets. The wgcf-mesh containers use kernel WireGuard (`wg-quick`); the official client containers use `warp-cli connector new` and `connect`. The two clients were never registered on a node at the same time. Every registration was deleted afterwards.

| Check | wgcf-mesh (WireGuard) | Official client (MASQUE) |
| --- | --- | --- |
| Cloudflare IPv4 to each other | pass | pass |
| Cloudflare IPv6 to each other | pass | pass |
| Host IPv4 (IPv4 CIDR routes) | pass | pass |
| **Host IPv6 (IPv6 CIDR routes)** | **fail: packets leave the sender's `wg0` and never reach the other node** | pass |

Notes:
- Interface addresses are handed out per registration (`.1`, `.3`, `.5`, …), not fixed per node, so always read them from the config.
- **Keepalive:** the wgcf-mesh config has no `PersistentKeepalive`, so a node that only receives traffic doesn't handshake until it sends something, and NAT can drop the mapping. The test set `persistent-keepalive 25`. Consider adding `PersistentKeepalive = 25` to the generated `[Peer]`, since a Mesh node is expected to receive traffic.

## Plan

Use a **throwaway** Mesh node on a WireGuard device profile, and delete it afterwards.

1. **Decode the token** locally and print only the key names and value lengths, not the values: `base64 -d < ~/.mesh-token | jq 'map_values(length)'`.
2. **Read the `warp-svc` logs** (stdout at DEBUG level, plus `/var/lib/cloudflare-warp/cfwarp_service_log.txt`) during `connector new`. Look for URLs, methods and the second key-update call.
3. **Run `strings` on `/bin/warp-svc`** for API hosts, paths (`/v0/`, `/reg`, `connector`…) and `CF-Client-Version`-style headers.
4. **Intercept with mitmproxy** in a container. Risk: `warp-svc` is Rust and may use a bundled trust store or pin certificates. If so, rely on steps 2–3 and the logs.
5. **Replay with curl** and a fresh `wg genkey` pair. Compare the response with the `conf.json` fields above, then write the config with the same validation as `wgcf-connector.sh`.
6. **Check CORS** on each endpoint, which decides whether a browser version is possible.
7. **Find the delete call** (probably authenticated with `reg.json`'s `api_token`) for CI cleanup.

Status: all steps done except 4, which is no longer needed. `API.md`, `wgcf-mesh.sh` and the offline tests (`tests/test.sh`, with `curl` stubbed) are written. A real run produced a working tunnel over IPv4 and IPv6, and the registration was deleted afterwards. README and CI are written. All changes go through PRs, and the `main` ruleset requires the `CI` check. The device profile (`wgcf-mesh-<id>.json` and `--delete`) is implemented, and the daily smoke test registers and then deletes through it. Next: check Cloudflare's terms, then cut v1.0.0 with `gh release create`. After that, the `CLAUDE.md` roadmap.

## Open questions

- ~~Is registration two steps?~~ No. One call with our Curve25519 key and no `tunnel_key_data`.
- ~~What are the token's fields?~~ `a`/`t`/`s` = account tag, tunnel ID, tunnel secret. `a` goes in the URL path and the whole token goes in the body.
- ~~How is a registration deleted?~~ `DELETE /v1/accounts/{a}/reg/{id}` with `Authorization: Bearer <result.token>` returns `204`.
- **`connector.additional_interfaces.ipv6`** (the official client's `connector_config.additional_interface_ips`): investigated 2026-10-02, still open whether to add it to `Address`.
  - ~~It's a node-level address.~~ Corrected 2026-10-02: it's shared across nodes too. Two different Mesh nodes in the same account both got `2606:4700:cf1:2000::1` from the official client, so it's probably an account-level address, not per node or per device. What it's for is still unknown.
  - The official client (`warp-cli connector new`, then `connect`, under a MASQUE profile) assigns it to `CloudflareWARP` as a **deprecated** address (`preferred_lft 0`). The kernel then never uses it as the source for outgoing connections, but still accepts traffic sent to it. Through MASQUE, traffic sourced from it reaches the internet (`warp=on`).
  - With a wgcf-mesh WireGuard config, adding it to `Address` breaks nothing, but traffic sourced from it gets no reply. That fits Cloudflare's note that IPv6 and high availability features need MASQUE.
  - So don't add it to `Address` as a plain address. wg-quick can't mark it deprecated, so the kernel could pick it as the source and break IPv6. A `PostUp = ip -6 addr add <ip>/128 dev %i preferred_lft 0` line would match the official client on Linux, but other WireGuard apps ignore `PostUp`, and it isn't useful until something can reach the node at that address over WireGuard.
- ~~Filename?~~ Decided 2026-10-01: `wgcf-mesh-<id>.conf`, where `<id>` is `result.id` as returned (`t.<uuid>`).
- ~~Does a MASQUE-only device profile still get a working WireGuard config?~~ Yes, verified 2026-10-01. Under a MASQUE profile the registration still returns the WireGuard peer key, and the tunnel works over IPv4 and IPv6 (`warp=on`, `gateway=on`). `policy.tunnel_protocol` is `"masque"` there and empty under a WireGuard profile, so the script ignores it and **no WireGuard device profile is needed**. Untested: Cloudflare's docs say hostname routes, IPv6 CIDR routes and high availability don't work with a WireGuard profile. Whether they work for our WireGuard tunnel under a MASQUE profile is tracked in the `CLAUDE.md` roadmap.
- ~~Which endpoint and port to use?~~ Decided 2026-10-02: like wgcf-connector, the first IPv4 address with the first port (2408) is the active `Endpoint`, and every other address and port pair is a `#Endpoint =` comment.
- Is `tos` required? Is `name` shown in the dashboard?
- What `CF-Client-Version` or user agent does the API require, and does it reject old values over time? Not required as of 2026-10-01, even for a real registration. If so, CI needs to track WARP releases like wgcf-connector's `auto-update.yaml` does.

## Carry over from wgcf-connector

- **Workflows to copy:** `build-and-push.yaml` (native per-arch builds, push by digest, test, merge), `auto-update.yaml` (patch release per WARP bump) and the semver tag scheme. Always release with `gh release create`, not a bare tag push: `auto-update.yaml` computes the next version from the latest GitHub Release.
- **Testing without a token:** stub `warp-cli`/`warp-svc` scripts that copy fake `reg.json`/`conf.json` fixtures, mounted over `/usr/local/bin`. The same fixture approach works for stubbing `curl` responses.
- **Testing with a token:** never paste it into the chat. Save it with `read -rs t && printf %s "$t" > ~/.mesh-token && chmod 600 ~/.mesh-token` in the VS Code terminal, and pass it as `"$(cat ~/.mesh-token)"`. Redact `PrivateKey` and the organization when showing output.
- **Tunnel test:** `alpine` with `--cap-add NET_ADMIN --sysctl net.ipv6.conf.all.disable_ipv6=0 --sysctl net.ipv4.conf.all.src_valid_mark=1`, `wireguard-tools-wg-quick iptables ip6tables` (`wg-quick` fails without `ip6tables-restore`), and the config without its `DNS` line (Alpine's `wg-quick` needs resolvconf for it). Then check `https://1.1.1.1/cdn-cgi/trace`.

## Environment notes

- The dev container shell is **zsh**: write `${img}:latest`, not `$img:latest` (zsh reads `:l` as a modifier), and unmatched globs are errors. Use `bash` for test scripts.
- Docker-in-Docker works, including `--privileged` and `NET_ADMIN`. `binfmt_misc` isn't mounted, so there's no QEMU for `docker run`; BuildKit still emulates `RUN` steps. `warp-svc` doesn't start under QEMU anyway (`NetworkInfoError`).
- `wg` isn't installed in the dev container, so generate keys with `openssl genpkey -algorithm X25519 -outform DER` (the last 32 bytes are the private key; `openssl pkey -pubout -outform DER`, last 32 bytes, is the public key).
- `gh` is logged in as AnimMouse with `repo`, `read:org`, `gist` and `write:packages`.
