#!/usr/bin/env sh

# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

set -eu

state_dir=/sandbox/.sentinel
log=$state_dir/setup.log
prefix="setup launch=$JACKIN_LAUNCH_ID "
mkdir -p "$state_dir"
if [ ! -e "/sandbox/.jackin/setup-done-$JACKIN_LAUNCH_ID" ] && grep -qF -- "$prefix" "$log" 2>/dev/null; then
    exit 0
fi
printf '%sflag=%s\n' "$prefix" "${SENTINEL_FAIL_PREFLIGHT-unset}" >>"$log"
