#!/usr/bin/env bash
set -euo pipefail
mkdir -p build
WLR="wlr-layer-shell-unstable-v1"
SRC="src"
CSRC="csrc"

# generate wayland protocol code if missing
if [ ! -f "${CSRC}/${WLR}.c" ]; then
  echo "Generating protocol code..."
  DATA_DIRS=$(pkg-config --variable=pkgdatadir wayland-protocols 2>/dev/null || true)
  if [ -z "$DATA_DIRS" ]; then
    echo "ERROR: wayland-protocols not found" >&2
    exit 1
  fi

  XDG_XML=""
  for d in $(echo "$DATA_DIRS" | tr ':' ' '); do
    for sub in "$d/stable/xdg-shell" "$d/staging/xdg-shell"; do
      test -f "$sub/xdg-shell.xml" && { XDG_XML="$sub/xdg-shell.xml"; break; }
    done
    [ -n "$XDG_XML" ] && break
  done
  if [ -z "$XDG_XML" ]; then
    echo "ERROR: cannot find xdg-shell.xml" >&2
    exit 1
  fi

  WLR_XML=""
  for d in $(echo "$DATA_DIRS" | tr ':' ' '); do
    for sub in "$d/unstable/wlr-layer-shell" "$d/staging/wlr-layer-shell"; do
      test -f "$sub/wlr-layer-shell-unstable-v1.xml" && { WLR_XML="$sub/wlr-layer-shell-unstable-v1.xml"; break; }
    done
    [ -n "$WLR_XML" ] && break
  done
  if [ -z "$WLR_XML" ]; then
    if [ ! -f "wlr-layer-shell-unstable-v1.xml" ]; then
      echo "Downloading wlr-layer-shell-unstable-v1.xml"
      curl -sL "https://raw.githubusercontent.com/swaywm/wlr-protocols/master/unstable/wlr-layer-shell-unstable-v1.xml" -o "wlr-layer-shell-unstable-v1.xml"
    fi
    WLR_XML="wlr-layer-shell-unstable-v1.xml"
  fi

  wayland-scanner client-header "$XDG_XML" "${CSRC}/xdg-shell.h"
  wayland-scanner private-code "$XDG_XML" "${CSRC}/xdg-shell.c"
  wayland-scanner client-header "$WLR_XML" "${CSRC}/${WLR}.h"
  wayland-scanner private-code "$WLR_XML" "${CSRC}/${WLR}.c"
fi

# compile C files to objects
echo "Compiling C objects..."
PKGCFLAGS="$(pkg-config --cflags wayland-client cairo librsvg-2.0) -I${CSRC}"
PKGLIBS="$(pkg-config --libs wayland-client cairo librsvg-2.0)"

gcc -c -O2 -Wall $PKGCFLAGS "${CSRC}/render.c" -o build/render.o
gcc -c -O2 -Wall $PKGCFLAGS "${CSRC}/${WLR}.c" -o "build/${WLR}.o"
gcc -c -O2 -Wall $PKGCFLAGS "${CSRC}/xdg-shell.c" -o build/xdg-shell.o

# build Odin binary
echo "Building ribbon..."
odin build "${SRC}" \
  -out:build/ribbon \
  -extra-linker-flags:"build/render.o build/wlr-layer-shell-unstable-v1.o build/xdg-shell.o $PKGLIBS -lrt -lm"

echo "Done: build/ribbon"
