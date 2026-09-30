# Handoff 2: wgcf-mesh

Working notes for starting the new `wgcf-mesh` repo. Written 2026-10-01, after wgcf-connector v1.0.3. Everything from `HANDOFF.md` is done except this project.

## Goal

Generate the Cloudflare Mesh WireGuard config by calling Cloudflare's registration API directly, without Docker or the WARP client, the way [ViRb3/wgcf](https://github.com/ViRb3/wgcf) and [poscat0x04/wgcf-teams](https://github.com/poscat0x04/wgcf-teams) do. wgcf-connector stays as the Docker-based fallback, and as the reference for what a correct config looks like.

## Decisions

- **Bash first:** `curl`, `jq`, and `wg genkey` or `openssl genpkey -algorithm X25519`. macOS LibreSSL may lack X25519, so fall back to `wg`. Not Go or Rust.
- **Browser app only if CORS allows it.** Check with `curl -i -X OPTIONS -H 'Origin: https://example.com' <endpoint>`. If it would need a proxy, don't build it: every user's Mesh token would pass through our server.
- **`API.md` documents the protocol.** The Bash script is the canonical implementation.
- **Scheduled CI smoke test** with a dedicated test token stored as a repository secret. It must delete the registration it creates (see open questions).
- **Output must match wgcf-connector exactly:** same filename (`wgcf-connector-<registration_id>.conf`, or decide on a new name up front), same `[Interface]`/`[Peer]` layout, and the same failure rules: fail fast, validate every value, never write a partial file, mode 600.
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

## Plan

Use a **throwaway** Mesh node on a WireGuard device profile, and delete it afterwards.

1. **Decode the token** locally and print only the key names and value lengths, not the values: `base64 -d < ~/.mesh-token | jq 'map_values(length)'`.
2. **Read the `warp-svc` logs** (stdout at DEBUG level, plus `/var/lib/cloudflare-warp/cfwarp_service_log.txt`) during `connector new`. Look for URLs, methods and the second key-update call.
3. **Run `strings` on `/bin/warp-svc`** for API hosts, paths (`/v0/`, `/reg`, `connector`…) and `CF-Client-Version`-style headers.
4. **Intercept with mitmproxy** in a container. Risk: `warp-svc` is Rust and may use a bundled trust store or pin certificates. If so, rely on steps 2–3 and the logs.
5. **Replay with curl** and a fresh `wg genkey` pair. Compare the response with the `conf.json` fields above, then write the config with the same validation as `wgcf-connector.sh`.
6. **Check CORS** on each endpoint, which decides whether a browser version is possible.
7. **Find the delete call** (probably authenticated with `reg.json`'s `api_token`) for CI cleanup.

## Open questions

- Does registration accept a Curve25519 key directly, or is the MASQUE-then-WireGuard two-step required?
- What are the token's fields, and which parts go into which request?
- How is a registration deleted?
- Is `additional_interface_ips` needed in `Address`?
- What `CF-Client-Version` or user agent does the API require, and does it reject old values over time? If so, CI needs to track WARP releases like wgcf-connector's `auto-update.yaml` does.

## Carry over from wgcf-connector

- **Workflows to copy:** `build-and-push.yaml` (native per-arch builds, push by digest, test, merge), `auto-update.yaml` (patch release per WARP bump) and the semver tag scheme. Always release with `gh release create`, not a bare tag push: `auto-update.yaml` computes the next version from the latest GitHub Release.
- **Testing without a token:** stub `warp-cli`/`warp-svc` scripts that copy fake `reg.json`/`conf.json` fixtures, mounted over `/usr/local/bin`. The same fixture approach works for stubbing `curl` responses.
- **Testing with a token:** never paste it into the chat. Save it with `read -rs t && printf %s "$t" > ~/.mesh-token && chmod 600 ~/.mesh-token` in the VS Code terminal, and pass it as `"$(cat ~/.mesh-token)"`. Redact `PrivateKey` and the organization when showing output.
- **Tunnel test:** `alpine` with `--cap-add NET_ADMIN --sysctl net.ipv6.conf.all.disable_ipv6=0 --sysctl net.ipv4.conf.all.src_valid_mark=1`, `wireguard-tools-wg-quick`, and the config without its `DNS` line (Alpine's `wg-quick` needs resolvconf for it). Then check `https://1.1.1.1/cdn-cgi/trace`.

## Environment notes

- The dev container shell is **zsh**: write `${img}:latest`, not `$img:latest` (zsh reads `:l` as a modifier), and unmatched globs are errors. Use `bash` for test scripts.
- Docker-in-Docker works, including `--privileged` and `NET_ADMIN`. `binfmt_misc` isn't mounted, so there's no QEMU for `docker run`; BuildKit still emulates `RUN` steps. `warp-svc` doesn't start under QEMU anyway (`NetworkInfoError`).
- `gh` is logged in as AnimMouse with `repo`, `read:org`, `gist` and `write:packages`.
