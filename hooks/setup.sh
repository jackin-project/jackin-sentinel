#!/usr/bin/env sh

# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

set -eu

LC_ALL=C
export LC_ALL

state_dir=/sandbox/.sentinel
log=$state_dir/setup.log
launch_id=$JACKIN_LAUNCH_ID
flag=${SENTINEL_FAIL_PREFLIGHT-unset}

fail() {
    printf '%s\n' "sentinel setup: $1" >&2
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

single_line "$launch_id" || fail "the launch id holds control characters"
single_line "$flag" || fail "SENTINEL_FAIL_PREFLIGHT holds control characters"

prefix="setup launch=$launch_id "
mkdir -p "$state_dir"
if [ ! -e "/sandbox/.jackin/setup-done-$launch_id" ]; then
    regular_log "$log" || fail "$log is not a regular file"
    if [ -f "$log" ]; then
        grep_rc=0
        timeout 5 grep -qF -- "$prefix" "$log" 2>/dev/null || grep_rc=$?
        if [ "$grep_rc" -eq 0 ]; then
            exit 0
        elif [ "$grep_rc" -ne 1 ]; then
            fail "reading $log failed"
        fi
    fi
fi
regular_log "$log" || fail "$log is not a regular file"
# shellcheck disable=SC2016
timeout 5 sh -c 'printf "%sflag=%s\n" "$1" "$2" >>"$3"' sh "$prefix" "$flag" "$log" || fail "writing $log failed"
