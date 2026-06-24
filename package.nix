{ lib, stdenv, odin, gcc, pkg-config, wayland-scanner
, wayland, cairo, librsvg, glib, gdk-pixbuf, pango, fontconfig, freetype
, wayland-protocols
}:

stdenv.mkDerivation {
  pname = "ribbon";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  nativeBuildInputs = [ odin gcc pkg-config wayland-scanner ];
  buildInputs = [ wayland cairo librsvg glib gdk-pixbuf pango fontconfig freetype ];

  buildPhase = ''
    runHook preBuild

    protocols="${wayland-protocols}/share/wayland-protocols"
    wayland-scanner client-header "$protocols/stable/xdg-shell/xdg-shell.xml" csrc/xdg-shell.h
    wayland-scanner private-code "$protocols/stable/xdg-shell/xdg-shell.xml" csrc/xdg-shell.c
    wayland-scanner client-header wlr-layer-shell-unstable-v1.xml csrc/wlr-layer-shell-unstable-v1.h
    wayland-scanner private-code wlr-layer-shell-unstable-v1.xml csrc/wlr-layer-shell-unstable-v1.c

    mkdir -p build
    cflags="$(pkg-config --cflags wayland-client cairo librsvg-2.0) -Icsrc -O2 -Wall"
    libs="$(pkg-config --libs wayland-client cairo librsvg-2.0) -lm -lrt"

    gcc -c $cflags csrc/render.c -o build/render.o
    gcc -c $cflags csrc/wlr-layer-shell-unstable-v1.c -o build/wlr-layer-shell-unstable-v1.o
    gcc -c $cflags csrc/xdg-shell.c -o build/xdg-shell.o

    odin build src -out:build/ribbon \
      -extra-linker-flags:"$(pwd)/build/render.o $(pwd)/build/wlr-layer-shell-unstable-v1.o $(pwd)/build/xdg-shell.o $libs"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp build/ribbon $out/bin/ribbon
    runHook postInstall
  '';

  meta.mainProgram = "ribbon";
}
