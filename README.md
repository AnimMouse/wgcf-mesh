# wgcf-mesh
Generate a [Cloudflare Mesh](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/) (formerly WARP Connector) WireGuard configuration without Docker or the WARP client.

Cloudflare Mesh is an overlay network like ZeroTier and Tailscale, but instead of connecting peer to peer, each node connects to the nearest Cloudflare PoP over WireGuard, like NordVPN Meshnet.

This is a single Bash script that registers a Mesh node by calling Cloudflare's API directly, the way [wgcf](https://github.com/ViRb3/wgcf) does for consumer WARP. Your WireGuard private key is generated locally and never leaves your machine. If this stops working, [wgcf-connector](https://github.com/AnimMouse/wgcf-connector) does the same with the official WARP client in Docker.

## Usage
1. Optional: set the Mesh node's [device profile](https://dash.cloudflare.com/?to=/:account/one/team-resources/devices/profiles) to WireGuard, as in [my tutorial](https://www.animmouse.com/p/setup-cloudflare-mesh-using-wireguard/#create-a-separate-device-profile-for-the-cloudflare-mesh-nodes). wgcf-mesh gets a working WireGuard configuration under either a WireGuard or a MASQUE device profile.
2. [Create a Mesh node](https://dash.cloudflare.com/?to=/:account/mesh) in the Cloudflare dashboard.
3. Copy the Cloudflare Mesh token, which starts with `eyJhIjoi`.
4. Run the script with the token:
   ```
   curl -fsSLO https://raw.githubusercontent.com/AnimMouse/wgcf-mesh/main/wgcf-mesh.sh
   bash wgcf-mesh.sh <token>
   ```
5. It writes two files to your current directory:
   - `wgcf-mesh-<registration_id>.conf`, the configuration to use in WireGuard.
   - `wgcf-mesh-<registration_id>.json`, the device profile. Keep it to delete the device later, see [Delete a device](#delete-a-device). It contains a token that can delete this device, so keep it private, but you don't need to copy it to the device that runs WireGuard.

> [!NOTE]
> According to [Cloudflare's docs](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/get-started/), hostname routes, IPv6 CIDR routes and high availability don't work when the Mesh node's device profile uses WireGuard. wgcf-mesh always sets up a WireGuard tunnel, and whether these features work with it under a MASQUE device profile hasn't been tested yet.

> [!TIP]
> To keep the token out of your shell history and process list, pass `-` and give the token on standard input: `bash wgcf-mesh.sh - < token.txt`

> [!TIP]
> If you got an endpoint IPv4 address starting with `162.159.192.x`, use `162.159.193.x` instead to have lower latency.

> [!TIP]
> You can check out my complete tutorial [here](https://www.animmouse.com/p/setup-cloudflare-mesh-using-wireguard/).

### Requirements
- Bash, `curl` and `jq` 1.6 or later.
- `wg` from wireguard-tools, or OpenSSL with X25519 support, to generate the key pair. macOS's built-in LibreSSL can't generate WireGuard keys, so on macOS install wireguard-tools: `brew install wireguard-tools`.

> [!TIP]
> You can use GitHub Codespaces for this.

### Delete a device
Each run registers a new device on the Mesh node. To delete one you no longer use, pass its device profile:
```
bash wgcf-mesh.sh --delete wgcf-mesh-<registration_id>.json
```
This deletes the device from Cloudflare and removes the profile, and its configuration stops working. Devices without a profile can be removed in the Cloudflare dashboard.

### Options
| Option | Use |
| --- | --- |
| `--delete <profile>` | Delete the device saved in a `wgcf-mesh-<registration_id>.json` device profile. |
| `--delete-after` | Delete the registration right after writing the configuration, so the configuration no longer works, and write no device profile. For testing. |

## How it works
See [API.md](API.md) for the protocol. The API is undocumented, and Cloudflare can change it without notice. A scheduled CI test checks it still works.

This project is not affiliated with or endorsed by Cloudflare.
