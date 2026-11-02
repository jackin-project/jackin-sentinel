#!/usr/bin/env sh

# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

set -eu

state_dir=/sandbox/.sentinel
mkdir -p "$state_dir"
printf 'setup flag=%s\n' "${SENTINEL_FAIL_PREFLIGHT-unset}" >>"$state_dir/setup.log"
