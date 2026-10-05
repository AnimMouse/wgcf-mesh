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

> [!WARNING]
> **A wgcf-mesh node can't serve IPv6 CIDR routes.** Tested 2026-10-02 on a MASQUE device profile: Cloudflare IPv4 and IPv6 addresses and IPv4 CIDR routes work over wgcf-mesh's WireGuard tunnel, and a wgcf-mesh node can reach IPv6 CIDR routes served by official-client nodes. But Cloudflare doesn't route a wgcf-mesh node's own IPv6 CIDR routes, in either direction. With the official WARP client on MASQUE, they work. This matches [Cloudflare's docs](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/get-started/), which also list hostname routes and high availability as not working with WireGuard; those two haven't been tested with wgcf-mesh yet. If you need any of them, use the official client.

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

### Name a device
Each device is called `wgcf-mesh` in the Cloudflare dashboard unless you name it. You can also set its model, OS version and serial number:
```
bash wgcf-mesh.sh --name hq-router --model RB5009UG+S+ --os-version 7.20.1 --serial-number HGF09ABCDEF - < token.txt
```
To change these later, pass the device profile and the options to change:
```
bash wgcf-mesh.sh --update wgcf-mesh-<registration_id>.json --name branch-router
```
Each value can be up to 100 bytes. Cloudflare keeps only the version number from the OS version if it finds one, so `RouterOS 7.20.1` is shown as `7.20.1`. The `# Device name:` comment in an existing configuration file isn't updated.

### Register a client device with a service token
Instead of a Mesh node, you can register a headless client device with a [service token](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/), the same way the official client does with `auth_client_id` and `auth_client_secret` in `mdm.xml`. One service token can register any number of devices, and you don't create anything in the dashboard per device.
1. Create a service token, and a device enrollment rule with the **Service Auth** action for it.
2. Pass your team name, the token's Client ID, and its Client Secret on standard input:
   ```
   bash wgcf-mesh.sh --organization <team-name> --client-id <client-id>.access --client-secret - < secret.txt
   ```
   Both values can also be pasted as the dashboard copies them, like `CF-Access-Client-Id: <client-id>.access`.

A client device gets its own Mesh IP and can reach Mesh nodes and the subnets behind them, but it **can't advertise CIDR routes**. For a router that serves a LAN, register a Mesh node with a Mesh token instead. The `--name`, `--update` and `--delete` options work the same for both.

### Delete a device
Each run registers a new device on the Mesh node. To delete one you no longer use, pass its device profile:
```
bash wgcf-mesh.sh --delete wgcf-mesh-<registration_id>.json
```
This deletes the device from Cloudflare, and its configuration stops working. The profile and configuration files are kept; delete them yourself when you no longer need them. Devices without a profile can be removed in the Cloudflare dashboard.

### Options
| Option | Use |
| --- | --- |
| `--name <name>` | Device name in the Cloudflare dashboard. `wgcf-mesh` by default. |
| `--model <model>` | Device model. |
| `--os-version <version>` | OS version. |
| `--serial-number <serial>` | Serial number. |
| `--organization <team>` | Zero Trust team name, to register a client device with a service token. |
| `--client-id <id>` | Service token Client ID. |
| `--client-secret <secret>` | Service token Client Secret, or `-` to read it from standard input. |
| `--update <profile>` | Change the name, model, OS version or serial number of the device saved in a device profile. |
| `--delete <profile>` | Delete the device saved in a `wgcf-mesh-<registration_id>.json` device profile. The files are kept. |
| `--delete-after` | Delete the registration right after writing the configuration, so the configuration no longer works, and write no device profile. For testing. |

## How it works
See [API.md](API.md) for the protocol. The API is undocumented, and Cloudflare can change it without notice. A scheduled CI test checks it still works.

This project is not affiliated with or endorsed by Cloudflare.
