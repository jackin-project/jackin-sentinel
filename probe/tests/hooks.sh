#!/bin/sh
# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0
set -u

here=$(cd "$(dirname "$0")" && pwd)
hooks=$here/../../hooks
scratch=$(mktemp -d) || exit 70
trap 'rm -rf "$scratch"' EXIT
failures=0
total=0

mk() {
    t=$scratch/$1
    rm -rf "$t"
    mkdir -p "$t/sandbox/.jackin"
    sed "s#/sandbox#$t/sandbox#g" "$hooks/setup.sh" >"$t/setup.sh"
}

run_setup() {
    launch=$1
    shift
    env -i PATH="$PATH" JACKIN_LAUNCH_ID="$launch" "$@" sh "$t/setup.sh"
    rc=$?
    check "${t##*/} exits zero" "$rc" 0
}

lines() {
    if [ -f "$t/sandbox/.sentinel/setup.log" ]; then
        wc -l <"$t/sandbox/.sentinel/setup.log" | tr -d ' '
    else
        echo 0
    fi
}

check() {
    total=$((total + 1))
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        failures=$((failures + 1))
        echo "FAIL $1: got [$2] want [$3]"
    fi
}

mk first_run_logs_one_line
run_setup L1
check first_run_logs_one_line "$(lines)" 1

mk crash_retry_before_the_marker_adds_no_line
run_setup L1
run_setup L1
run_setup L1
check crash_retry_before_the_marker_adds_no_line "$(lines)" 1

mk crash_retry_with_another_flag_adds_no_line
run_setup L1
run_setup L1 SENTINEL_FAIL_PREFLIGHT=1
check crash_retry_with_another_flag_adds_no_line "$(lines)" 1

mk a_run_after_the_marker_is_counted
run_setup L1
: >"$t/sandbox/.jackin/setup-done-L1"
run_setup L1
check a_run_after_the_marker_is_counted "$(lines)" 2

mk the_marker_of_another_launch_does_not_hide_a_retry
: >"$t/sandbox/.jackin/setup-done-L0"
run_setup L1
run_setup L1
check the_marker_of_another_launch_does_not_hide_a_retry "$(lines)" 1

mk another_launch_is_counted
run_setup L1
: >"$t/sandbox/.jackin/setup-done-L1"
run_setup L2
check another_launch_is_counted "$(lines)" 2

mk a_launch_id_that_extends_another_is_counted
run_setup L10
run_setup L1
check a_launch_id_that_extends_another_is_counted "$(lines)" 2

mk a_missing_launch_id_fails_the_hook
env -i PATH="$PATH" sh "$t/setup.sh" 2>/dev/null
rc=$?
check a_missing_launch_id_fails_the_hook "$([ "$rc" -ne 0 ] && echo failed)" failed
check a_missing_launch_id_logs_nothing "$(lines)" 0

echo "$total cases, $failures failed"
[ "$failures" -eq 0 ]
