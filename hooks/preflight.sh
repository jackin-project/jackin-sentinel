#!/usr/bin/env sh

# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

set -eu

LC_ALL=C
export LC_ALL

state_dir=/sandbox/.sentinel
log=$state_dir/preflight.log
flag=${SENTINEL_FAIL_PREFLIGHT:-0}

fail() {
    printf '%s\n' "sentinel preflight: $1" >&2
    exit 78
}

single_line() {
    case $1 in
        *[[:cntrl:]]*) return 1 ;;
    esac
    return 0
}

regular_log() {
    if [ -L "$1" ]; then
        return 1
    fi
    if [ -e "$1" ]; then
        [ -f "$1" ] || return 1
    fi
    return 0
}

single_line "$flag" || fail "SENTINEL_FAIL_PREFLIGHT holds control characters"

mkdir -p "$state_dir"
regular_log "$log" || fail "$log is not a regular file"

if [ "$flag" = 1 ]; then
    # shellcheck disable=SC2016
    timeout 5 sh -c 'printf "preflight fail flag=%s\n" "$1" >>"$2"' sh "$flag" "$log" || fail "writing $log failed"
    echo "sentinel preflight: SENTINEL_FAIL_PREFLIGHT=1" >&2
    exit 17
fi
# shellcheck disable=SC2016
timeout 5 sh -c 'printf "preflight ok flag=%s\n" "$1" >>"$2"' sh "$flag" "$log" || fail "writing $log failed"
