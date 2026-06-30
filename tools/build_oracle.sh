#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

repo=${MINIPRO_ORACLE_SOURCE:-$HOME/repos/minipro}
out=${MINIPRO_ORACLE_BUILD:-zig-cache/oracle/minipro-src}

if [ ! -d "$repo" ]; then
    printf 'upstream minipro source not found: %s\n' "$repo" >&2
    exit 1
fi

rm -rf "$out"
mkdir -p "$(dirname "$out")"
cp -R "$repo" "$out"
make -C "$out" minipro
printf '%s/minipro\n' "$out"
