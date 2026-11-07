#!/usr/bin/env sh

# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

set -eu

state_dir=/sandbox/.sentinel
mkdir -p "$state_dir"
flag=${SENTINEL_FAIL_PREFLIGHT:-0}
if [ "$flag" = 1 ]; then
    printf 'preflight fail flag=%s\n' "$flag" >>"$state_dir/preflight.log"
    echo "sentinel preflight: SENTINEL_FAIL_PREFLIGHT=1" >&2
    exit 17
fi
printf 'preflight ok flag=%s\n' "$flag" >>"$state_dir/preflight.log"
