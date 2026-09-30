# wgcf-mesh

Generates a Cloudflare Mesh (formerly WARP Connector) WireGuard config by calling Cloudflare's undocumented registration API directly, without Docker or the WARP client. Like [ViRb3/wgcf](https://github.com/ViRb3/wgcf) and [poscat0x04/wgcf-teams](https://github.com/poscat0x04/wgcf-teams).

- `HANDOFF.md` holds the current state, findings, plan and open questions. Read it first, and update it as findings come in.
- `/workspaces/refs/wgcf-connector` is the Docker-based sibling project (uses `warp-cli`). It is the reference for what a correct config looks like and for CI workflows. Don't edit it from here.

## Implementation rules

- **Bash is the canonical implementation.** Use `curl`, `jq`, and `wg genkey` or `openssl genpkey -algorithm X25519`, falling back to `wg` because macOS LibreSSL may lack X25519. No Go or Rust.
- **`API.md` documents the protocol**: endpoints, methods, headers, request and response fields. Keep it in sync with the script.
- **Output must match `wgcf-connector.sh`**: the same filename (`wgcf-connector-<registration_id>.conf` unless a new name is decided), the same `[Interface]`/`[Peer]` layout, `Address = <v6>/128, <v4>/32`, the same DNS line, `MTU = 1420`, the first endpoint active and the rest as `#Endpoint =` comments.
- **Never report success when something failed.** Fail fast. Read each value once with `jq -er`, reject missing, `null` or empty values, and validate them all before writing. Never write a partial file. Use `umask 077` so the file is mode 600. `set -e` doesn't catch a failing `$(...)` inside a heredoc, so don't put command substitutions there.
- **Browser version only if CORS allows it.** Never proxy requests through a server we run: users' Mesh tokens must not pass through it.

## Secrets and testing

- **Never ask for the Mesh token in chat, and never print it.** It lives in `~/.mesh-token`, saved by the user with `read -rs t && printf %s "$t" > ~/.mesh-token && chmod 600 ~/.mesh-token`. Use it as `"$(cat ~/.mesh-token)"`.
- When inspecting the token or API responses, print key names, types and lengths, not values. Redact `PrivateKey`, `secret_key`, `api_token` and the organization in anything shown.
- **Only use throwaway Mesh nodes.** Every registration creates a new device on the node, so delete test registrations afterwards. CI must delete what it creates.
- **Test without a token** by stubbing `curl` with JSON fixtures, the same way wgcf-connector stubs `warp-cli`/`warp-svc`.
- **Tunnel test:** an `alpine` container with `--cap-add NET_ADMIN --sysctl net.ipv6.conf.all.disable_ipv6=0 --sysctl net.ipv4.conf.all.src_valid_mark=1` and `wireguard-tools-wg-quick`, using the config without its `DNS` line. A working tunnel shows `warp=on` at `https://1.1.1.1/cdn-cgi/trace`.

## Environment

- The interactive shell is **zsh**: write `${img}:latest`, not `$img:latest` (zsh reads `:l` as a modifier), and unmatched globs are errors. Write test scripts in `bash`.
- Docker-in-Docker works, including `--privileged` and `NET_ADMIN`. There's no QEMU for `docker run`, and `warp-svc` won't run under emulation anyway.
- `gh` is logged in as AnimMouse.

## Releases and CI

- Use semver tags, and always release with `gh release create` rather than a bare tag push. Workflows compute the next version from the latest GitHub Release.
- Copy workflow patterns from wgcf-connector's `.github/workflows/`. Pin actions to major versions, and `dependabot.yaml` updates them weekly.
- Check Cloudflare's terms before publishing anything.
