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

## License

AGPL-3.0-only (upstream Sure license).
