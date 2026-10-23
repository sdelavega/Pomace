#!/bin/bash
# Read Mach-O rpaths for release cleanup and bundle validation.
macho_rpaths() {
  otool -l "$1" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { rpath = 1; next }
    rpath && $1 == "path" { sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; rpath = 0 }
  '
}
