{
  config,
  lib,
  pkgs,
  hermesAgentPackage,
  ...
}:

let
  inherit (lib)
    concatMap
    concatMapStringsSep
    filterAttrs
    flatten
    mapAttrs
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    nameValuePair
    optional
    optionals
    types
    ;

  cfg = config.services.hermesMultiUser;
  enabledInstances = filterAttrs (_: instance: instance.enable) cfg.instances;

  isSafeRelativePath =
    path:
    path != ""
    && !lib.hasPrefix "/" path
    && builtins.match "([A-Za-z0-9_+@.-]+/)*[A-Za-z0-9_+@.-]+" path != null
    && lib.all (part: part != "" && part != "." && part != "..") (lib.splitString "/" path);

  parentDirectories =
    path:
    let
      parts = lib.splitString "/" path;
    in
    map (depth: lib.concatStringsSep "/" (lib.take depth parts)) (lib.range 1 ((lib.length parts) - 1));

  isReservedProfilePath =
    path:
    path == ".env"
    || path == "cache"
    || path == "cron"
    || path == "logs"
    || path == "memories"
    || path == "runtime"
    || path == "sessions"
    || lib.hasPrefix ".env/" path
    || lib.hasPrefix "cache/" path
    || lib.hasPrefix "cron/" path
    || lib.hasPrefix "logs/" path
    || lib.hasPrefix "memories/" path
    || lib.hasPrefix "runtime/" path
    || lib.hasPrefix "sessions/" path;

  instanceType = types.submodule (
    { name, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether this Hermes instance is enabled.";
        };

        user = mkOption {
          type = types.str;
          description = "Existing normal NixOS user that runs this instance.";
        };

        group = mkOption {
          type = types.str;
          default = "hermes-${name}";
          description = "Private Unix group used only by this Hermes instance.";
        };

        stateDirectory = mkOption {
          type = types.strMatching "[A-Za-z0-9][A-Za-z0-9_-]*";
          default = "hermes-${name}";
          description = "Directory name below /var/lib for this isolated instance.";
        };

        environmentSecretName = mkOption {
          type = types.str;
          default = "hermes-${name}-env";
          description = "SOPS key containing this instance's dotenv environment.";
        };

        profile.files = mkOption {
          type = types.attrsOf (
            types.submodule {
              options = {
                secretName = mkOption {
                  type = types.str;
                  description = "SOPS key containing the private file content.";
                };

                mode = mkOption {
                  type = types.enum [
                    "0640"
                    "0750"
                  ];
                  default = "0640";
                  description = "Mode after root deploys the stable profile file.";
                };
              };
            }
          );
          default = { };
          description = ''
            Stable, encrypted profile files keyed by their relative HERMES_HOME
            destination. Values are deployed from sops-nix at runtime, never
            rendered by Nix. Use this for config, persona, skills, plugins,
            tool settings, and platform configuration.
          '';
        };

        extraArgs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Additional non-secret arguments for `hermes gateway`.";
        };
      };
    }
  );

  instanceStateDir = instance: "/var/lib/${instance.stateDirectory}";
  instanceHermesHome = instance: "${instanceStateDir instance}/home";
  instanceWorkspace = instance: "${instanceStateDir instance}/workspace";
  profileUnitName = name: "hermes-profile-${name}";
  serviceUnitName = name: "hermes-${name}";

  runtimeDirectories = [
    "cache"
    "cron"
    "logs"
    "memories"
    "runtime"
    "runtime/config"
    "sessions"
  ];

  instanceSecretNames =
    instance:
    [ instance.environmentSecretName ]
    ++ map (file: file.secretName) (lib.attrValues instance.profile.files);

  allSecretNames = flatten (map instanceSecretNames (lib.attrValues enabledInstances));

  installProfile =
    name: instance:
    let
      stateDir = instanceStateDir instance;
      hermesHome = instanceHermesHome instance;
      workspace = instanceWorkspace instance;
      profileFiles = mapAttrsToList (
        destination: file:
        let
          secretPath = config.sops.secrets.${file.secretName}.path;
        in
        ''
          destination=${lib.escapeShellArg destination}
          ${pkgs.coreutils}/bin/install -D -o root -g ${lib.escapeShellArg instance.group} -m ${file.mode} \
            ${lib.escapeShellArg secretPath} "$stage/profile/$destination"
        ''
      ) instance.profile.files;
      profileParentDirectories = lib.unique (
        concatMap parentDirectories (lib.attrNames instance.profile.files)
      );
      profileDirectorySetup = map (destination: ''
        managed_dir=${lib.escapeShellArg "${hermesHome}/${destination}"}
        if [ -L "$managed_dir" ] || [ -f "$managed_dir" ]; then
          ${pkgs.coreutils}/bin/rm -f -- "$managed_dir"
        fi
        ${pkgs.coreutils}/bin/install -d -o root -g ${lib.escapeShellArg instance.group} -m 0750 "$managed_dir"
      '') profileParentDirectories;
      profileLinks = mapAttrsToList (destination: _: ''
        link=${lib.escapeShellArg "${hermesHome}/${destination}"}
        ${pkgs.coreutils}/bin/rm -rf -- "$link"
        ${pkgs.coreutils}/bin/ln -s "${stateDir}/profile/${destination}" "$link"
      '') instance.profile.files;
    in
    pkgs.writeShellScript "${profileUnitName name}-install" ''
      set -euo pipefail

      state_dir=${lib.escapeShellArg stateDir}
      hermes_home=${lib.escapeShellArg hermesHome}
      workspace=${lib.escapeShellArg workspace}
      environment_secret=${lib.escapeShellArg config.sops.secrets.${instance.environmentSecretName}.path}

      test -r "$environment_secret" || {
        echo "${profileUnitName name}: missing separately deployed environment secret" >&2
        exit 1
      }

      stage="$(${pkgs.coreutils}/bin/mktemp -d "$state_dir/.profile.XXXXXXXX")"
      cleanup() {
        ${pkgs.coreutils}/bin/rm -rf -- "$stage"
      }
      trap cleanup EXIT

      ${pkgs.coreutils}/bin/install -d -o ${lib.escapeShellArg instance.user} -g ${lib.escapeShellArg instance.group} -m 0700 "$hermes_home"
      ${concatMapStringsSep "\n" (path: ''
        ${pkgs.coreutils}/bin/install -d -o ${lib.escapeShellArg instance.user} -g ${lib.escapeShellArg instance.group} -m 0700 "$hermes_home/${path}"
      '') runtimeDirectories}
      ${pkgs.coreutils}/bin/install -d -o ${lib.escapeShellArg instance.user} -g ${lib.escapeShellArg instance.group} -m 0700 "$workspace"
      ${pkgs.coreutils}/bin/install -d -o root -g ${lib.escapeShellArg instance.group} -m 0750 "$stage/profile"

      ${lib.concatStringsSep "\n" profileFiles}
      ${pkgs.findutils}/bin/find "$stage/profile" -type d \
        -exec ${pkgs.coreutils}/bin/chown root:${lib.escapeShellArg instance.group} {} + \
        -exec ${pkgs.coreutils}/bin/chmod 0750 {} +

      previous="$state_dir/profile.previous"
      ${pkgs.coreutils}/bin/rm -rf -- "$previous"
      if [ -e "$state_dir/profile" ]; then
        ${pkgs.coreutils}/bin/mv "$state_dir/profile" "$previous"
      fi
      ${pkgs.coreutils}/bin/mv "$stage/profile" "$state_dir/profile"
      ${pkgs.coreutils}/bin/rm -rf -- "$previous"

      ${pkgs.coreutils}/bin/install -o ${lib.escapeShellArg instance.user} -g ${lib.escapeShellArg instance.group} -m 0600 \
        "$environment_secret" "$hermes_home/.env"

      ${lib.concatStringsSep "\n" profileDirectorySetup}
      ${lib.concatStringsSep "\n" profileLinks}
    '';

  mkSopsSecret = name: instance: {
    owner = instance.user;
    group = instance.group;
    mode = "0400";
    restartUnits = [
      "${profileUnitName name}.service"
      "${serviceUnitName name}.service"
    ];
  };

  sopsSecrets = lib.foldl' lib.recursiveUpdate { } (
    mapAttrsToList (
      name: instance:
      {
        ${instance.environmentSecretName} = mkSopsSecret name instance;
      }
      // lib.foldl' lib.recursiveUpdate { } (
        mapAttrsToList (_: file: {
          ${file.secretName} = mkSopsSecret name instance;
        }) instance.profile.files
      )
    ) enabledInstances
  );
in
{
  options.services.hermesMultiUser = {
    enable = mkEnableOption "isolated, system-managed Hermes gateway instances";

    package = mkOption {
      type = types.package;
      default = hermesAgentPackage;
      description = "The upstream Hermes package used by every instance.";
    };

    instances = mkOption {
      type = types.attrsOf instanceType;
      default = { };
      description = "Named Hermes instances run as existing normal users.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = enabledInstances != { };
        message = "services.hermesMultiUser.enable requires at least one enabled instance.";
      }
      {
        assertion = lib.all (instance: instance.profile.files ? "config.yaml") (
          lib.attrValues enabledInstances
        );
        message = "Every enabled Hermes instance must deploy encrypted profile.files.\"config.yaml\".";
      }
      {
        assertion = lib.all (instance: lib.all isSafeRelativePath (lib.attrNames instance.profile.files)) (
          lib.attrValues enabledInstances
        );
        message = "Hermes profile file destinations must be safe, non-empty relative paths.";
      }
      {
        assertion = lib.all (
          instance: lib.all (path: !isReservedProfilePath path) (lib.attrNames instance.profile.files)
        ) (lib.attrValues enabledInstances);
        message = "Hermes profile files must not replace mutable runtime paths or .env.";
      }
      {
        assertion = lib.length allSecretNames == lib.length (lib.unique allSecretNames);
        message = "Every Hermes environment and profile file must use a distinct SOPS secret key.";
      }
      {
        assertion =
          lib.length (lib.attrNames enabledInstances)
          == lib.length (lib.unique (map (instance: instance.user) (lib.attrValues enabledInstances)));
        message = "An operating-system user may own only one enabled Hermes instance.";
      }
      {
        assertion = lib.all (
          instance:
          builtins.hasAttr instance.user config.users.users
          && config.users.users.${instance.user}.isNormalUser
        ) (lib.attrValues enabledInstances);
        message = "Every enabled Hermes instance must reference an existing normal NixOS user.";
      }
    ];

    users.groups = lib.listToAttrs (
      mapAttrsToList (_: instance: nameValuePair instance.group { }) enabledInstances
    );
    users.users = lib.listToAttrs (
      mapAttrsToList (
        _: instance:
        nameValuePair instance.user {
          extraGroups = [ instance.group ];
        }
      ) enabledInstances
    );

    sops.secrets = sopsSecrets;

    systemd.services =
      (lib.mapAttrs' (
        name: instance:
        nameValuePair (profileUnitName name) {
          description = "Deploy the stable encrypted profile for Hermes ${name}";
          requires = lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
          after = lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
          before = [ "${serviceUnitName name}.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "root";
            Group = instance.group;
            UMask = "0077";
            StateDirectory = instance.stateDirectory;
            StateDirectoryMode = "0750";
            ExecStart = installProfile name instance;
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ (instanceStateDir instance) ];
          };
        }
      ) enabledInstances)
      // (lib.mapAttrs' (
        name: instance:
        nameValuePair (serviceUnitName name) {
          description = "Hermes gateway for ${instance.user}";
          wantedBy = [ "multi-user.target" ];
          requires = [ "${profileUnitName name}.service" ];
          after = [
            "network-online.target"
            "${profileUnitName name}.service"
          ];
          wants = [ "network-online.target" ];
          environment = {
            HOME = instanceHermesHome instance;
            HERMES_HOME = instanceHermesHome instance;
            HERMES_MANAGED = "true";
            XDG_CACHE_HOME = "${instanceHermesHome instance}/cache";
            XDG_CONFIG_HOME = "${instanceHermesHome instance}/runtime/config";
            XDG_STATE_HOME = "${instanceHermesHome instance}/runtime";
          };
          serviceConfig = {
            User = instance.user;
            Group = instance.group;
            WorkingDirectory = instanceWorkspace instance;
            ExecStart = lib.escapeShellArgs (
              [
                "${cfg.package}/bin/hermes"
                "gateway"
              ]
              ++ instance.extraArgs
            );
            Restart = "always";
            RestartSec = 5;
            UMask = "0077";
            NoNewPrivileges = true;
            CapabilityBoundingSet = "";
            AmbientCapabilities = "";
            LockPersonality = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectSystem = "strict";
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
            RestrictNamespaces = true;
            SystemCallArchitectures = "native";
            ReadWritePaths = [
              (instanceWorkspace instance)
              (instanceHermesHome instance)
            ];
          };
          path = [
            cfg.package
            pkgs.bash
            pkgs.coreutils
            pkgs.git
          ];
        }
      ) enabledInstances);
  };
}
