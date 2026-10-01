# Cloudflare Mesh registration API

How `wgcf-mesh.sh` registers a Cloudflare Mesh node. This API is undocumented: it was worked out from the Linux WARP client (`warp-svc` 2026.7.1377.0) on 2026-10-01 and can change without notice. `wgcf-mesh.sh` is the reference implementation.

## Overview

1. Decode the Mesh token to get the account tag.
2. Generate a WireGuard (Curve25519) key pair locally.
3. `POST` the public key and the token to the registration endpoint. The response contains everything the WireGuard config needs.
4. Optionally, delete the registration later using the `token` from the response. `wgcf-mesh.sh --delete-after` does this right after writing the config, for testing.

There is no second step. The WARP client registers a P-256 MASQUE key first and then rotates it to a WireGuard key, but that only happens because it sends `tunnel_key_data`. Leave that field out and the server accepts the WireGuard key directly.

## Host and headers

- Host: `https://api.devices.cloudflare.com`. `zero-trust-client.cloudflareclient.com` (same IPs) and `api.cloudflareclient.com` also answer these paths.
- No client version header, user agent or other special header is required. Send `Content-Type: application/json` with JSON bodies.
- No CORS: `OPTIONS` returns 404 and no response has `Access-Control-*` headers, so a browser page can't call the API.

## The token

The Mesh token from the dashboard is base64-encoded JSON, starting with `eyJhIjoi`:

| Field | Length | Meaning |
| --- | --- | --- |
| `a` | 32 hex characters | Account tag, used in the URL path |
| `t` | 36, UUID | Tunnel ID |
| `s` | 88, base64 | Tunnel secret |

The client never uses `t` or `s` on its own. It sends the whole token, unchanged, in the request body.

## Register

```
POST /v1/accounts/{a}/warp_connector
Content-Type: application/json
```
```json
{
  "type": "linux",
  "name": "wgcf-mesh",
  "key": "<base64 Curve25519 public key>",
  "tos": "2026-10-01T00:00:00Z",
  "warp_connector_token": "<token, unchanged>"
}
```

- `key` is required (`3006 missing key field`).
- **Don't send `tunnel_key_data`.** `{"key_type": "curve25519", "tunnel_type": "wireguard"}` is rejected with `2004 bad device request`.
- The WARP client also sends `model`, `os_version`, `gateway_device_id`, `serial_number`, `identifiers` and `mtls_csr`. None are required.

A successful response has status `200` and `"success": true`. Fields used by `wgcf-mesh.sh`:

| Field | Example | Use |
| --- | --- | --- |
| `result.id` | `t.01a0f4c0-…` | Registration ID, for the filename and later calls |
| `result.token` | UUID | Bearer token for `/reg/{id}` calls |
| `result.key` | | Our public key, echoed back. Check it matches |
| `result.account.organization` | | Team name, written as a comment |
| `result.config.interface.addresses.v4` | `100.96.0.17` | `Address`, as `/32` |
| `result.config.interface.addresses.v6` | `2606:4700:cf1:1000::11` | `Address`, as `/128` |
| `result.config.peers[0].public_key` | `bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=` | Peer `PublicKey` |
| `result.config.peers[0].endpoint.v4` | `162.159.193.5:0` | Endpoint address. The port is always `0` |
| `result.config.peers[0].endpoint.v6` | `[2606:4700:100::a29f:c105]:0` | Endpoint address. The port is always `0` |
| `result.config.peers[0].endpoint.ports` | `[2408, 500, 1701, 4500]` | Ports to combine with each address |

Other fields in the response (not used yet):

- `result.config.peers[0].endpoint.host` (`engage.cloudflareclient.com:2408`)
- `result.connector.additional_interfaces.ipv6[]`: an address of the Mesh node rather than the device, the same for every registration on that node (e.g. `2606:4700:cf1:2000::1`). The official client adds it to its interface as a deprecated, receive-only address. See `HANDOFF.md`.
- `result.connector.routes.{ipv4,ipv6}[]` and `result.connector.nat_mode`: probably the node's advertised routes.
- `result.policy`, the device profile. Its `tunnel_protocol` is empty under a WireGuard profile and `"masque"` under a MASQUE one. Either way the registration returns a working WireGuard config (verified 2026-10-01), so `wgcf-mesh.sh` ignores it.
- `result.peer`, `result.user`, `result.override_codes` (secrets), `result.dex_tests`, and timestamps.

## Get a registration

```
GET /v1/accounts/{a}/reg/{id}
Authorization: Bearer <result.token>
```

Returns `200` with the same `result` as the registration response.

## Delete a registration

```
DELETE /v1/accounts/{a}/reg/{id}
Authorization: Bearer <result.token>
```

Returns `204` with an empty body. After that, the token is rejected with `401` (`2016 unauthorized`).

## Errors

Errors return a non-2xx status and `"success": false`:

```json
{"result": null, "success": false, "errors": [{"code": 3004, "message": "invalid warp_connector_token"}], "messages": []}
```

| Code | Status | Message | Cause |
| --- | --- | --- | --- |
| 2004 | 400 | `bad device request` | Body rejected, e.g. because `tunnel_key_data` was sent |
| 2016 | 401 | `unauthorized` | Bad or deleted bearer token |
| 3004 | 400 | `invalid warp_connector_token` | Token not valid for this account |
| 3006 | 400 | `missing key field` | No `key` in the body |

## WireGuard config

`wgcf-mesh.sh` writes `wgcf-mesh-<result.id>.conf` in the same layout as wgcf-connector:

```
# Registration ID: <result.id>
# Organization: <result.account.organization>
[Interface]
PrivateKey = <our private key>
Address = <v6>/128, <v4>/32
DNS = 2606:4700:4700::1111, 2606:4700:4700::1001, 1.1.1.1, 1.0.0.1
MTU = 1420

[Peer]
PublicKey = <peer public key>
AllowedIPs = ::/0, 0.0.0.0/0
Endpoint = <endpoint v4 address>:<first port>
#Endpoint = <every other address and port pair>
```

The endpoint lines go through each port in order and list the IPv4 address before the IPv6 address for each one.
