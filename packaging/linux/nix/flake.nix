# ArchoeraMusic NixOS 打包入口（消费预构建 bundle，与 Arch PKGBUILD 同模式）。
#
# 使用（CI/本地）：
#   1. bash packaging/linux/package.sh nix <bundle> <版本>
#      → 生成 packaging/linux/work/nix/{flake.nix, package.nix, bundle/, desktop, icon}
#      （版本号注入 package.nix 的 version）
#   2. nix --extra-experimental-features "nix-command flakes" build .#default
#
# 说明：bundle 是构建期产物（Flutter App + FFI/引擎子进程），不入 git，
# 因此本 flake 不能直接 `nix build github:...` 消费（需先跑 package.sh 预置）；
# NixOS 安装方式见 package.nix 头部注释。
{
  description = "ArchoeraMusic — 开源音乐播放器（NixOS 打包）";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self
    , nixpkgs
    }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.callPackage ./package.nix { };
          archoera-music = self.packages.${system}.default;
        });
    };
}
