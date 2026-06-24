{
  description = "ribbon — Wayland status bar with .rib DSL";

  nixConfig = {
    extra-substituters = [ "https://ribbon.cachix.org" ];
    extra-trusted-public-keys = [ "ribbon.cachix.org-1:1gncTaQfEIHh3mX9I0bi8nZ4WSKsPredqTrRwSSlT3g=" ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        packages = {
          ribbon = pkgs.callPackage ./package.nix {};
          default = self.packages.${system}.ribbon;
        };
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            odin gcc pkg-config wayland wayland-scanner wayland-protocols wlr-protocols
            cairo librsvg glib gdk-pixbuf pango fontconfig freetype libxkbcommon
          ];
        };
      });
}
