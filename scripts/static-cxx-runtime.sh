#!/bin/sh
# Prints a directory to pass as `-Xlinker -L<dir>` when building the glibc
# Linux release, so the binary needs no C++ runtime.
#
# Swift's static-stdlib link file ends with `-lstdc++` (and libgcc pulls in
# libgcc_s), because static Foundation bundles ICU. That makes an otherwise
# plain binary depend on libstdc++.so.6 and libgcc_s.so.1, which a minimal
# system may not have. The file is appended after any flags we pass, so
# `-Bstatic` cannot reach it.
#
# Instead, put a linker script named libstdc++.so earlier on the search path
# than the real shared library: `-lstdc++` then resolves to the script,
# which names the static archive. Same for `-lgcc_s`. No toolchain patching.
set -eu

out=${1:?usage: $0 <output directory>}
mkdir -p "$out"

# Whichever compiler the image has can name libgcc's archives; Swift's
# toolchain ships clang, and a bare container may have no gcc at all.
cc=$(command -v clang || command -v cc || command -v gcc)

for pair in "libstdc++.so:libstdc++.a" "libgcc_s.so:libgcc_eh.a"; do
  name=${pair%%:*}
  archive=$("$cc" -print-file-name="${pair#*:}")
  case $archive in
    /*) ;;
    *) echo "static-cxx-runtime: cannot locate ${pair#*:} ($archive)" >&2; exit 1 ;;
  esac
  if [ ! -f "$archive" ]; then
    echo "static-cxx-runtime: ${pair#*:} not installed ($archive)" >&2
    exit 1
  fi
  echo "INPUT ( $archive )" > "$out/$name"
done
