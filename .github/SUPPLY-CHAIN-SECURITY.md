<!-- nemtus-owned doc. Not from upstream symbol/symbol; survives mirror-sync. -->
# Supply-chain hardening (Socket) — nemtus/symbol

This mirror ingests upstream `symbol/symbol` dependencies automatically every day
(`mirror-sync.yml`) and republishes npm packages via OIDC. To stop a malicious or
compromised dependency from reaching a release, we layer [Socket](https://socket.dev)
on top. **Cost: $0** — Socket is free and unlimited for public/open-source repos, and
Socket Firewall Free needs no account or API key.

## The three layers

1. **Socket GitHub App — PR-time scanning (all ecosystems).**
   Scans dependency-manifest changes on every PR (especially the daily `mirror-sync`
   PR) and posts a comment + a Check Run. Covers npm, Python, Rust, and C/C++
   (`client/catapult/conanfile.py`, `vcpkg.json`). Tuned by [`socket.yml`](../socket.yml).

2. **Socket Firewall (`sfw`) — install-time hard gate in CI.**
   Every `npm ci` in `mirror-ci.yml`, `publish.yml`, and `openapi-publish.yml` runs as
   `sfw npm ci`. `sfw` is installed by Socket's official action, **pinned to a commit SHA**
   (`SocketDev/action@…  # v1.3.2`, `mode: firewall-free`) — so `pinact.yml` enforces the
   pin and Dependabot bumps it for us; no hand-edited version string to maintain. A
   confirmed-malicious package fails the install — and the job — before it can build or
   publish. `sfw` supports npm/yarn/pnpm, pip/uv, and cargo; it does **not** support
   C/C++ (Conan/vcpkg), so C++ relies on layers 1 & 3.

3. **Required status check — merge-time hard gate (all ecosystems).**
   The Socket check is a required status check on `dev`, so no PR (including C++ changes)
   merges while Socket flags an unresolved high-severity risk.

## One-time manual setup (no code, $0)

- **Install the Socket GitHub App** on `nemtus/symbol` from the GitHub Marketplace
  (public repo → free). It picks up `socket.yml` automatically.
- **Make the Socket check required:** Settings → Branches → branch protection for `dev`
  → Require status checks to pass → add the Socket check. Do this only after confirming
  the dashboard alert policy doesn't block on benign alerts (e.g. native code in crypto
  deps), or every PR will need a manual override.
- Optionally review the org/repo alert policy in the Socket dashboard (block vs. warn).

- Confirm **Dependabot is enabled** (default-on for public repos). The nemtus
  `.github/dependabot.yml` is scoped to the `github-actions` ecosystem only, so it keeps
  the SHA-pinned actions — including the Socket gate — current via reviewed weekly PRs,
  without touching the mirror's upstream-tracked npm/cargo deps.

Both `socket.yml` (repo root) and `.github/dependabot.yml` are **owned by the nemtus
layer**: `.github/scripts/apply-nemtus-patch.sh` rewrites them verbatim on every sync, so
edit them in that script (not the files) — `mirror-ci.yml`'s no-drift check enforces this.

## Local developer use (optional, free)

Block malware on your own machine / in Jenkins by prefixing `sfw`:

```sh
npm i -g sfw        # latest is fine locally; CI pins via SocketDev/action
sfw npm ci          # JavaScript (sdk/javascript, openapi, client/rest)
sfw pip install -r requirements.txt   # Python (sdk/python, catbuffer/parser)
sfw cargo fetch     # Rust/WASM (sdk/javascript/wasm)
```

## Known limits

- C/C++ (Conan/vcpkg) has **no free install-time block** — covered by layers 1 & 3 only.
- `sfw` Free blocks only human-verified confirmed malware; AI-flagged (unconfirmed)
  packages are warned, not blocked — the App covers those at PR time.
- Socket does not auto-update dependencies (that's Dependabot/Renovate's job, out of scope).
