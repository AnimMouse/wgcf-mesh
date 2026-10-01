# wgcf-mesh

Generates a Cloudflare Mesh (formerly WARP Connector) WireGuard config by calling Cloudflare's undocumented registration API directly, without Docker or the WARP client. Like [ViRb3/wgcf](https://github.com/ViRb3/wgcf) and [poscat0x04/wgcf-teams](https://github.com/poscat0x04/wgcf-teams).

- `HANDOFF.md` holds the current state, findings, plan and open questions. Read it first, and update it as findings come in.
- `/workspaces/refs/wgcf-connector` is the Docker-based sibling project (uses `warp-cli`). It is the reference for what a correct config looks like and for CI workflows. Don't edit it from here.

## Implementation rules

- **Bash is the canonical implementation.** Use `curl`, `jq`, and `wg genkey` or `openssl genpkey -algorithm X25519`, preferring `wg`. macOS's LibreSSL 3.3.6 lacks X25519 (verified in CI), so macOS users need `brew install wireguard-tools`. No Go or Rust.
- **`API.md` documents the protocol**: endpoints, methods, headers, request and response fields. Keep it in sync with the script.
- **Output must match `wgcf-connector.sh`**: the same `[Interface]`/`[Peer]` layout, but the filename is `wgcf-mesh-<id>.conf`, plus a `wgcf-mesh-<id>.json` device profile (`<id>` is the registration's `result.id`). `Address = <v6>/128, <v4>/32`, the same DNS line, `MTU = 1420`, plus `PersistentKeepalive = 60` (not in wgcf-connector) so a node behind NAT stays reachable, the first endpoint active and the rest as `#Endpoint =` comments.
- **Never report success when something failed.** Fail fast. Read each value once with `jq -er`, reject missing, `null` or empty values, and validate them all before writing. Never write a partial file. Use `umask 077` so the file is mode 600. `set -e` doesn't catch a failing `$(...)` inside a heredoc, so don't put command substitutions there.
- **Browser version only if CORS allows it.** Never proxy requests through a server we run: users' Mesh tokens must not pass through it.

## Commands

- Offline tests: `bash tests/test.sh` (stubs `curl` with `tests/stub/curl` and `tests/fixtures/`).
- Lint, the same as CI's Lint job (versions pinned in `.github/workflows/ci.yaml`; shfmt style comes from `.editorconfig`):
  ```
  docker run --rm -v "$PWD:/mnt" -w /mnt mvdan/shfmt:v3.14.1 -d .
  docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.11.0 $(docker run --rm -v "$PWD:/mnt" -w /mnt mvdan/shfmt:v3.14.1 -f .)
  docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12
  docker run --rm -v "$PWD:/repo" -w /repo ghcr.io/zizmorcore/zizmor:1.30.1 --offline .
  ```
  To fix formatting, run shfmt with `-w` instead of `-d`.
- Real run without leaving a device behind: `./wgcf-mesh.sh --delete-after - < ~/.mesh-token`, or register normally and then `./wgcf-mesh.sh --delete wgcf-mesh-<id>.json`.

## Secrets and testing

- **Never ask for the Mesh token in chat, and never print it.** It lives in `~/.mesh-token`, saved by the user with `read -rs t && printf %s "$t" > ~/.mesh-token && chmod 600 ~/.mesh-token`. Use it as `"$(cat ~/.mesh-token)"`.
- When inspecting the token or API responses, print key names, types and lengths, not values. Redact `PrivateKey`, `secret_key`, `api_token` and the organization in anything shown.
- **Only use throwaway Mesh nodes.** Every registration creates a new device on the node, so delete test registrations afterwards. CI must delete what it creates.
- **Test without a token** by stubbing `curl` with JSON fixtures, the same way wgcf-connector stubs `warp-cli`/`warp-svc`.
- **Tunnel test:** an `alpine` container with `--cap-add NET_ADMIN --sysctl net.ipv6.conf.all.disable_ipv6=0 --sysctl net.ipv4.conf.all.src_valid_mark=1` and `wireguard-tools-wg-quick iptables ip6tables`, using the config without its `DNS` line. A working tunnel shows `warp=on` at `https://1.1.1.1/cdn-cgi/trace`.

## Environment

- The interactive shell is **zsh**: write `${img}:latest`, not `$img:latest` (zsh reads `:l` as a modifier), and unmatched globs are errors. Write test scripts in `bash`.
- Docker-in-Docker works, including `--privileged` and `NET_ADMIN`. There's no QEMU for `docker run`, and `warp-svc` won't run under emulation anyway.
- `gh` is logged in as AnimMouse.

## Workflow

- **Never commit to `main`.** Branch, push, and open a PR with `gh pr create`. A ruleset on `main` requires a PR and the `CI` check.
- Run the tests and linters locally before pushing.
- Merge only when the user asks, and only once CI is green. Squash is the only merge method. Write the squash commit yourself instead of keeping GitHub's default list of commit messages:
  ```
  gh pr merge <n> --squash --delete-branch --subject "<PR title> (#<n>)" --body "<summary>"
  ```
  The subject is the PR title in Conventional Commits form, plus the PR number. The body summarizes the whole change in a few lines, not commit by commit, and ends with the `Co-Authored-By` trailer.
- The repo's own default squash message (used when merging in the web UI) is the PR title plus every commit's message, which keeps their trailers.

## Releases and CI

- Use semver tags, and always release with `gh release create` rather than a bare tag push. Workflows compute the next version from the latest GitHub Release.
- `ci.yaml` runs on every PR and push to `main`: a Detect changes job, a Lint job (ShellCheck, shfmt, actionlint, zizmor), the offline tests on Ubuntu with OpenSSL, Ubuntu with `wg`, and macOS with Homebrew's `wg`, and a final `CI` job that fails unless all the others passed. Only `CI` is a required check. `ci.yaml` has no workflow-level path filters, because a required check from a skipped workflow never reports. Instead, Detect changes skips Lint and the tests when every changed file is a root `*.md` file or `LICENSE`, and `CI` accepts skipped jobs only if Detect changes succeeded. Every job has a `timeout-minutes`. `smoke-test.yaml` runs daily against the real API with the `MESH_TOKEN` secret. Copy patterns from wgcf-connector's `.github/workflows/`. Pin GitHub's `actions/*` to major versions and hash-pin third-party actions (`.github/zizmor.yml` enforces this). `dependabot.yaml` updates them weekly after a 7-day cooldown. Give every workflow `permissions: {}` and grant each job only what it needs.
- Check Cloudflare's terms before publishing anything.

## Roadmap

Planned features, in priority order. Leads come from `strings` on `warp-svc` and its logs (see `HANDOFF.md`) and are unverified unless stated. Document each new call in `API.md` as it is verified.

Main features:

1. **Service token auth.** Register with a Cloudflare Access service token instead of a Mesh token. Leads: the client's `RegistrationAuthMethod` has an `AccessServiceToken { id, key }` variant, and the binary has `cf-access-client-id`/`cf-access-client-secret` header names.
2. ~~**Device profile for later deletion.**~~ Done: every registration also writes `wgcf-mesh-<id>.json` (mode 600) with the account tag, `result.id` and `result.token`, and `--delete <profile>` deletes the device. The profile stays out of the WireGuard config. The smoke test registers and then deletes through the profile.
3. **Custom device name and metadata** shown in the dashboard: `name`, plus `model`, `os_version`, `serial_number` and `type`. These are the registration body fields `warp-svc` sends. Check which ones the dashboard shows, and whether they can be changed after registration, probably with `PATCH /v1/accounts/{a}/reg/{id}`.

To verify:

- **Mesh features that need MASQUE.** Cloudflare's [Get started](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/get-started/) page says: "Hostname routes, IPv6 CIDR routes, and high availability do not work if the device profile uses WireGuard instead." wgcf-mesh always produces a WireGuard tunnel, even under a MASQUE device profile.
  - **IPv6 CIDR routes: tested 2026-10-02, don't work.** Between two nodes on a MASQUE profile, IPv6 traffic to a CIDR route leaves the sender's WireGuard tunnel and never reaches the other node. Cloudflare IPv4/IPv6 addresses and IPv4 CIDR routes work. The official client on MASQUE passes the same test. A mixed test showed it's server-side, not a WireGuard limit: a WireGuard device can reach a MASQUE node's IPv6 route, but Cloudflare doesn't route IPv6 CIDR routes owned by a WireGuard registration, either to it or from it. Setup and results are in `HANDOFF.md`.
  - Still to test: hostname routes and high availability.
  - Untested idea: the server may program IPv6 routes only for registrations made with `tunnel_key_data` `masque`/`secp256r1`. Ours omit it, and a MASQUE tunnel would need a MASQUE implementation, so this probably can't be fixed in Bash.

Nice to have:

1. **Device posture heartbeat**, so the device shows as alive in the dashboard's Devices tab. The tunnel works without it, so it must stay optional, for example a command to run periodically on the server. Leads: `/v0/accounts/{a}/reg/{id}/posture` and `/v0/accounts/{a}/reg/{id}/devicestate`, and the registration response's `last_seen`.
2. **Consumer WARP profile**, like [ViRb3/wgcf](https://github.com/ViRb3/wgcf). Leads: the consumer API host `api.cloudflareclient.com` also answers our paths, and wgcf documents the consumer registration.
3. **Standalone Zero Trust devices** that aren't Mesh nodes, like [poscat0x04/wgcf-teams](https://github.com/poscat0x04/wgcf-teams). They register with a team login JWT instead of a Mesh token. Leads: wgcf-teams, and the `Cf-Access-Jwt-Assertion` header in the binary.
