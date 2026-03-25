# NixOS module for Sure — self-hosted personal finance manager.
#
# Usage in nic-os (or any NixOS flake):
#
#   inputs.sure-nix.url = "github:nSimonFR/sure-nix";
#
#   # In your nixosSystem specialArgs or imports:
#   imports = [ inputs.sure-nix.nixosModules.sure ];
#   services.sure.enable = true;
#   services.sure.environmentFile = "/run/agenix/sure-app-env";
#   services.sure.databaseUrl     = "postgresql://sure_user@127.0.0.1/sure_production";
#   services.sure.redisUrl        = "redis://127.0.0.1:6379/2";
#
# The environmentFile must export at minimum:
#   SECRET_KEY_BASE=<64-byte hex>
#   POSTGRES_PASSWORD=<password>     # used in databaseUrl if it contains %PGPASSWORD%
#                                    # OR handled via pgpass / databaseUrl directly
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.sure;
  defaultPackage = pkgs.callPackage (self + "/package.nix") { };

  # Directory layout under cfg.dataDir:
  #   storage/   — Active Storage uploads (persistent)
  #   tmp/       — Puma pidfile, cache (ephemeral but must survive service restart)
  #   log/       — Rails log (optional; RAILS_LOG_TO_STDOUT avoids it)
in
{
  options.services.sure = {
    enable = lib.mkEnableOption "Sure personal finance manager";

    package = lib.mkOption {
      type        = lib.types.package;
      default     = defaultPackage;
      description = "The Sure derivation to use.";
    };

    port = lib.mkOption {
      type        = lib.types.port;
      default     = 3000;
      description = "Port Puma (web server) listens on.";
    };

    dataDir = lib.mkOption {
      type        = lib.types.str;
      default     = "/var/lib/sure";
      description = "Directory for persistent runtime state (storage, tmp).";
    };

    user  = lib.mkOption { type = lib.types.str; default = "sure"; };
    group = lib.mkOption { type = lib.types.str; default = "sure"; };

    databaseUrl = lib.mkOption {
      type        = lib.types.str;
      example     = "postgresql://sure_user:PASSWORD@127.0.0.1/sure_production";
      description = "Full DATABASE_URL for the Rails app (may include password).";
    };

    redisUrl = lib.mkOption {
      type        = lib.types.str;
      default     = "redis://127.0.0.1:6379/0";
      description = "REDIS_URL for Sidekiq and Rails cache.";
    };

    # Path to a file that will be loaded as an EnvironmentFile by systemd.
    # Must at minimum contain: SECRET_KEY_BASE=<hex>
    environmentFile = lib.mkOption {
      type        = lib.types.nullOr lib.types.str;
      default     = null;
      description = "Path to a file exporting secrets as KEY=VALUE lines.";
    };

    # Extra environment variables merged into all Sure services.
    settings = lib.mkOption {
      type    = lib.types.attrsOf lib.types.str;
      default = {};
      example = { RAILS_MAX_THREADS = "5"; WEB_CONCURRENCY = "2"; };
      description = "Additional environment variables for Sure services.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group        = cfg.group;
      home         = cfg.dataDir;
      createHome   = false;
    };
    users.groups.${cfg.group} = {};

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir}              0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/storage      0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/tmp          0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/log          0750 ${cfg.user} ${cfg.group} -"
    ];

    # ── Common environment shared by all Sure services ──────────────────────
    # Each service also loads cfg.environmentFile for secrets.
    # Active Storage: symlink storage/ and tmp/ into the nix-store app dir
    # via the setup service below so Rails finds them relative to RAILS_ROOT.

    # ── sure-setup: prepare writable dirs, run DB migrations ────────────────
    systemd.services.sure-setup = {
      description   = "Sure — first-run setup and database migrations";
      wantedBy      = [ "multi-user.target" ];
      # Caller is responsible for ordering postgresql before this service.
      serviceConfig = {
        Type             = "oneshot";
        RemainAfterExit  = true;
        User             = cfg.user;
        Group            = cfg.group;
        WorkingDirectory = "${cfg.package}/share/sure";

        # Writable paths for Rails internals
        PrivateTmp   = false;   # we manage tmp ourselves
        ProtectHome  = "read-only";
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.dataDir ];
      } // lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };

      environment = {
        RAILS_ENV          = "production";
        RAILS_LOG_TO_STDOUT = "true";
        DATABASE_URL       = cfg.databaseUrl;
        REDIS_URL          = cfg.redisUrl;
        PORT               = toString cfg.port;
        RAILS_STORAGE_PATH = "${cfg.dataDir}/storage";
        RAILS_TMP_PATH     = "${cfg.dataDir}/tmp";
        HOME               = cfg.dataDir;
      } // cfg.settings;

      script = ''
        set -euo pipefail
        # Migrations are idempotent; safe to run on every boot.
        ${cfg.package}/bin/sure-rails db:migrate
      '';
    };

    # ── sure-web: Puma HTTP server ───────────────────────────────────────────
    systemd.services.sure-web = {
      description = "Sure — Puma web server";
      after       = [ "network-online.target" "sure-setup.service" ];
      wants       = [ "network-online.target" ];
      requires    = [ "sure-setup.service" ];
      wantedBy    = [ "multi-user.target" ];

      serviceConfig = {
        Type             = "simple";
        User             = cfg.user;
        Group            = cfg.group;
        WorkingDirectory = "${cfg.package}/share/sure";
        ExecStart        = "${cfg.package}/bin/sure-web";
        Restart          = "on-failure";
        RestartSec       = "5s";
        PrivateTmp       = false;
        ProtectHome      = "read-only";
        ProtectSystem    = "strict";
        ReadWritePaths   = [ cfg.dataDir ];
      } // lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };

      environment = {
        RAILS_ENV           = "production";
        RAILS_LOG_TO_STDOUT = "true";
        DATABASE_URL        = cfg.databaseUrl;
        REDIS_URL           = cfg.redisUrl;
        PORT                = toString cfg.port;
        PIDFILE             = "${cfg.dataDir}/tmp/puma.pid";
        RAILS_STORAGE_PATH  = "${cfg.dataDir}/storage";
        RAILS_TMP_PATH      = "${cfg.dataDir}/tmp";
        HOME                = cfg.dataDir;
      } // cfg.settings;
    };

    # ── sure-worker: Sidekiq background job processor ───────────────────────
    systemd.services.sure-worker = {
      description = "Sure — Sidekiq worker";
      after       = [ "network-online.target" "sure-setup.service" ];
      wants       = [ "network-online.target" ];
      requires    = [ "sure-setup.service" ];
      wantedBy    = [ "multi-user.target" ];

      serviceConfig = {
        Type             = "simple";
        User             = cfg.user;
        Group            = cfg.group;
        WorkingDirectory = "${cfg.package}/share/sure";
        ExecStart        = "${cfg.package}/bin/sure-worker";
        Restart          = "on-failure";
        RestartSec       = "10s";
        PrivateTmp       = false;
        ProtectHome      = "read-only";
        ProtectSystem    = "strict";
        ReadWritePaths   = [ cfg.dataDir ];
      } // lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };

      environment = {
        RAILS_ENV           = "production";
        RAILS_LOG_TO_STDOUT = "true";
        DATABASE_URL        = cfg.databaseUrl;
        REDIS_URL           = cfg.redisUrl;
        RAILS_STORAGE_PATH  = "${cfg.dataDir}/storage";
        HOME                = cfg.dataDir;
      } // cfg.settings;
    };
  };
}
