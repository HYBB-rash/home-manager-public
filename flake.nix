{
  description = "User's NixOS and Home Manager configuration";

  inputs = {
    # 日常软件使用固定发行分支；Codex 等需要新版本的软件单独从 unstable 获取。
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      # 复用本 flake 的 nixpkgs，避免 Home Manager 再引入一套不同版本的软件包。
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-flatpak.url = "github:gmodena/nix-flatpak/main";

    cc-switch-cli = {
      # Upstream CLI replacement for the previously packaged CC Switch AppImage.
      url = "github:SaladDay/cc-switch-cli/v5.10.0";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agent-learning = {
      url = "path:/home/user/Agent/home-manager";
      flake = false;
    };


    codex-desktop-linux = {
      # 固定到已验证的提交，避免上游更新未经确认就改变桌面端行为。
      url = "github:ilysenko/codex-desktop-linux/main";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    hermes-agent = {
      # NixOS 模块管理服务，Desktop 包由 Home Manager 安装到用户环境。
      url = "github:NousResearch/hermes-agent";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      codex-desktop-linux,
      hermes-agent,
      nix-flatpak,
      cc-switch-cli,
      sops-nix,
      agent-learning,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # 高频应用单独跟随 unstable，并只放行其中实际使用的非自由软件。
      pkgsUnstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfreePredicate =
          package:
          builtins.elem (nixpkgs.lib.getName package) [
            "qq"
            "vivaldi"
            "widevine-cdm"
            "claude-code"
          ];
      };

      # Codex Desktop 的上游二次封装和 Home Manager 集成集中在独立组件中。
      codexDesktopBundle = import ./home/applications/codex-desktop/package.nix {
        inherit pkgs;
        codexDesktop = codex-desktop-linux.packages.${system}.default;
        codexCli = pkgs.lib.getExe' pkgsUnstable.codex "codex";
      };

      nixosConfiguration = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          hermesAgentPackage = hermes-agent.packages.${system}.default;
        };
        modules = [
          sops-nix.nixosModules.sops
          ./configuration.nix
        ];
      };
      wechatVmConfiguration = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/virtualbox-image.nix"
          ./vm/wechat-exporter.nix
        ];
      };
      homeConfiguration = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;

        # 将 unstable 包集注入 home/ 下各模块的参数。
        extraSpecialArgs = {
          inherit pkgsUnstable;
          ccSwitchCli = cc-switch-cli.packages.${system}.default;
          hermesDesktop = hermes-agent.packages.${system}.desktop;
          inherit codexDesktopBundle;
        };

        modules = [
          nix-flatpak.homeManagerModules.nix-flatpak
          (import "${agent-learning}/agent-learning-sync.nix")
          ./home
        ];
      };
    in
    {
      nixosConfigurations.nixos = nixosConfiguration;
      nixosConfigurations.wechat-exporter = wechatVmConfiguration;
      homeConfigurations.user = homeConfiguration;

      packages.${system}.wechat-exporter-vm = wechatVmConfiguration.config.system.build.virtualBoxOVA;

      # 开发工具只在进入 `nix develop` 时可用，不写入 Home Manager 环境。
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.nodejs
          pkgs.python3
          pkgs.pnpm
        ];
      };

      # `nix flake check` 同时验证 NixOS 和完整的 Home Manager 配置。
      checks.${system} = {
        nixos = nixosConfiguration.config.system.build.toplevel;
        home-manager = homeConfiguration.activationPackage;
        wechat-snapshot-read-only = pkgs.testers.runNixOSTest (
          import ./tests/wechat-snapshot.nix { inherit pkgs; }
        );
        wechat-project-release = pkgs.runCommand "wechat-project-release-tests" {
          nativeBuildInputs = [ pkgs.python3 ];
        } ''
          export WECHAT_PROJECT_RELEASE_MODULE=${./system/wechat-project-release.py}
          python3 ${./tests/test_wechat_project_release.py}
          touch "$out"
        '';
        wechat-exporter-lan-firewall =
          assert wechatVmConfiguration.config.virtualbox.params.nic1 == "nat";
          assert wechatVmConfiguration.config.virtualbox.params.nic2 == "nat";
          assert wechatVmConfiguration.config.virtualbox.params.macaddress2 == "080027A11CE2";
          assert builtins.elem "enp0s8"
            wechatVmConfiguration.config.networking.firewall.trustedInterfaces;
          pkgs.runCommand "wechat-exporter-lan-firewall" { } ''
            touch "$out"
          '';
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
