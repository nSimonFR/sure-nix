# sure-nix

Nix flake packaging [Sure](https://github.com/we-promise/sure) — a self-hosted personal finance manager (community fork of Maybe Finance).

Provides:
- `packages.sure` — the Sure Rails application, with gems vendored via `bundlerEnv` and assets precompiled at build time
- `nixosModules.sure` — a NixOS module that configures Puma (web), Sidekiq (worker), and a DB migration oneshot service
- `overlays.default` — exposes `pkgs.sure`

## Prerequisites

`Gemfile`, `Gemfile.lock`, and `gemset.nix` must be present in the flake root before building. They are generated from the upstream source via:

```bash
./scripts/update-gemset.sh 0.6.8
```

Then paste the printed `hash` into `package.nix`.

## Usage

### Standalone build

```bash
nix build github:nSimonFR/sure-nix
```

### NixOS module

```nix
# flake.nix
inputs.sure-nix.url = "github:nSimonFR/sure-nix";

# configuration.nix
imports = [ inputs.sure-nix.nixosModules.sure ];

services.sure = {
  enable          = true;
  port            = 3000;
  environmentFile = "/run/secrets/sure-env";  # exports SECRET_KEY_BASE
  databaseUrl     = "postgresql://sure_user@127.0.0.1/sure_production";
  redisUrl        = "redis://127.0.0.1:6379/0";
};
```

The `environmentFile` must export at minimum:
```
SECRET_KEY_BASE=<64-byte hex string>
```

### Module options

| Option | Default | Description |
|---|---|---|
| `enable` | `false` | Enable Sure |
| `package` | flake default | Override the derivation |
| `port` | `3000` | Puma listen port |
| `dataDir` | `/var/lib/sure` | Persistent state directory (storage, tmp) |
| `user` / `group` | `sure` | Service user/group |
| `databaseUrl` | — | Full `DATABASE_URL` (required) |
| `redisUrl` | `redis://127.0.0.1:6379/0` | `REDIS_URL` for Sidekiq and cache |
| `environmentFile` | `null` | Path to a `KEY=VALUE` secrets file |
| `settings` | `{}` | Additional environment variables |

## Updating Sure

1. Run `./scripts/update-gemset.sh <new-version>`
2. Paste the printed hash into `package.nix`
3. Commit `Gemfile`, `Gemfile.lock`, `gemset.nix`, and `package.nix`

## Systemd services

| Unit | Type | Description |
|---|---|---|
| `sure-setup.service` | oneshot | Runs `rails db:migrate` on every boot |
| `sure-web.service` | simple | Puma HTTP server |
| `sure-worker.service` | simple | Sidekiq background job processor |

`sure-web` and `sure-worker` both depend on `sure-setup`.

## Setup for AI coding agents

This section orients an AI agent (or any new contributor) to the codebase: toolchain, build/test workflow, the load-bearing tailwindcss patch, and the hard rules to follow.

### Toolchain

- **Ruby 3.4.x** — `.ruby-version` pins `3.4.7`; nixpkgs provides `ruby_3_4 = 3.4.8`. The mismatch is intentional and handled by `package.nix` (the `ruby file: ".ruby-version"` directive is stripped from the Gemfile via `patchedGemfile`, and the `RUBY VERSION` section is stripped from `Gemfile.lock` by `scripts/update-gemset.sh`). Do not try to "fix" either to match — both directions break Bundler frozen mode.
- **Bundler 2.6.9** — `BUNDLED WITH` line at the bottom of `Gemfile.lock`. Provided transitively by `ruby_3_4`.
- **Node.js** — needed only at build time for asset precompilation (propshaft + tailwindcss). Pulled in via `nativeBuildInputs`.
- **bundix** — used by `scripts/update-gemset.sh` to regenerate `gemset.nix`. Fetched on-demand from nixpkgs (`nix build nixpkgs#bundix`); not in any dev shell.

### Nix dev shell

There is no `devShells` output in `flake.nix` yet, so `nix develop` falls back to the implicit shell for `packages.default` (i.e. `sure`). That gives you Ruby + the full bundlerEnv as build inputs but no extra dev tooling. For ad-hoc Ruby/Bundler/bundix commands, prefer:

```bash
nix shell nixpkgs#ruby_3_4 nixpkgs#bundler nixpkgs#bundix
```

### Building the package

```bash
# Build the package for the host platform
nix build

# Or against a specific system
nix build .#sure --system aarch64-linux

# Standalone, from GitHub
nix build github:nSimonFR/sure-nix
```

The result is `result/share/sure/` (the Rails app, assets precompiled) plus `result/bin/{sure-web,sure-worker,sure-rails}` wrappers.

### Testing the NixOS module

The fastest end-to-end check is to dry-build a host that imports the module. Inside the nic-os flake (which already uses `services.sure`):

```bash
# From the consuming flake
sudo nixos-rebuild build --flake /home/nsimon/nic-os#rpi5

# Or with the local checkout as the input (override the flake URL)
sudo nixos-rebuild build \
  --flake /home/nsimon/nic-os#rpi5 \
  --override-input sure-nix path:/home/nsimon/sure-nix
```

Per nic-os memory: always commit before invoking `nixos-rebuild`; never use `--impure`; new files must be `git add`ed (Nix builds from the git index).

### The tailwindcss-ruby gotcha — load-bearing

`tailwindcss-ruby` 4.x ships a **Bun-bundled binary** that hardcodes `/lib/ld-linux-*.so.*` as its dynamic linker. On NixOS that path does not exist, so the binary won't run for asset precompilation.

**Fix (already in `package.nix`):**

```nix
patchelf \
  --set-interpreter "${glibc}/lib/${twPlatformInfo.ldSo}" \
  "$TWDIR/exe/${twPlatformInfo.gemPlatform}/tailwindcss"
export LD_LIBRARY_PATH="${glibc}/lib:${stdenv.cc.cc.lib}/lib"
```

**Do NOT use `patchelf --set-rpath` instead.** The Bun-bundled binary stores its layout in a way that `--set-rpath` corrupts; the result segfaults at startup. The combination is specifically:

1. `patchelf --set-interpreter` to point at NixOS' `ld-linux-*.so.*` under `${glibc}/lib`.
2. `LD_LIBRARY_PATH` exporting `${glibc}/lib:${stdenv.cc.cc.lib}/lib` so `libstdc++.so.6` resolves at runtime.

If you ever bump `twVersion` in `package.nix`, re-prefetch the platform gem (`nix-prefetch-url https://rubygems.org/gems/tailwindcss-ruby-<VER>-<PLATFORM>.gem`) and update `twPlatformInfo.sha256` for both `aarch64-linux` and `x86_64-linux`. Leave the patchelf incantation alone.

### Updating the Sure upstream pin

Bumping Sure's version touches three things in this flake:

1. **`version`** and **`hash`** in `package.nix` (the `fetchFromGitHub` `src`).
2. **`Gemfile`, `Gemfile.lock`, `.ruby-version`** copied from the new upstream tag.
3. **`gemset.nix`** regenerated by `bundix` against the new lockfile.

All four are handled by `./scripts/update-gemset.sh <VERSION>`. The script:

- Clones `we-promise/sure` at `v<VERSION>`.
- Copies `Gemfile`, `Gemfile.lock`, `.ruby-version`.
- Runs `bundle lock --add-platform ruby` to add source-gem entries (needed because `BUNDLE_FORCE_RUBY_PLATFORM=1` won't resolve platform-only gems).
- Strips the `RUBY VERSION` block from `Gemfile.lock`.
- Runs a patched `bundix` (with a nil-fix monkey-patch) to regenerate `gemset.nix`.
- Rewrites platform-gem hashes in `gemset.nix` to the source-gem hash (because `bundlerEnv` downloads source gems even when the lockfile lists platform variants).
- Patches `version` and `hash` in `package.nix`.

After running the script, commit all five files together:

```bash
git add Gemfile Gemfile.lock .ruby-version gemset.nix package.nix
git commit -m "chore: update Sure to v<VERSION>"
```

To regenerate **only `gemset.nix`** after a manual `Gemfile.lock` edit (e.g. a Dependabot bump), the relevant fragment is:

```bash
nix build --print-out-paths --no-link 'nixpkgs#bundix'
# then run the wrapped bundix from that store path; see scripts/update-gemset.sh
```

In practice, just re-run the full script — its steps are idempotent.

### nixpkgs input

`flake.nix` follows `nixpkgs/nixos-unstable`. `nix flake update --update-input nixpkgs` bumps it. Run lock updates with `sudo` if the resulting lock will be consumed by `nixos-rebuild` on the same host (Nix 2.31.2 user/root narHash mismatch — see nic-os memory).

### GitHub account — hard rule

Every `gh` and `git` push operation must use the `nSimonFR-ai` account, never the personal `nSimonFR`. Before any GitHub op:

```bash
gh auth switch -u nSimonFR-ai
```

### Commit style

Recent history (`git log --oneline`) shows a loose convention:

- `Fix(<scope>): ...` for targeted fixes (e.g. `Fix(package): ...`, `Fix(lockfile): ...`)
- `fix: ...`, `chore: ...`, `feat: ...` for broader changes
- `Refactor: ...`, `Debug: ...` occasionally
- Dependabot bumps use `Bump <gem> from X to Y`

Match the prevailing style of nearby commits when picking a prefix. Keep summaries imperative and under ~70 chars.

### Minimal module-usage example

Copied from `module.nix` header — the smallest functional `services.sure` block:

```nix
imports = [ inputs.sure-nix.nixosModules.sure ];

services.sure = {
  enable          = true;
  environmentFile = "/run/agenix/sure-app-env";   # SECRET_KEY_BASE=…
  databaseUrl     = "postgresql://sure_user@127.0.0.1/sure_production";
  redisUrl        = "redis://127.0.0.1:6379/2";
};
```

The consuming host is responsible for PostgreSQL (DB + user + password) and Redis. See `rpi5/sure.nix` in nic-os for a complete deployment (pg setup oneshot, agenix secret, Tailscale Serve, etc.).

## License

AGPL-3.0-only (upstream Sure license).
