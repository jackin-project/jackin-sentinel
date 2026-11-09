#!/bin/sh
# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0
set -u

here=$(cd "$(dirname "$0")" && pwd)
probe=$here/../jackin-sentinel-probe
scratch=$(mktemp -d) || exit 70
trap 'rm -rf "$scratch"' EXIT
failures=0
total=0

mkdir -p "$scratch/tools" "$scratch/shim"
for tool in awk basename base64 cat chmod cp cut date dirname env find grep head jq ls mkdir mkfifo mktemp mv od python3 readlink rm rmdir sed sha256sum sh sleep sort stat tail tee timeout touch tr wc git; do
    if [ "$tool" = jq ] && command -v mise >/dev/null 2>&1; then
        found=$(mise which jq) || exit 70
    else
        found=$(command -v "$tool") || {
            echo "FAIL setup: $tool is not installed"
            exit 70
        }
    fi
    ln -s "$found" "$scratch/tools/$tool"
done
real_id=$(command -v id) || exit 70
real_uname=$(command -v uname) || exit 70

R_OK1='jackin-env-kinds 2\nattempt 1\nmain GITHUB_TOKEN empty\nmain OPENAI_API_KEY placeholder\nagent GITHUB_TOKEN empty\nagent OPENAI_API_KEY placeholder\n'
R_W0='jackin-env-kinds 2\nattempt 0\nmain OPENAI_API_KEY placeholder\n'
R_EMPTY='jackin-env-kinds 2\nattempt 0\nmain GITHUB_TOKEN empty\n'
R_NOCODEX='jackin-env-kinds 2\nattempt 1\nmain OPENAI_API_KEY placeholder\n'
R_OTHER_MAIN='jackin-env-kinds 2\nattempt 1\nmain P73_FAKE_API_KEY other\nagent OPENAI_API_KEY placeholder\n'
R_OTHER_CODEX='jackin-env-kinds 2\nattempt 1\nmain OPENAI_API_KEY placeholder\nagent STRIPE_SECRET other\n'

mk() {
    t=$scratch/$1
    rm -rf "$t"
    mkdir -p "$t/bin" "$t/bad-bin" "$t/sandbox/.jackin/run" "$t/sandbox/project" "$t/proc/sys/kernel/random" "$t/tmp"
}

prepare_probe() {
    fixture_path=${1:-$t/bin:$scratch/shim:$scratch/tools}
    sed -e "s#/sandbox#$t/sandbox#g" -e "s#/proc/#$t/proc/#g" "$probe" >"$t/probe.impl"
    if grep -q '^SANDBOX_PATH=' "$t/probe.impl"; then
        sed "s#^SANDBOX_PATH=.*#SANDBOX_PATH=$fixture_path#" "$t/probe.impl" >"$t/probe.next" || return 1
        mv "$t/probe.next" "$t/probe.impl" || return 1
        grep -Fq "SANDBOX_PATH=$fixture_path" "$t/probe.impl" || return 1
        if grep -Fq 'SANDBOX_PATH=/usr/local/bin:/usr/bin:/bin' "$t/probe.impl"; then
            return 1
        fi
    fi
    cat >"$t/spec" <<EOF
{"target":{"tuple":"T01","agent":"codex","provider":"codex","model":"gpt-6.1-sol","adapter":"t01-codex-v1","spec_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"behavior":{"version":{"binary":"$t/bin/codex","exact_output":"codex-cli 0.167.0"},"process":{"comm":"codex","minimum_age_seconds":15},"prompt":{"argv":["$t/bin/codex","exec","--skip-git-repo-check","Reply with the word ready"],"answer":{"word_case_insensitive":{"word":"ready"}}},"credential":{"auth_file":{"path":"$t/sandbox/.codex/auth.json"}},"provider":{"probe_url":"https://chatgpt.com/backend-api/models","accepted_status":401,"accepted_body":{"json_error_code":{"code":"invalid_api_key"}}}}}
EOF
    cat >"$t/probe" <<EOF
#!/bin/sh
exec "$t/probe.impl" --spec "$t/spec" "\$@"
EOF
    chmod +x "$t/probe" "$t/probe.impl"
}

state() {
    printf '%s\n' "$1" >"$t/sandbox/.jackin/run/state"
}

record() {
    printf '%b' "$1" >"$t/sandbox/.jackin/run/env-kinds"
}

proc_main() {
    mkdir -p "$t/proc/100"
    printf '/usr/local/bin/jackin-start\0codex\0' >"$t/proc/100/cmdline"
    printf '100 (jackin-start) S 1 100 100 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0\n' >"$t/proc/100/stat"
}

proc_codex() {
    mkdir -p "$t/proc/101"
    printf 'codex\0--sandbox\0' >"$t/proc/101/cmdline"
    printf '101 (codex) S 100 100 100 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 101 0 0\n' >"$t/proc/101/stat"
}

environ() {
    pid=$1
    shift
    : >"$t/proc/$pid/environ"
    for pair in "$@"; do
        printf '%s\0' "$pair" >>"$t/proc/$pid/environ"
    done
}

cat_fail_for_proc() {
    target=$1
    prefix_bytes=$2
    real_cat=$(command -v cat) || return 1
    mkdir -p "$t/bin"
    cat >"$t/bin/cat" <<EOF
#!/bin/sh
if [ "\$#" -eq 1 ] && [ "\$1" = "$target" ]; then
    "$real_cat" "\$1" | head -c "$prefix_bytes"
    exit 1
fi
exec "$real_cat" "\$@"
EOF
    chmod +x "$t/bin/cat"
}

jq_fail_for_codex_filter() {
    real_jq=$(command -v jq) || return 1
    mkdir -p "$t/bin"
    cat >"$t/bin/jq" <<'EOF'
#!/bin/sh
if [ "${1-}" = -Rrs ]; then
    case " $* " in
        *" --arg source agent "*) exit 9 ;;
    esac
fi
exec "$SENTINEL_REAL_JQ" "$@"
EOF
    chmod +x "$t/bin/jq"
}

seam() {
    printf 's#^%s=.*#%s=%s#\n' "$1" "$1" "$2" >>"$t/seams.sed"
}

exit_shim() {
    real=$(command -v "$1")
    cat >"$t/bin/$1" <<EOF
#!/bin/sh
for last; do :; done
case \$last in
    $2) exit $3 ;;
esac
exec $real "\$@"
EOF
    chmod +x "$t/bin/$1"
}

setup_failed() {
    total=$((total + 1))
    failures=$((failures + 1))
    echo "FAIL $1: the test setup failed"
}

bounded() {
    limit=$1
    shift
    "$@" >"$scratch/bounded.out" 2>"$scratch/bounded.err" &
    pid=$!
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        ticks=$((ticks + 1))
        if [ "$ticks" -gt $((limit * 10)) ]; then
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.1
    done
    wait "$pid"
}

printf '#!/bin/sh\necho Linux\n' >"$scratch/shim/uname"
printf '#!/bin/sh\n[ "$*" = -un ] && echo sandbox && exit 0\nexec %s "$@"\n' "$real_id" >"$scratch/shim/id"
cat >"$scratch/shim/dd" <<'EOF'
#!/usr/bin/env python3
import os
import sys

arguments = dict(argument.split("=", 1) for argument in sys.argv[1:] if "=" in argument)
source = arguments.get("if")
destination = arguments.get("of")
if arguments.get("bs") != "65" or arguments.get("count") != "1" or arguments.get("iflag") != "nonblock,nofollow":
    raise SystemExit(64)
if not source or not destination:
    raise SystemExit(64)
if os.environ.get("SENTINEL_DD_SWAP_PATH") == source:
    os.unlink(source)
    os.symlink(os.environ["SENTINEL_DD_SWAP_TARGET"], source)
try:
    descriptor = os.open(source, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
except OSError:
    raise SystemExit(1)
try:
    data = os.read(descriptor, 65)
finally:
    os.close(descriptor)
descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
try:
    offset = 0
    while offset < len(data):
        offset += os.write(descriptor, data[offset:])
finally:
    os.close(descriptor)
EOF
chmod +x "$scratch/shim/uname" "$scratch/shim/id" "$scratch/shim/dd"

begin() {
    total=$((total + 1))
    name=$1
    shift
    problems=
    prepare_probe || {
        failures=$((failures + 1))
        echo "FAIL setup $name: the sandbox path fixture was not safely substituted"
        return
    }
    if [ -f "$t/expected-version" ]; then
        "$scratch/tools/jq" --arg version "$(cat "$t/expected-version")" ".behavior.version.exact_output = \$version" "$t/spec" >"$t/spec.next"
        mv "$t/spec.next" "$t/spec"
    fi
    if [ -f "$t/seams.sed" ]; then
        sed -f "$t/seams.sed" "$t/probe.impl" >"$t/probe.seamed" && mv "$t/probe.seamed" "$t/probe.impl"
        chmod +x "$t/probe.impl"
    fi
    bounded 20 env -i PATH="$t/bin:$scratch/shim:$scratch/tools" TMPDIR="$t/tmp" "$@"
    rc=$?
    cp "$scratch/bounded.out" "$t/out"
    cp "$scratch/bounded.err" "$t/err"
}

expect_rc() {
    [ "$rc" -eq "$1" ] || problems="$problems rc=$rc(want $1)"
}

expect_report() {
    jq -e --arg step "$1" --arg mode "$2" \
        '.schema == 3 and .probe == "jackin-sentinel-probe" and .mode == $mode and (.steps | keys) == [$step]' "$t/out" >/dev/null 2>&1 ||
        problems="$problems report-shape"
    if [ "$1" = J15 ]; then
        [ -f "$t/bin/docker-data/run.called" ] || problems="$problems run-not-invoked"
        [ -f "$t/bin/docker-data/info.called" ] || problems="$problems info-not-invoked"
    fi
}

expect() {
    check=$1
    want_result=$2
    want_detail=$3
    got_result=$(jq -r --arg n "$check" '.steps[].checks[] | select(.name == $n) | .result' "$t/out" 2>/dev/null)
    got_detail=$(jq -r --arg n "$check" '.steps[].checks[] | select(.name == $n) | .detail' "$t/out" 2>/dev/null)
    [ "$got_result" = "$want_result" ] || problems="$problems $check=$got_result(want $want_result)"
    case $got_detail in
        *"$want_detail"*) ;;
        *) problems="$problems $check.detail=[$got_detail](want [$want_detail])" ;;
    esac
}

fact() {
    filter=$1
    want=$2
    got=$(jq -r ".steps[].facts | $filter" "$t/out" 2>/dev/null)
    [ "$got" = "$want" ] || problems="$problems fact[$filter]=[$got](want [$want])"
}

detail_contains() {
    check=$1
    needle=$2
    got_detail=$(jq -r --arg n "$check" '.steps[].checks[] | select(.name == $n) | .detail' "$t/out" 2>/dev/null)
    case $got_detail in
        *"$needle"*) ;;
        *) problems="$problems $check.detail=[$got_detail](missing [$needle])" ;;
    esac
}

not_disclosed() {
    if grep -Fq "$1" "$t/out" || grep -Fq "$1" "$t/err"; then
        problems="$problems credential-disclosed"
    fi
}

no_raw_nul() {
    if od -An -v -tu1 "$t/out" "$t/err" | awk '{ for (i = 1; i <= NF; i++) if ($i == 0) found = 1 } END { exit !found }'; then
        problems="$problems raw-nul-in-output"
    fi
}

public_not_disclosed() {
    label=$1
    marker=$2
    if grep -Fq "$marker" "$t/out"; then
        problems="$problems ${label}_marker_in_public_report"
    fi
}

expect_usage() {
    expect_rc 64
    [ ! -s "$t/out" ] || problems="$problems stdout-not-empty"
    case $(cat "$t/err") in
        usage:*) ;;
        *) problems="$problems stderr=[$(cat "$t/err")](want usage)" ;;
    esac
}

finish_case() {
    if LC_ALL=C grep -q '[[:cntrl:]]' "$t/out"; then
        problems="$problems control-byte-in-report"
    fi
    if [ -n "$problems" ]; then
        failures=$((failures + 1))
        echo "FAIL $name:$problems"
    else
        echo "ok   $name"
    fi
}

finish_git_case() {
    if [ -n "$problems" ]; then
        cat "$t/out"
    fi
    finish_case
}

verify() {
    begin "$1" sh "$t/probe" --only J08
    expect_rc 0
    expect_report J08 sandbox
    expect environment "$2" "$3"
    fact '.start_record.state' "$4"
    finish_case
}

mk pass_via_record
state 'exited 1 0'
record "$R_OK1"
verify pass_via_record PASS 'via record' read

mk fail_other_in_main_at_attempt_zero
state waiting
record 'jackin-env-kinds 2\nattempt 0\nmain P73_FAKE_API_KEY other\n'
verify fail_other_in_main_at_attempt_zero FAIL 'P73_FAKE_API_KEY' read

mk fail_other_in_codex
state 'exited 1 0'
record 'jackin-env-kinds 2\nattempt 1\nmain GITHUB_TOKEN empty\nagent STRIPE_SECRET other\n'
verify fail_other_in_codex FAIL 'STRIPE_SECRET' read

mk fail_invalid_name_other
state waiting
record 'jackin-env-kinds 2\nattempt 0\nmain INVALID_NAME other\n'
verify fail_invalid_name_other FAIL 'INVALID_NAME' read

mk fail_proc_other_without_record
state waiting
proc_main
environ 100 'X_TOKEN=sk-live-FAKE'
verify fail_proc_other_without_record FAIL 'X_TOKEN' absent

mk skip_absent
state waiting
verify skip_absent SKIP 'no start record' absent

mk skip_proc_clean_without_record
state waiting
proc_main
proc_codex
environ 100 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
environ 101 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
verify skip_proc_clean_without_record SKIP 'no start record' absent

mk main_environ_partial_read_falls_back_to_the_other_start_record
state 'exited 1 0'
proc_main
proc_codex
environ 100 'OPENAI_API_KEY=sk-FAKE-REAL-SECRET-0123456789abcdef'
environ 101 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
record "$R_OTHER_MAIN"
cat_fail_for_proc "$t/proc/100/environ" 12
begin main_environ_partial_read_falls_back_to_the_other_start_record env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'P73_FAKE_API_KEY'
fact '.agent_environment.main' record
fact '.start_record.state' read
not_disclosed 'sk-FAKE-REAL-SECRET-0123456789abcdef'
finish_case

mk codex_environ_failed_read_falls_back_to_the_other_start_record
state 'exited 1 0'
proc_main
proc_codex
environ 100 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
environ 101 'GITHUB_TOKEN=sk-FAKE-CODEX-SECRET-0123456789abcdef'
record "$R_OTHER_CODEX"
cat_fail_for_proc "$t/proc/101/environ" 0
begin codex_environ_failed_read_falls_back_to_the_other_start_record env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'STRIPE_SECRET'
fact '.agent_environment.agent' record
fact '.start_record.state' read
not_disclosed 'sk-FAKE-CODEX-SECRET-0123456789abcdef'
finish_case

mk main_environ_failed_read_uses_a_clean_start_record
state 'exited 1 0'
proc_main
proc_codex
environ 100 'OPENAI_API_KEY=sk-FAKE-REAL-SECRET-0123456789abcdef'
environ 101 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
record "$R_OK1"
cat_fail_for_proc "$t/proc/100/environ" 12
begin main_environ_failed_read_uses_a_clean_start_record env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment PASS 'via record'
fact '.agent_environment.main' record
not_disclosed 'sk-FAKE-REAL-SECRET-0123456789abcdef'
finish_case

mk main_environ_failed_read_without_a_fresh_record_remains_unknown
state waiting
proc_main
environ 100 'OPENAI_API_KEY=sk-FAKE-REAL-SECRET-0123456789abcdef'
cat_fail_for_proc "$t/proc/100/environ" 0
begin main_environ_failed_read_without_a_fresh_record_remains_unknown env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment SKIP 'never clean'
fact '.agent_environment.main' denied
fact '.start_record.state' absent
not_disclosed 'sk-FAKE-REAL-SECRET-0123456789abcdef'
finish_case

if [ "$(id -u)" -ne 0 ]; then
    mk skip_unreadable
    state waiting
    record "$R_W0"
    chmod 000 "$t/sandbox/.jackin/run/env-kinds"
    verify skip_unreadable SKIP 'cannot be read' unreadable
else
    echo "skip skip_unreadable: running as root"
fi

mk skip_stale_attempt
state 'exited 2 0'
record "$R_OK1"
verify skip_stale_attempt SKIP 'stale' stale

mk skip_state_absent
record "$R_W0"
verify skip_state_absent SKIP 'stale' stale

mk skip_state_garbled
state 'bogus 1'
record "$R_W0"
verify skip_state_garbled SKIP 'stale' stale

mk skip_malformed_running_state_with_matching_start_record
state 'running 1 garbage'
proc_main
proc_codex
environ 100 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
environ 101 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
record "$R_OK1"
begin skip_malformed_running_state_with_matching_start_record sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment SKIP 'stale'
fact '.start_record.state' stale
finish_case

multiline_exited_state=$(printf 'exited 1 0\nextra')
for variant in 'exited 1 0 garbage' 'exited 1 0 ' 'exited 1 00' 'exited 1 256' 'exited 01 0' "$multiline_exited_state"; do
    case_name=skip_malformed_exited_state_$(printf '%s' "$variant" | tr -c 'A-Za-z0-9' _)
    mk "$case_name"
    state "$variant"
    record "$R_OK1"
    verify "$case_name" SKIP stale stale
done

mk skip_nul_exited_state_with_matching_start_record
printf 'exited 1 0\000garbage\n' >"$t/sandbox/.jackin/run/state"
record "$R_OK1"
verify skip_nul_exited_state_with_matching_start_record SKIP stale stale

mk skip_oversized_running_state_with_matching_start_record
{
    printf 'running 1'
    head -c 128 /dev/zero | tr '\000' x
    printf '\n'
} >"$t/sandbox/.jackin/run/state"
proc_main
proc_codex
environ 100 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
environ 101 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
record "$R_OK1"
verify skip_oversized_running_state_with_matching_start_record SKIP stale stale

mk skip_fifo_run_state_with_matching_start_record
rm -f "$t/sandbox/.jackin/run/state"
mkfifo "$t/sandbox/.jackin/run/state"
record "$R_OK1"
verify skip_fifo_run_state_with_matching_start_record SKIP stale stale

mk skip_symlink_run_state_with_matching_start_record
printf 'exited 1 0\n' >"$t/valid-state"
rm -f "$t/sandbox/.jackin/run/state"
ln -s "$t/valid-state" "$t/sandbox/.jackin/run/state"
record "$R_OK1"
verify skip_symlink_run_state_with_matching_start_record SKIP stale stale

mk skip_swapped_symlink_run_state_with_matching_start_record
state 'exited 1 0'
printf 'exited 1 0\n' >"$t/valid-state"
record "$R_OK1"
begin skip_swapped_symlink_run_state_with_matching_start_record \
    env SENTINEL_DD_SWAP_PATH="$t/sandbox/.jackin/run/state" SENTINEL_DD_SWAP_TARGET="$t/valid-state" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment SKIP 'stale'
fact '.start_record.state' stale
finish_case

mk skip_codex_not_yet_started
state waiting
record "$R_W0"
verify skip_codex_not_yet_started SKIP 'Codex environment is not known' read

mk reject_missing_agent_evidence
state 'exited 1 65'
record "$R_NOCODEX"
verify reject_missing_agent_evidence FAIL 'malformed start record' malformed

mk fail_proc_wins_over_record
state 'exited 1 0'
proc_main
environ 100 'OPENAI_API_KEY=sk-real-value-0123456789abcdef'
record "$R_OK1"
verify fail_proc_wins_over_record FAIL 'OPENAI_API_KEY' read

mk pass_proc_wins_and_notes_disagreement
state 'exited 1 0'
proc_main
environ 100 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
record 'jackin-env-kinds 2\nattempt 1\nmain OPENAI_API_KEY other\nagent OPENAI_API_KEY placeholder\n'
verify pass_proc_wins_and_notes_disagreement PASS 'disagree' read

mk malformed_symlink_to_dev_zero
state waiting
ln -s /dev/zero "$t/sandbox/.jackin/run/env-kinds"
verify malformed_symlink_to_dev_zero FAIL 'malformed start record' malformed

mk malformed_directory
state waiting
mkdir "$t/sandbox/.jackin/run/env-kinds"
verify malformed_directory FAIL 'malformed start record' malformed

mk malformed_one_mebibyte
state waiting
{
    printf 'jackin-env-kinds 2\nattempt 0\n'
    head -c 1048576 /dev/zero | tr '\0' 'a'
} >"$t/sandbox/.jackin/run/env-kinds"
verify malformed_one_mebibyte FAIL 'malformed start record' malformed

mk malformed_symlink_to_a_valid_record
state waiting
printf '%b' "$R_W0" >"$t/real-record"
ln -s "$t/real-record" "$t/sandbox/.jackin/run/env-kinds"
verify malformed_symlink_to_a_valid_record FAIL 'malformed start record' malformed

mk malformed_oversized_valid_grammar
state waiting
{
    printf 'jackin-env-kinds 2\nattempt 0\n'
    i=0
    while [ "$i" -lt 2338 ]; do
        printf 'main P%05d_KEY placeholder\n' "$i"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt 202 ]; do
        printf 'main Q%05d_KEY empty\n' "$i"
        i=$((i + 1))
    done
} >"$t/sandbox/.jackin/run/env-kinds"
verify malformed_oversized_valid_grammar FAIL 'malformed start record' malformed

mk malformed_nul_byte
state waiting
record 'jackin-env-kinds 2\nattempt 0\nmain A\0KEY other\n'
verify malformed_nul_byte FAIL 'malformed start record' malformed

for variant in \
    'version_one|jackin-env-kinds 1\nattempt 0\nmain A_KEY empty\n' \
    'codex_section|jackin-env-kinds 2\nattempt 1\nmain A_KEY empty\ncodex A_KEY empty\n' \
    'bad_version|jackin-env-kinds 2\nattempt 0\n' \
    'missing_attempt|jackin-env-kinds 2\nmain OPENAI_API_KEY placeholder\n' \
    'leading_zero_attempt|jackin-env-kinds 2\nattempt 00\n' \
    'duplicate_main_name|jackin-env-kinds 2\nattempt 0\nmain A_KEY empty\nmain A_KEY empty\n' \
    'main_after_codex|jackin-env-kinds 2\nattempt 0\nagent A_KEY empty\nmain A_KEY empty\n' \
    'escape_in_name|jackin-env-kinds 2\nattempt 0\nmain X\033]0;pwn other\n' \
    'capitalised_kind|jackin-env-kinds 2\nattempt 0\nmain A_KEY Placeholder\n' \
    'bad_name|jackin-env-kinds 2\nattempt 0\nmain 1A_KEY other\n' \
    'carriage_return|jackin-env-kinds 2\r\nattempt 0\r\n' \
    'blank_line|jackin-env-kinds 2\nattempt 0\n\n' \
    'unknown_section|jackin-env-kinds 2\nattempt 0\nextra A_KEY other\n' \
    'header_only|jackin-env-kinds 2\n'; do
    vname=${variant%%|*}
    mk "malformed_$vname"
    state waiting
    record "${variant#*|}"
    verify "malformed_$vname" FAIL 'malformed start record' malformed
done

PLACEHOLDER_ACCESS=openshell:resolve:env:CODEX_AUTH_ACCESS_TOKEN
PLACEHOLDER_REFRESH=openshell:resolve:env:CODEX_AUTH_REFRESH_TOKEN
ID_TOKEN_HEADER=$(printf '%s' 'eyJhbGci' 'OiJub25l' 'IiwidHlw' 'IjoiSldU' 'In0')
ID_TOKEN_PAYLOAD=$(printf '%s' 'eyJpc3Mi' 'OiJodHRw' 'czovL2F1' 'dGgub3Bl' 'bmFpLmNv' 'bSIsImF1' 'ZCI6ImNv' 'ZGV4Iiwi' 'c3ViIjoi' 'b3BlbnNo' 'ZWxsLWFw' 'cC1zZXJ2' 'ZXIifQ')
ID_TOKEN_PLACEHOLDER="${ID_TOKEN_HEADER}.${ID_TOKEN_PAYLOAD}.placeholder"

auth_json() {
    mkdir -p "$t/sandbox/.codex"
    printf '%s\n' "$1" >"$t/sandbox/.codex/auth.json"
}

report() {
    begin "$1" sh "$t/probe" --only J08
    expect_rc 0
    expect_report J08 sandbox
}

mk credential_skip_for_empty_auth_file
state waiting
record "$R_EMPTY"
auth_json '{}'
report credential_skip_for_empty_auth_file
expect credential SKIP 'no credential placeholder'
expect auth_file PASS 'only placeholders'
finish_case

mk credential_pass_for_placeholder_auth_file
state waiting
record "$R_EMPTY"
auth_json "{\"tokens\":{\"access_token\":\"$PLACEHOLDER_ACCESS\",\"refresh_token\":\"\"}}"
report credential_pass_for_placeholder_auth_file
expect credential PASS '1 placeholder tokens in auth.json'
expect auth_file PASS 'only placeholders'
expect file_scan PASS 'no token-shaped string'
finish_case

mk file_scan_accepts_placeholder_refresh_token
state waiting
record "$R_W0"
auth_json "{\"tokens\":{\"access_token\":\"$PLACEHOLDER_ACCESS\",\"refresh_token\":\"$PLACEHOLDER_REFRESH\"}}"
report file_scan_accepts_placeholder_refresh_token
expect auth_file PASS 'only placeholders'
expect file_scan PASS 'no token-shaped string'
finish_case

mk file_scan_flags_real_refresh_token
state waiting
record "$R_W0"
auth_json "{\"tokens\":{\"access_token\":\"$PLACEHOLDER_ACCESS\",\"refresh_token\":\"rt_FAKE_refresh_value\"}}"
report file_scan_flags_real_refresh_token
expect auth_file FAIL 'not a placeholder'
expect file_scan FAIL 'auth.json'
finish_case

mk file_scan_flags_a_multiline_refresh_token_outside_the_project_without_disclosing_it
state waiting
record "$R_W0"
multiline_refresh=$(printf '%s%s' 'refresh-' 'token-value-0123456789')
printf '{\n  "refresh_token":\n    "%s"\n}\n' "$multiline_refresh" >"$t/sandbox/session.json"
report file_scan_flags_a_multiline_refresh_token_outside_the_project_without_disclosing_it
expect file_scan FAIL 'session.json'
fact '.leaks | length' 1
if grep -Fq "$multiline_refresh" "$t/out"; then
    problems="$problems report-disclosed-refresh-token"
fi
finish_case

mk file_scan_accepts_multiline_refresh_placeholders_and_empty_values
state waiting
record "$R_W0"
printf '{\n  "refresh_token":\n    "%s"\n}\n' "$PLACEHOLDER_REFRESH" >"$t/sandbox/placeholder-session.json"
printf '{\n  "refresh_token":\n    ""\n}\n' >"$t/sandbox/empty-session.json"
report file_scan_accepts_multiline_refresh_placeholders_and_empty_values
expect file_scan PASS 'no token-shaped string'
fact '.leaks | length' 0
finish_case

mk file_scan_flags_token_in_file_over_two_mebibytes
state waiting
record "$R_W0"
{
    head -c 3145728 /dev/zero | tr '\0' 'a'
    printf '\nsk-%s\n' abcdefghijklmnopqrstuvwxyz
} >"$t/sandbox/big.log"
report file_scan_flags_token_in_file_over_two_mebibytes
expect file_scan FAIL 'big.log'
fact '.leaks | length' 1
finish_case

mk file_scan_passes_clean_sandbox
state waiting
record "$R_W0"
printf 'nothing here\n' >"$t/sandbox/note.txt"
report file_scan_passes_clean_sandbox
expect file_scan PASS 'no token-shaped string'
fact '.leaks | length' 0
finish_case

mk api_key_in_auth_file_is_not_a_placeholder
state waiting
record "$R_EMPTY"
auth_json '{"OPENAI_API_KEY":"FAKE-not-a-placeholder"}'
report api_key_in_auth_file_is_not_a_placeholder
expect auth_file FAIL 'not a placeholder'
expect credential SKIP 'no credential placeholder'
finish_case

mk auth_file_flags_a_top_level_key_behind_a_nested_placeholder
state waiting
record "$R_EMPTY"
auth_json "{\"tokens\":{\"access_token\":\"$PLACEHOLDER_ACCESS\"},\"OPENAI_API_KEY\":\"FAKE-real-key\"}"
report auth_file_flags_a_top_level_key_behind_a_nested_placeholder
expect auth_file FAIL 'not a placeholder'
fact '.auth_file.access_token' other
finish_case

mk auth_file_flags_a_nested_token_behind_a_top_level_placeholder
state waiting
record "$R_EMPTY"
auth_json "{\"tokens\":{\"access_token\":\"FAKE-real-token\"},\"OPENAI_API_KEY\":\"$PLACEHOLDER_ACCESS\"}"
report auth_file_flags_a_nested_token_behind_a_top_level_placeholder
expect auth_file FAIL 'not a placeholder'
fact '.auth_file.access_token' other
finish_case

mk auth_file_accepts_two_placeholders_and_an_empty_key
state waiting
record "$R_EMPTY"
auth_json "{\"tokens\":{\"access_token\":\"$PLACEHOLDER_ACCESS\"},\"OPENAI_API_KEY\":\"\"}"
report auth_file_accepts_two_placeholders_and_an_empty_key
expect auth_file PASS 'only placeholders'
fact '.auth_file.access_token' placeholder
finish_case

j10_seams() {
    mkdir -p "$t/allowed"
    seam J10_ALLOWED "\"\$STATE_DIR $t/allowed\""
    seam J10_DENIED "\"$1\""
}

j10_stays_inside() {
    fact '[.writes[].path | select(startswith("'"$t"'/") | not)] | length' 0
}

mk j10_state_dir_is_created
j10_seams "$t/missing"
begin j10_state_dir_is_created sh "$t/probe" --only J10
expect_rc 0
expect_report J10 sandbox
expect allowed_writes PASS '.sentinel'
j10_stays_inside
finish_case

mk j10_state_dir_cannot_be_created
: >"$t/sandbox/.sentinel"
j10_seams "$t/missing"
begin j10_state_dir_cannot_be_created sh "$t/probe" --only J10
expect_rc 0
expect_report J10 sandbox
expect allowed_writes FAIL '.sentinel'
j10_stays_inside
finish_case

mk j10_writable_denied_directory_fails
mkdir "$t/denied_rw"
j10_seams "$t/denied_rw"
begin j10_writable_denied_directory_fails sh "$t/probe" --only J10
expect_rc 0
expect_report J10 sandbox
expect denied_writes FAIL 'denied_rw'
expect denial_by_policy FAIL 'not proven'
j10_stays_inside
finish_case

mk j10_missing_denied_directory_is_not_proof_of_a_policy
j10_seams "$t/missing"
begin j10_missing_denied_directory_is_not_proof_of_a_policy sh "$t/probe" --only J10
expect_rc 0
expect_report J10 sandbox
expect denied_writes PASS 'no file could be created'
expect denial_by_policy FAIL 'not proven'
j10_stays_inside
finish_case

if [ "$(id -u)" -ne 0 ]; then
    mk j10_a_directory_without_search_permission_is_not_proof_of_a_policy
    mkdir "$t/denied_nosearch"
    chmod 622 "$t/denied_nosearch"
    j10_seams "$t/denied_nosearch"
    begin j10_a_directory_without_search_permission_is_not_proof_of_a_policy sh "$t/probe" --only J10
    chmod 755 "$t/denied_nosearch"
    expect_rc 0
    expect_report J10 sandbox
    expect denied_writes PASS 'no file could be created'
    expect denial_by_policy FAIL 'not proven'
    fact '[.writes[] | select(.expected == "denied") | .dac_writable] | map(tostring) | join(",")' false
    j10_stays_inside
    finish_case
else
    echo "skip j10_a_directory_without_search_permission_is_not_proof_of_a_policy: running as root"
fi

mk j10_eexist_in_a_mode_writable_directory_is_not_attributed_to_policy
mkdir "$t/denied_policy"
j10_seams "$t/denied_policy"
cat >"$t/occupy_then_probe.sh" <<'WRAP'
: >"$1/jackin-sentinel-j10-$$"
exec sh "$2" --only J10
WRAP
begin j10_eexist_in_a_mode_writable_directory_is_not_attributed_to_policy \
    sh "$t/occupy_then_probe.sh" "$t/denied_policy" "$t/probe"
expect_rc 0
expect_report J10 sandbox
expect denied_writes PASS 'no file could be created'
expect denial_by_policy FAIL 'not proven'
fact '[.writes[] | select(.expected == "denied") | .dac_writable] | map(tostring) | join(",")' true
j10_stays_inside
finish_case

if [ "$(id -u)" -ne 0 ]; then
    mk j10_eacces_in_a_mode_writable_directory_supports_policy_attribution
    mkdir "$t/denied_policy"
    j10_seams "$t/denied_policy"
    cat >"$t/occupy_then_probe.sh" <<'WRAP'
mkfifo "$1/jackin-sentinel-j10-$$"
chmod 000 "$1/jackin-sentinel-j10-$$"
exec sh "$2" --only J10
WRAP
    begin j10_eacces_in_a_mode_writable_directory_supports_policy_attribution \
        sh "$t/occupy_then_probe.sh" "$t/denied_policy" "$t/probe"
    chmod 600 "$t/denied_policy/jackin-sentinel-j10-$$" 2>/dev/null || true
    expect_rc 0
    expect_report J10 sandbox
    expect denied_writes PASS 'no file could be created'
    expect denial_by_policy PASS 'denied_policy'
    fact '[.writes[] | select(.expected == "denied") | .dac_writable] | map(tostring) | join(",")' true
    j10_stays_inside
    finish_case
else
    echo "skip j10_eacces_case: running as root"
fi

mk j10_eisdir_in_a_mode_writable_directory_is_not_attributed_to_policy
mkdir "$t/denied_policy"
j10_seams "$t/denied_policy"
cat >"$t/occupy_then_probe.sh" <<'WRAP'
mkdir "$1/jackin-sentinel-j10-$$"
exec sh "$2" --only J10
WRAP
begin j10_eisdir_in_a_mode_writable_directory_is_not_attributed_to_policy \
    sh "$t/occupy_then_probe.sh" "$t/denied_policy" "$t/probe"
expect_rc 0
expect_report J10 sandbox
expect denied_writes PASS 'no file could be created'
expect denial_by_policy FAIL 'not proven'
fact '[.writes[] | select(.expected == "denied") | .dac_writable] | map(tostring) | join(",")' true
j10_stays_inside
finish_case

proc_agent_child() {
    mkdir -p "$t/proc/$1"
    printf 'codex\0--sandbox\0' >"$t/proc/$1/cmdline"
    printf '%s (codex) S 100 100 100 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "$1" "$1" >"$t/proc/$1/stat"
}

processes() {
    begin "$1" sh "$t/probe" --only "$2"
    expect_rc 0
    expect_report "$2" sandbox
}

mk j11_one_agent_child_in_a_running_state_passes
state 'running 1'
proc_main
proc_codex
processes j11_one_agent_child_in_a_running_state_passes J11
expect agent_child PASS 'as a child of the main process'
finish_case

mk j11_a_state_that_is_not_running_skips_the_agent_child_check
state waiting
proc_main
processes j11_a_state_that_is_not_running_skips_the_agent_child_check J11
expect agent_child SKIP 'not running'
finish_case

mk j07_one_agent_child_in_a_running_state_passes
state 'running 1'
proc_main
proc_codex
processes j07_one_agent_child_in_a_running_state_passes J07
expect agent_child PASS 'as a child of the main process'
finish_case

multiline_running_state=$(printf 'running 1\nextra')
for variant in 'running-bad' 'running' 'running ' 'running 0' 'running 01' 'running x' 'running -1' 'running 1 garbage' 'running 1 ' 'running 1 2' "$multiline_running_state"; do
    case_name=j11_the_state_$(printf '%s' "$variant" | tr -c 'A-Za-z0-9' _)_is_not_a_pass
    mk "$case_name"
    state "$variant"
    proc_main
    proc_codex
    processes "$case_name" J11
    expect agent_child FAIL 'not a valid running state'
    finish_case
done

for variant in 'running 1 garbage' 'running 1 ' 'running 1 2' "$multiline_running_state"; do
    case_name=j07_the_state_$(printf '%s' "$variant" | tr -c 'A-Za-z0-9' _)_is_not_a_pass
    mk "$case_name"
    state "$variant"
    proc_main
    proc_codex
    processes "$case_name" J07
    expect agent_child FAIL 'not a valid running state'
    finish_case
done

for step in J07 J11; do
    case_name=${step}_nul_running_state_is_not_a_pass
    mk "$case_name"
    printf 'running 1\000junk\n' >"$t/sandbox/.jackin/run/state"
    proc_main
    proc_codex
    processes "$case_name" "$step"
    expect agent_child FAIL 'not a valid running state'
    finish_case

    case_name=${step}_fifo_run_state_does_not_block_or_pass
    mk "$case_name"
    rm -f "$t/sandbox/.jackin/run/state"
    mkfifo "$t/sandbox/.jackin/run/state"
    proc_main
    proc_codex
    processes "$case_name" "$step"
    expect agent_child SKIP 'not running'
    finish_case

    case_name=${step}_symlink_run_state_is_not_followed
    mk "$case_name"
    printf 'running 1\n' >"$t/valid-state"
    rm -f "$t/sandbox/.jackin/run/state"
    ln -s "$t/valid-state" "$t/sandbox/.jackin/run/state"
    proc_main
    proc_codex
    processes "$case_name" "$step"
    expect agent_child SKIP 'not running'
    finish_case

    case_name=${step}_oversized_running_state_is_not_a_pass
    mk "$case_name"
    {
        printf 'running 1'
        head -c 128 /dev/zero | tr '\000' x
        printf '\n'
    } >"$t/sandbox/.jackin/run/state"
    proc_main
    proc_codex
    processes "$case_name" "$step"
    expect agent_child FAIL 'not a valid running state'
    finish_case
done

mk j11_two_agent_children_are_not_a_pass
state 'running 1'
proc_main
proc_codex
proc_agent_child 102
processes j11_two_agent_children_are_not_a_pass J11
expect agent_child FAIL '2 Codex processes'
finish_case

proc_tty_process() {
    mkdir -p "$t/proc/$1"
    printf '%s\0' "$2" >"$t/proc/$1/cmdline"
    printf '%s (%s) S %s %s %s %s -1 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' \
        "$1" "$3" "$4" "$1" "$1" "$5" "$1" >"$t/proc/$1/stat"
}

j12_case() {
    name=$1
    first_tty=$2
    second_tty=$3
    mk "$name"
    state 'running 1'
    proc_tty_process 100 /usr/local/bin/jackin-start jackin-start 1 0
    proc_tty_process 101 'codex\0--sandbox\0' codex 100 "$first_tty"
    proc_tty_process 102 'codex\0--sandbox\0' codex 100 "$second_tty"
    cat >"$t/run-probe.sh" <<'EOF'
#!/bin/sh
pid=$$
mkdir -p "$1/$pid"
printf 'sh\0' >"$1/$pid/cmdline"
printf '%s (sh) S 1 %s %s 256 -1 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "$pid" "$pid" "$pid" "$pid" >"$1/$pid/stat"
exec sh "$2" --only J12
EOF
    begin "$name" sh "$t/run-probe.sh" "$t/proc" "$t/probe"
    expect_rc 0
    expect_report J12 sandbox
}

j12_case j12_all_agent_children_have_distinct_ttys 512 768
expect distinct_tty PASS 'every Codex child'
finish_case

j12_case j12_second_agent_child_sharing_the_probe_tty_fails 512 256
expect distinct_tty FAIL 'share'
finish_case

j12_case j12_first_agent_child_sharing_the_probe_tty_fails 256 768
expect distinct_tty FAIL 'share'
finish_case

j12_case j12_shared_tty_wins_when_the_first_child_tty_is_unknown 256 0
expect distinct_tty FAIL 'share'
finish_case

j12_case j12_shared_tty_wins_when_the_second_child_tty_is_unknown 0 256
expect distinct_tty FAIL 'share'
finish_case

j12_case j12_all_unknown_child_ttys_remain_unknown 0 0
expect distinct_tty SKIP 'unknown'
finish_case

mk j12_no_agent_children_remain_unknown
state 'running 1'
proc_tty_process 100 /usr/local/bin/jackin-start jackin-start 1 0
cat >"$t/run-probe.sh" <<'EOF'
#!/bin/sh
pid=$$
mkdir -p "$1/$pid"
printf 'sh\0' >"$1/$pid/cmdline"
printf '%s (sh) S 1 %s %s 256 -1 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "$pid" "$pid" "$pid" "$pid" >"$1/$pid/stat"
exec sh "$2" --only J12
EOF
begin j12_no_agent_children_remain_unknown sh "$t/run-probe.sh" "$t/proc" "$t/probe"
expect_rc 0
expect_report J12 sandbox
expect distinct_tty SKIP 'unknown'
finish_case

mk j12_process_arguments_are_not_disclosed
state 'running 1'
main_marker=jackin-sentinel-main-argv0-synthetic-41f2c86a
child_marker=jackin-sentinel-codex-option-synthetic-b709d3e1
self_marker=jackin-sentinel-probe-positional-synthetic-63ac951d
mkdir -p "$t/proc/100" "$t/proc/101"
printf '%s\0%s\0' "/usr/local/bin/jackin-start-$main_marker" '--role=jackin' >"$t/proc/100/cmdline"
printf '100 (jackin-start) S 1 100 100 768 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0\n' >"$t/proc/100/stat"
printf 'codex\0--model\0%s\0' "$child_marker" >"$t/proc/101/cmdline"
printf '101 (codex) S 100 100 100 512 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 101 0 0\n' >"$t/proc/101/stat"
cat >"$t/run-probe.sh" <<'EOF'
#!/bin/sh
pid=$$
mkdir -p "$1/$pid"
printf 'sh\0%s\0' "$3" >"$1/$pid/cmdline"
printf '%s (sh) S 1 %s %s 256 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "$pid" "$pid" "$pid" "$pid" >"$1/$pid/stat"
exec sh "$2" --only J12
EOF
begin j12_process_arguments_are_not_disclosed sh "$t/run-probe.sh" "$t/proc" "$t/probe" "$self_marker"
expected_self_pid=$pid
expect_rc 0
expect_report J12 sandbox
expect not_descendant PASS 'not a descendant'
expect distinct_tty PASS 'every Codex child'
fact '.processes.run_state' 'running 1'
fact '.processes.main.pid' 100
fact '.processes.main.ppid' 1
fact '.processes.main.start_ticks' 100
fact '.processes.main.tty' 'tty:3:0'
fact '.processes.agent | length' 1
fact '.processes.agent[0].pid' 101
fact '.processes.agent[0].ppid' 100
fact '.processes.agent[0].start_ticks' 101
fact '.processes.agent[0].tty' 'tty:2:0'
fact '.processes.self.pid' "$expected_self_pid"
fact '.processes.self.ppid' 1
fact '.processes.self.start_ticks' "$expected_self_pid"
fact '.processes.self.tty' 'tty:1:0'
fact '.processes.main | has("args")' false
fact '.processes.agent[0] | has("args")' false
fact '.processes.self | has("args")' false
public_not_disclosed main "$main_marker"
public_not_disclosed codex "$child_marker"
public_not_disclosed self "$self_marker"
if jq -e --arg marker "$main_marker" \
    '.steps[].facts.processes.main | type == "object" and (tojson | contains($marker) | not)' "$t/out" >/dev/null 2>&1; then :; else problems="$problems main_marker_in_main_process"; fi
if jq -e --arg marker "$child_marker" \
    '.steps[].facts.processes.agent[0] | type == "object" and (tojson | contains($marker) | not)' "$t/out" >/dev/null 2>&1; then :; else problems="$problems codex_marker_in_codex_process"; fi
if jq -e --arg marker "$self_marker" \
    '.steps[].facts.processes.self | type == "object" and (tojson | contains($marker) | not)' "$t/out" >/dev/null 2>&1; then :; else problems="$problems self_marker_in_self_process"; fi
finish_case

mk j08_a_second_agent_child_with_a_real_credential_is_not_a_pass
state 'exited 1 0'
proc_main
proc_codex
proc_agent_child 102
environ 101 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
environ 102 'OPENAI_API_KEY=sk-real-value-0123456789abcdef'
record "$R_OK1"
begin j08_a_second_agent_child_with_a_real_credential_is_not_a_pass sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'not a placeholder'
fact '.agent_environment.agent' read
fact '.start_record.state' read
detail_contains environment '2 Codex processes'
detail_contains environment 'read 2 child environments'
fact '.environment | map(select(.name == "OPENAI_API_KEY" and .kind == "other" and .source == "agent")) | length' 1
not_disclosed 'sk-real-value-0123456789abcdef'
finish_case

mk codex_environments_preserve_first_child_evidence_when_second_read_fails
state 'exited 1 0'
proc_main
proc_codex
proc_agent_child 102
environ 101 'STRIPE_SECRET=sk-FAKE-FIRST-CHILD-SECRET-0123456789'
environ 102 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
record "$R_OK1"
cat_fail_for_proc "$t/proc/102/environ" 0
begin codex_environments_preserve_first_child_evidence_when_second_read_fails env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'not a placeholder'
detail_contains environment 'STRIPE_SECRET'
detail_contains environment '2 Codex processes'
detail_contains environment 'read 1 child environment'
detail_contains environment '1 child environment unread; the fresh aggregate Codex record is retained'
fact '.agent_environment.agent' read
fact '.environment | map(select(.name == "STRIPE_SECRET" and .kind == "other" and .source == "agent")) | length' 1
fact '.environment | map(select(.name == "GITHUB_TOKEN" and .source == "agent")) | length' 1
not_disclosed 'sk-FAKE-FIRST-CHILD-SECRET-0123456789'
finish_case

mk codex_environments_preserve_second_child_evidence_when_first_read_fails
state 'exited 1 0'
proc_main
proc_codex
proc_agent_child 102
environ 101 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
environ 102 'STRIPE_SECRET=sk-FAKE-SECOND-CHILD-SECRET-0123456789'
record "$R_OK1"
cat_fail_for_proc "$t/proc/101/environ" 0
begin codex_environments_preserve_second_child_evidence_when_first_read_fails env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'not a placeholder'
detail_contains environment 'STRIPE_SECRET'
detail_contains environment '2 Codex processes'
detail_contains environment 'read 1 child environment'
detail_contains environment '1 child environment unread; the fresh aggregate Codex record is retained'
fact '.agent_environment.agent' read
fact '.environment | map(select(.name == "STRIPE_SECRET" and .kind == "other" and .source == "agent")) | length' 1
fact '.environment | map(select(.name == "GITHUB_TOKEN" and .source == "agent")) | length' 1
not_disclosed 'sk-FAKE-SECOND-CHILD-SECRET-0123456789'
finish_case

mk codex_same_name_live_placeholder_keeps_fresh_record_other
state 'exited 1 0'
proc_main
proc_codex
proc_agent_child 102
environ 101 'STRIPE_SECRET=openshell:resolve:env:STRIPE_SECRET'
environ 102 'STRIPE_SECRET=openshell:resolve:env:STRIPE_SECRET'
record 'jackin-env-kinds 2\nattempt 1\nmain OPENAI_API_KEY placeholder\nagent STRIPE_SECRET other\n'
cat_fail_for_proc "$t/proc/102/environ" 0
begin codex_same_name_live_placeholder_keeps_fresh_record_other env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'not a placeholder'
detail_contains environment 'not a placeholder: STRIPE_SECRET'
detail_contains environment '2 Codex processes'
detail_contains environment 'read 1 child environment'
detail_contains environment '1 child environment unread; the fresh aggregate Codex record is retained'
fact '.environment | map(select(.name == "STRIPE_SECRET" and .kind == "placeholder" and .source == "agent")) | length' 1
fact '.environment | map(select(.name == "STRIPE_SECRET" and .kind == "other" and .source == "agent")) | length' 1
fact '.agent_environment.agent' read
fact '.start_record.state' read
finish_case

mk codex_same_name_live_other_keeps_fresh_record_placeholder
state 'exited 1 0'
proc_main
proc_codex
proc_agent_child 102
environ 101 'STRIPE_SECRET=sk-FAKE-SAME-NAME-OTHER-0123456789'
environ 102 'STRIPE_SECRET=openshell:resolve:env:STRIPE_SECRET'
record 'jackin-env-kinds 2\nattempt 1\nmain OPENAI_API_KEY placeholder\nagent STRIPE_SECRET placeholder\n'
cat_fail_for_proc "$t/proc/102/environ" 0
begin codex_same_name_live_other_keeps_fresh_record_placeholder env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'not a placeholder'
detail_contains environment 'not a placeholder: STRIPE_SECRET'
detail_contains environment '2 Codex processes'
detail_contains environment 'read 1 child environment'
detail_contains environment '1 child environment unread; the fresh aggregate Codex record is retained'
fact '.environment | map(select(.name == "STRIPE_SECRET" and .kind == "other" and .source == "agent")) | length' 1
fact '.environment | map(select(.name == "STRIPE_SECRET" and .kind == "placeholder" and .source == "agent")) | length' 1
fact '.agent_environment.agent' read
fact '.start_record.state' read
not_disclosed 'sk-FAKE-SAME-NAME-OTHER-0123456789'
finish_case

mk codex_same_name_placeholder_observations_keep_child_multiplicity
state 'exited 1 0'
proc_main
proc_codex
proc_agent_child 102
environ 101 'STRIPE_SECRET=openshell:resolve:env:STRIPE_SECRET'
environ 102 'STRIPE_SECRET=openshell:resolve:env:STRIPE_SECRET'
record 'jackin-env-kinds 2\nattempt 1\nmain OPENAI_API_KEY placeholder\nagent STRIPE_SECRET placeholder\n'
cat_fail_for_proc "$t/proc/102/environ" 0
begin codex_same_name_placeholder_observations_keep_child_multiplicity env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL '2 Codex processes'
detail_contains environment 'read 1 child environment'
detail_contains environment '1 child environment could not be read; the fresh aggregate Codex record is retained'
fact '.environment | map(select(.name == "STRIPE_SECRET" and .kind == "placeholder" and .source == "agent")) | length' 1
fact '.environment | map(select(.name == "STRIPE_SECRET" and .kind == "other" and .source == "agent")) | length' 0
finish_case

mk codex_environment_count_reports_every_clean_child_read
state 'exited 1 0'
proc_main
proc_codex
proc_agent_child 102
environ 101 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
environ 102 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
record "$R_OK1"
begin codex_environment_count_reports_every_clean_child_read sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL '2 Codex processes'
detail_contains environment 'read 2 child environments'
finish_case

mk codex_filter_failure_uses_fresh_clean_record_without_claiming_live_read
state 'exited 1 0'
proc_main
proc_codex
environ 100 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
environ 101 'STRIPE_SECRET=sk-FAKE-FILTER-SECRET-0123456789'
record "$R_OK1"
jq_fail_for_codex_filter
begin codex_filter_failure_uses_fresh_clean_record_without_claiming_live_read env SENTINEL_REAL_JQ="$real_jq" PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment PASS 'via record'
fact '.agent_environment.agent' record
not_disclosed 'sk-FAKE-FILTER-SECRET-0123456789'
finish_case

mk codex_filter_failure_keeps_fresh_other_record_evidence
state 'exited 1 0'
proc_main
proc_codex
environ 100 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
environ 101 'STRIPE_SECRET=sk-FAKE-FILTER-OTHER-SECRET-0123456789'
record "$R_OTHER_CODEX"
jq_fail_for_codex_filter
begin codex_filter_failure_keeps_fresh_other_record_evidence env SENTINEL_REAL_JQ="$real_jq" PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'STRIPE_SECRET'
fact '.agent_environment.agent' record
fact '.environment | map(select(.name == "STRIPE_SECRET" and .kind == "other" and .source == "agent")) | length' 1
not_disclosed 'sk-FAKE-FILTER-OTHER-SECRET-0123456789'
finish_case

sudo_shim() {
    mkdir -p "$t/bin"
    printf '#!/bin/sh\ncase "$*" in\n    "-n true") exit %s ;;\n    "-n -l") echo "    (root) NOPASSWD: /bin/sh"; exit %s ;;\nesac\nexit 1\n' "$1" "$2" >"$t/bin/sudo"
    chmod +x "$t/bin/sudo"
}

mk j04_a_passwordless_grant_other_than_true_fails_the_sudo_check
sudo_shim 1 0
begin j04_a_passwordless_grant_other_than_true_fails_the_sudo_check env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J04
expect_rc 0
expect_report J04 sandbox
expect sudo FAIL 'sudo works'
fact '.sudo.works' true
finish_case

mk j04_a_passwordless_true_fails_the_sudo_check
sudo_shim 0 1
begin j04_a_passwordless_true_fails_the_sudo_check env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J04
expect_rc 0
expect_report J04 sandbox
expect sudo FAIL 'sudo works'
fact '.sudo.works' true
finish_case

mk j04_a_sudo_without_a_passwordless_grant_passes_the_sudo_check
sudo_shim 1 1
begin j04_a_sudo_without_a_passwordless_grant_passes_the_sudo_check env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J04
expect_rc 0
expect_report J04 sandbox
expect sudo PASS 'found=true works=false'
fact '.sudo.works' false
finish_case

hook_tree() {
    mkdir -p "$t/hookroot/lib/hooks"
    : >"$t/hookroot/lib/hooks/setup"
    : >"$t/hookroot/lib/hooks/preflight"
    chmod 444 "$t/hookroot/lib/hooks/setup" "$t/hookroot/lib/hooks/preflight"
    seam HOOK_DIR "$t/hookroot/lib/hooks"
    seam HOOK_TOP "$t/hookroot"
}

hook_writable() {
    fact '[.hooks[].writable] | map(tostring) | join(",")' "$1"
}

if [ "$(id -u)" -ne 0 ]; then
    mk j06_a_writable_parent_of_the_hook_directory_makes_the_hooks_mutable
    hook_tree
    chmod 555 "$t/hookroot/lib/hooks" "$t/hookroot"
    begin j06_a_writable_parent_of_the_hook_directory_makes_the_hooks_mutable sh "$t/probe" --only J06
    chmod 755 "$t/hookroot/lib/hooks" "$t/hookroot"
    expect_rc 0
    expect_report J06 sandbox
    expect hooks_immutable FAIL 'writable'
    hook_writable true,true
    finish_case

    mk j06_a_writable_top_of_the_hook_tree_makes_the_hooks_mutable
    hook_tree
    chmod 555 "$t/hookroot/lib/hooks" "$t/hookroot/lib"
    begin j06_a_writable_top_of_the_hook_tree_makes_the_hooks_mutable sh "$t/probe" --only J06
    chmod 755 "$t/hookroot/lib/hooks" "$t/hookroot/lib"
    expect_rc 0
    expect_report J06 sandbox
    hook_writable true,true
    finish_case

    mk j06_a_hook_tree_without_a_writable_ancestor_is_immutable
    hook_tree
    chmod 555 "$t/hookroot/lib/hooks" "$t/hookroot/lib" "$t/hookroot"
    mkdir -p "$t/bin"
    real_stat=$(command -v stat)
    cat >"$t/bin/stat" <<EOF
#!/bin/sh
for last; do :; done
case \$last in
    */hookroot/lib/hooks/setup | */hookroot/lib/hooks/preflight) printf '0 444\\n' ;;
    *) exec $real_stat "\$@" ;;
esac
EOF
    chmod +x "$t/bin/stat"
    begin j06_a_hook_tree_without_a_writable_ancestor_is_immutable env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J06
    chmod 755 "$t/hookroot/lib/hooks" "$t/hookroot/lib" "$t/hookroot"
    expect_rc 0
    expect_report J06 sandbox
    expect hooks_immutable PASS 'not symlinked'
    hook_writable false,false
    finish_case
else
    echo "skip j06 ancestor cases: running as root"
fi

if [ "$(id -u)" -ne 0 ]; then
    mk j06_a_root_owned_hook_symlink_to_a_writable_physical_ancestor_fails
    mkdir -p "$t/hookroot/lib/hooks" "$t/physical" "$t/sandbox/.sentinel"
    printf 'setup\n' >"$t/sandbox/.sentinel/setup.log"
    printf 'preflight\n' >"$t/sandbox/.sentinel/preflight.log"
    printf 'target\n' >"$t/physical/setup"
    : >"$t/hookroot/lib/hooks/preflight"
    chmod 444 "$t/physical/setup" "$t/hookroot/lib/hooks/preflight"
    ln -s "$t/physical/setup" "$t/hookroot/lib/hooks/setup"
    chmod 555 "$t/hookroot/lib/hooks" "$t/hookroot/lib" "$t/hookroot"
    seam HOOK_DIR "$t/hookroot/lib/hooks"
    seam HOOK_TOP "$t/hookroot"
    mkdir -p "$t/bin"
    real_stat=$(command -v stat)
    cat >"$t/bin/stat" <<EOF
#!/bin/sh
for last; do :; done
case \$last in
    $t/hookroot/lib/hooks/setup) printf '0 777\\n' ;;
    $t/hookroot/lib/hooks/preflight | $t/physical/setup) printf '0 444\\n' ;;
    *) exec $real_stat "\$@" ;;
esac
EOF
    chmod +x "$t/bin/stat"
    begin j06_a_root_owned_hook_symlink_to_a_writable_physical_ancestor_fails env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J06
    chmod 755 "$t/hookroot/lib/hooks" "$t/hookroot/lib" "$t/hookroot"
    expect_rc 0
    expect_report J06 sandbox
    expect hooks_immutable FAIL 'symlinked'
    hook_writable true,false
    finish_case
else
    echo "skip j06_physical_symlink_case: running as root"
fi

mk only_rejects_whitespace
begin only_rejects_whitespace sh "$t/probe" --only 'J04 J05'
expect_usage
finish_case

mk only_rejects_comma_then_space
begin only_rejects_comma_then_space sh "$t/probe" --only 'J04, J05'
expect_usage
finish_case

mk only_rejects_glob
begin only_rejects_glob sh "$t/probe" --only '*'
expect_usage
finish_case

mk only_rejects_unknown_step
begin only_rejects_unknown_step sh "$t/probe" --only J99
expect_usage
finish_case

mk only_rejects_commas_alone
begin only_rejects_commas_alone sh "$t/probe" --only ,,
expect_usage
finish_case

mk host_mode_skips_every_selected_step
begin host_mode_skips_every_selected_step sh "$t/probe" --host --only J08
expect_rc 0
expect_report J08 host
expect sandbox SKIP 'not running in a sandbox'
finish_case

mk outside_a_sandbox_the_probe_refuses
ln -s "$real_uname" "$t/bin/uname" || exit 70
ln -s "$real_id" "$t/bin/id" || exit 70
begin outside_a_sandbox_the_probe_refuses env PATH="$PATH" sh "$t/probe" --only J08
case $(uname -s)-$(id -un) in
    Linux-sandbox) ;;
    *)
        expect_rc 66
        [ ! -s "$t/out" ] || problems="$problems stdout-not-empty"
        ;;
esac
finish_case

mk file_scan_flags_token_in_binary_file
state waiting
record "$R_W0"
printf 'head\0tail\nsk-%s\n' abcdefghijklmnopqrstuvwxyz >"$t/sandbox/blob.bin"
report file_scan_flags_token_in_binary_file
expect file_scan FAIL 'blob.bin'
finish_case

mk file_scan_ignores_sk_inside_a_word
state waiting
record "$R_W0"
printf 'see task-manager-configuration-value-for-the-job\n' >"$t/sandbox/note.txt"
report file_scan_ignores_sk_inside_a_word
expect file_scan PASS 'no token-shaped string'
finish_case

b64url() {
    printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'
}

JWT_HEADER=$(b64url '{"alg":"ES256","kid":"oailb-v1","typ":"JWT"}')
JWT_NO_SUB=$(b64url '{"aud":["chatgpt.com"],"exp":1,"host":"x","iat":1,"iss":"edge-gateway"}')
JWT_WITH_SUB=$(b64url '{"aud":["chatgpt.com"],"exp":1,"host":"x","iat":1,"iss":"edge-gateway","sub":"user-FAKE"}')
JWT_SIGNATURE=ZmFrZXNpZ25hdHVyZWZha2VzaWduYXR1cmU

mk file_scan_passes_a_jwt_without_a_sub_claim_in_a_binary_file
state waiting
record "$R_W0"
printf 'head\0Set-Cookie: __oailb=%s.%s.%s; Path=/\0tail\n' "$JWT_HEADER" "$JWT_NO_SUB" "$JWT_SIGNATURE" >"$t/sandbox/logs.sqlite"
report file_scan_passes_a_jwt_without_a_sub_claim_in_a_binary_file
expect file_scan PASS 'no token-shaped string'
fact '.leaks | length' 0
finish_case

mk file_scan_flags_a_jwt_with_a_sub_claim_in_a_binary_file
state waiting
record "$R_W0"
printf 'head\0Set-Cookie: __oailb=%s.%s.%s; Path=/\0tail\n' "$JWT_HEADER" "$JWT_WITH_SUB" "$JWT_SIGNATURE" >"$t/sandbox/logs.sqlite"
report file_scan_flags_a_jwt_with_a_sub_claim_in_a_binary_file
expect file_scan FAIL 'logs.sqlite'
fact '.leaks | length' 1
finish_case

jwt_flagged() {
    mk "$1"
    state waiting
    record "$R_W0"
    printf 'head\0token=%s.%s.%s\0tail\n' "$2" "$3" "$JWT_SIGNATURE" >"$t/sandbox/logs.sqlite"
    report "$1"
    expect file_scan FAIL 'logs.sqlite'
    fact '.leaks | length' 1
    finish_case
}

mk file_scan_flags_a_subless_jwt_of_another_issuer
state waiting
record "$R_W0"
cookie_schema_issuer_jwt=$JWT_HEADER.$(b64url '{"aud":["chatgpt.com"],"exp":1,"host":"x","iat":1,"iss":"other-service"}').$JWT_SIGNATURE
printf 'head\0Set-Cookie: __oailb=%s; Path=/\0tail\n' "$cookie_schema_issuer_jwt" >"$t/sandbox/logs.sqlite"
report file_scan_flags_a_subless_jwt_of_another_issuer
expect file_scan FAIL 'logs.sqlite'
fact '.leaks | length' 1
fact '.leaks[0] | endswith("/logs.sqlite")' true
not_disclosed "$cookie_schema_issuer_jwt"
finish_case
jwt_flagged file_scan_flags_a_subless_jwt_of_another_audience "$JWT_HEADER" "$(b64url '{"aud":["api.example.com"],"exp":1,"iss":"edge-gateway"}')"
jwt_flagged file_scan_flags_a_subless_jwt_without_an_audience "$JWT_HEADER" "$(b64url '{"exp":1,"iss":"edge-gateway"}')"
jwt_flagged file_scan_flags_a_cookie_with_an_extra_secret_claim "$JWT_HEADER" "$(b64url '{"aud":["chatgpt.com"],"exp":1,"host":"x","iat":1,"iss":"edge-gateway","x":"sk-FAKEFAKEFAKEFAKEFAKE0123456789ABCD"}')"
jwt_flagged file_scan_flags_a_cookie_with_an_email_claim "$JWT_HEADER" "$(b64url '{"aud":["chatgpt.com"],"email":"user@example.com","exp":1,"host":"x","iat":1,"iss":"edge-gateway"}')"
jwt_flagged file_scan_flags_a_cookie_without_a_host_claim "$JWT_HEADER" "$(b64url '{"aud":["chatgpt.com"],"exp":1,"iat":1,"iss":"edge-gateway"}')"
jwt_flagged file_scan_flags_a_cookie_wrapped_around_a_jwt_with_a_sub "$JWT_HEADER" "$JWT_NO_SUB.$JWT_HEADER.$JWT_WITH_SUB"
jwt_flagged file_scan_flags_a_subless_jwt_of_another_key "$(b64url '{"alg":"ES256","kid":"other-v1","typ":"JWT"}')" "$JWT_NO_SUB"
jwt_flagged file_scan_flags_a_subless_jwt_with_a_string_audience_of_another_host "$JWT_HEADER" "$(b64url '{"aud":"api.example.com","exp":1,"host":"x","iat":1,"iss":"edge-gateway"}')"
jwt_flagged file_scan_flags_a_subless_jwt_with_an_extra_audience "$JWT_HEADER" "$(b64url '{"aud":["chatgpt.com","api.example.com"],"exp":1,"host":"x","iat":1,"iss":"edge-gateway"}')"

mk file_scan_passes_the_cookie_with_a_string_audience
state waiting
record "$R_W0"
printf 'head\0Set-Cookie: __oailb=%s.%s.%s; Path=/\0tail\n' "$JWT_HEADER" "$(b64url '{"aud":"chatgpt.com","exp":1,"host":"x","iat":1,"iss":"edge-gateway"}')" "$JWT_SIGNATURE" >"$t/sandbox/logs.sqlite"
report file_scan_passes_the_cookie_with_a_string_audience
expect file_scan PASS 'no token-shaped string'
finish_case

mk file_scan_flags_a_jwt_shaped_string_that_does_not_decode
state waiting
record "$R_W0"
JWT_NOT_JSON=$(b64url '{"not json at all')
printf 'head\0token=%s.%s.%s\0tail\n' "$JWT_HEADER" "$JWT_NOT_JSON" "$JWT_SIGNATURE" >"$t/sandbox/logs.sqlite"
report file_scan_flags_a_jwt_shaped_string_that_does_not_decode
expect file_scan FAIL 'logs.sqlite'
fact '.leaks | length' 1
finish_case

cookie_schema_flagged() {
    mk "$1"
    state waiting
    record "$R_W0"
    cookie_schema_jwt=$2.$3.$JWT_SIGNATURE
    printf 'head\0Set-Cookie: __oailb=%s; Path=/\0tail\n' "$cookie_schema_jwt" >"$t/sandbox/logs.sqlite"
    report "$1"
    expect file_scan FAIL 'logs.sqlite'
    fact '.leaks | length' 1
    fact '.leaks[0] | endswith("/logs.sqlite")' true
    not_disclosed "$cookie_schema_jwt"
    if [ -n "${4-}" ]; then
        not_disclosed "$4"
    fi
    finish_case
}

cookie_schema_flagged file_scan_flags_a_cookie_with_an_extra_header_secret "$(b64url '{"alg":"ES256","kid":"oailb-v1","typ":"JWT","x":"sk-FAKEFAKEFAKEFAKEFAKE0123456789ABCD"}')" "$JWT_NO_SUB" 'sk-FAKEFAKEFAKEFAKEFAKE0123456789ABCD'
cookie_schema_flagged file_scan_flags_a_cookie_with_another_algorithm "$(b64url '{"alg":"HS256","kid":"oailb-v1","typ":"JWT"}')" "$JWT_NO_SUB"
cookie_schema_flagged file_scan_flags_a_cookie_with_a_nonstring_host "$JWT_HEADER" "$(b64url '{"aud":["chatgpt.com"],"exp":1,"host":false,"iat":1,"iss":"edge-gateway"}')"
cookie_schema_flagged file_scan_flags_a_cookie_with_a_nonnumeric_iat "$JWT_HEADER" "$(b64url '{"aud":["chatgpt.com"],"exp":1,"host":"x","iat":"1","iss":"edge-gateway"}')"
cookie_schema_flagged file_scan_flags_a_cookie_with_a_nonnumeric_exp "$JWT_HEADER" "$(b64url '{"aud":["chatgpt.com"],"exp":"1","host":"x","iat":1,"iss":"edge-gateway"}')"

mk file_scan_passes_a_cookie_without_typ
state waiting
record "$R_W0"
cookie_schema_without_typ_jwt=$(b64url '{"alg":"ES256","kid":"oailb-v1"}').$JWT_NO_SUB.$JWT_SIGNATURE
printf 'head\0Set-Cookie: __oailb=%s; Path=/\0tail\n' "$cookie_schema_without_typ_jwt" >"$t/sandbox/logs.sqlite"
report file_scan_passes_a_cookie_without_typ
expect file_scan PASS 'no token-shaped string'
fact '.leaks | length' 0
not_disclosed "$cookie_schema_without_typ_jwt"
finish_case

cookie_schema_flagged file_scan_flags_a_cookie_with_invalid_typ "$(b64url '{"alg":"ES256","kid":"oailb-v1","typ":"not-JWT"}')" "$JWT_NO_SUB"
cookie_schema_flagged file_scan_flags_a_cookie_with_duplicate_header_alg "$(b64url '{"alg":"sk-FAKEFAKEFAKEFAKEFAKE0123456789ABCD","alg":"ES256","kid":"oailb-v1","typ":"JWT"}')" "$JWT_NO_SUB" 'sk-FAKEFAKEFAKEFAKEFAKE0123456789ABCD'
cookie_schema_flagged file_scan_flags_a_cookie_with_duplicate_payload_host "$JWT_HEADER" "$(b64url '{"aud":["chatgpt.com"],"exp":1,"host":"sk-FAKEFAKEFAKEFAKEFAKE0123456789ABCD","host":"x","iat":1,"iss":"edge-gateway"}')" 'sk-FAKEFAKEFAKEFAKEFAKE0123456789ABCD'

mk file_scan_passes_a_cookie_with_json_whitespace
state waiting
record "$R_W0"
cookie_schema_whitespace_jwt=$(b64url '{"alg": "ES256", "kid": "oailb-v1", "typ": "JWT"}').$(b64url '{"aud": ["chatgpt.com"], "exp": 1, "host": "x", "iat": 1, "iss": "edge-gateway"}').$JWT_SIGNATURE
printf 'head\0Set-Cookie: __oailb=%s; Path=/\0tail\n' "$cookie_schema_whitespace_jwt" >"$t/sandbox/logs.sqlite"
report file_scan_passes_a_cookie_with_json_whitespace
expect file_scan PASS 'no token-shaped string'
fact '.leaks | length' 0
not_disclosed "$cookie_schema_whitespace_jwt"
finish_case

cookie_schema_flagged file_scan_flags_a_cookie_with_escaped_duplicate_header_alg "$(b64url '{"alg":"sk-FAKEFAKEFAKEFAKEFAKE0123456789ABCD","a\u006cg":"ES256","kid":"oailb-v1","typ":"JWT"}')" "$JWT_NO_SUB" 'sk-FAKEFAKEFAKEFAKEFAKE0123456789ABCD'
cookie_schema_flagged file_scan_flags_a_cookie_with_escaped_duplicate_payload_host "$JWT_HEADER" "$(b64url '{"aud":["chatgpt.com"],"exp":1,"host":"sk-FAKEFAKEFAKEFAKEFAKE0123456789ABCD","h\u006fst":"x","iat":1,"iss":"edge-gateway"}')" 'sk-FAKEFAKEFAKEFAKEFAKE0123456789ABCD'

mk file_scan_passes_a_cookie_with_punctuation_in_host
state waiting
record "$R_W0"
cookie_schema_punctuation_host='a{,}"\b'
cookie_schema_punctuation_jwt=$JWT_HEADER.$(b64url '{"aud":["chatgpt.com"],"exp":1,"host":"a{,}\"\\b","iat":1,"iss":"edge-gateway"}').$JWT_SIGNATURE
printf 'head\0Set-Cookie: __oailb=%s; Path=/\0tail\n' "$cookie_schema_punctuation_jwt" >"$t/sandbox/logs.sqlite"
report file_scan_passes_a_cookie_with_punctuation_in_host
expect file_scan PASS 'no token-shaped string'
fact '.leaks | length' 0
not_disclosed "$cookie_schema_punctuation_jwt"
not_disclosed "$cookie_schema_punctuation_host"
finish_case

cookie_schema_flagged file_scan_flags_a_cookie_with_a_secret_in_host "$JWT_HEADER" "$(b64url '{"aud":["chatgpt.com"],"exp":1,"host":"sk-FAKEFAKEFAKEFAKEFAKE0123456789ABCD","iat":1,"iss":"edge-gateway"}')" 'sk-FAKEFAKEFAKEFAKEFAKE0123456789ABCD'

mk file_scan_skips_when_the_jwt_classifier_fails
state waiting
record "$R_W0"
mkdir -p "$t/bin"
exit_shim jq '*base64d*' 5
printf 'head\0Set-Cookie: __oailb=%s.%s.%s; Path=/\0tail\n' "$JWT_HEADER" "$JWT_NO_SUB" "$JWT_SIGNATURE" >"$t/sandbox/logs.sqlite"
begin file_scan_skips_when_the_jwt_classifier_fails env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect file_scan SKIP 'not scanned'
finish_case

mk file_scan_accepts_a_placeholder_id_token
state waiting
record "$R_W0"
auth_json "{\"tokens\":{\"access_token\":\"$PLACEHOLDER_ACCESS\",\"refresh_token\":\"$PLACEHOLDER_REFRESH\",\"id_token\":\"$ID_TOKEN_PLACEHOLDER\"}}"
report file_scan_accepts_a_placeholder_id_token
expect auth_file PASS 'only placeholders'
expect file_scan PASS 'no token-shaped string'
fact '.leaks | length' 0
finish_case

mk auth_file_rejects_an_id_token_with_only_the_placeholder_suffix
state waiting
record "$R_W0"
auth_json '{"tokens":{"id_token":"real-secret.placeholder"}}'
report auth_file_rejects_an_id_token_with_only_the_placeholder_suffix
expect auth_file FAIL 'not a placeholder'
finish_case

mk auth_file_rejects_an_id_token_with_an_extra_segment
state waiting
record "$R_W0"
auth_json "{\"tokens\":{\"id_token\":\"${ID_TOKEN_PLACEHOLDER%.placeholder}.extra.placeholder\"}}"
report auth_file_rejects_an_id_token_with_an_extra_segment
expect auth_file FAIL 'not a placeholder'
finish_case

mk auth_file_rejects_an_id_token_with_an_altered_segment
state waiting
record "$R_W0"
altered_id_token=$(printf '%s' "$ID_TOKEN_PLACEHOLDER" | sed 's/^eyJ/eyK/')
auth_json "{\"tokens\":{\"id_token\":\"$altered_id_token\"}}"
report auth_file_rejects_an_id_token_with_an_altered_segment
expect auth_file FAIL 'not a placeholder'
finish_case

mk auth_file_rejects_a_multiline_id_token_ending_in_the_placeholder_suffix
state waiting
record "$R_W0"
multiline_id_token=${ID_TOKEN_PLACEHOLDER%.placeholder}
auth_json "{\"tokens\":{\"id_token\":\"${multiline_id_token}\\n.placeholder\"}}"
report auth_file_rejects_a_multiline_id_token_ending_in_the_placeholder_suffix
expect auth_file FAIL 'not a placeholder'
finish_case

mk file_scan_flags_token_in_name_with_newline
state waiting
record "$R_W0"
printf 'sk-%s\n' abcdefghijklmnopqrstuvwxyz >"$t/sandbox/$(printf 'to\nken.txt')"
report file_scan_flags_token_in_name_with_newline
expect file_scan FAIL 'token-shaped strings in'
fact '.leaks | length' 1
fact '.leaks[0] | endswith("to\nken.txt")' true
finish_case

mk file_scan_skips_a_file_over_the_size_cap
state waiting
record "$R_W0"
seam SCAN_MAX_KIB 1
{
    head -c 3072 /dev/zero | tr '\0' 'a'
    printf '\nsk-%s\n' abcdefghijklmnopqrstuvwxyz
} >"$t/sandbox/big.log"
report file_scan_skips_a_file_over_the_size_cap
expect file_scan SKIP 'big.log (over the size cap)'
fact '.leaks | length' 0
finish_case

mk file_scan_skips_when_grep_fails
state waiting
record "$R_W0"
mkdir -p "$t/bin"
exit_shim grep '*bad.dat' 2
printf 'plain\n' >"$t/sandbox/bad.dat"
begin file_scan_skips_when_grep_fails env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect file_scan SKIP 'bad.dat'
finish_case

mk file_scan_flags_a_token_next_to_a_failed_grep
state waiting
record "$R_W0"
mkdir -p "$t/bin"
exit_shim grep '*bad.dat' 2
printf 'plain\n' >"$t/sandbox/bad.dat"
printf 'sk-%s\n' abcdefghijklmnopqrstuvwxyz >"$t/sandbox/secret.txt"
begin file_scan_flags_a_token_next_to_a_failed_grep env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect file_scan FAIL 'secret.txt'
finish_case

mk file_scan_skip_keeps_its_reason_before_a_long_path
state waiting
record "$R_W0"
mkdir -p "$t/bin"
exit_shim grep '*bad.dat' 2
long=$(printf 'd%.0s' $(seq 1 120))
mkdir -p "$t/sandbox/$long/$long"
printf 'plain\n' >"$t/sandbox/$long/$long/bad.dat"
begin file_scan_skip_keeps_its_reason_before_a_long_path env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect file_scan SKIP '(grep failed)'
finish_case

mk file_scan_skips_when_grep_times_out
state waiting
record "$R_W0"
mkdir -p "$t/bin"
exit_shim timeout '*slow.dat' 124
printf 'plain\n' >"$t/sandbox/slow.dat"
begin file_scan_skips_when_grep_times_out env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect file_scan SKIP 'slow.dat (grep timed out)'
finish_case

if [ "$(id -u)" -ne 0 ]; then
    mk file_scan_skips_an_unreadable_file
    state waiting
    record "$R_W0"
    printf 'plain\n' >"$t/sandbox/locked.txt"
    chmod 000 "$t/sandbox/locked.txt"
    report file_scan_skips_an_unreadable_file
    expect file_scan SKIP 'locked.txt (unreadable)'
    finish_case

    mk file_scan_skips_an_unreadable_directory
    state waiting
    record "$R_W0"
    mkdir "$t/sandbox/locked"
    printf 'sk-%s\n' abcdefghijklmnopqrstuvwxyz >"$t/sandbox/locked/secret.txt"
    chmod 000 "$t/sandbox/locked"
    report file_scan_skips_an_unreadable_directory
    chmod 755 "$t/sandbox/locked"
    expect file_scan SKIP 'locked'
    finish_case
else
    echo "skip file_scan_skips_an_unreadable_file and directory: running as root"
fi

git_in_project() {
    git_fixture -C "$t/sandbox/project" "$@"
}

git_project() {
    git_in_project init -q &&
        git_in_project -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m init
}

git_fixture() {
    env -i PATH="$scratch/tools:$scratch/shim" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git --no-optional-locks -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

git_global_fixture() {
    env -i PATH="$scratch/tools:$scratch/shim" HOME="$t/home" GIT_CONFIG_NOSYSTEM=1 git --no-optional-locks -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

git_public_state() {
    git_state_repo=$1
    git_state_index=$(git_fixture -C "$git_state_repo" rev-parse --git-path index) || return 1
    case "$git_state_index" in
        /*) git_state_index_file=$git_state_index ;;
        *) git_state_index_file=$git_state_repo/$git_state_index ;;
    esac
    git_fixture -C "$git_state_repo" rev-parse --verify HEAD &&
        git_fixture -C "$git_state_repo" for-each-ref --format='%(refname) %(objectname)' &&
        git_fixture -C "$git_state_repo" status --porcelain --untracked-files=all &&
        if [ -f "$git_state_index_file" ]; then
            git_state_index_digest=$(sha256sum "$git_state_index_file") || return 1
            printf 'index present %s\n' "${git_state_index_digest%% *}"
        else
            printf 'index absent\n'
        fi
}

git_foreign_repo() {
    git_foreign_path=$1
    mkdir -p "$git_foreign_path" &&
        git_fixture -C "$git_foreign_path" init -q &&
        git_fixture -C "$git_foreign_path" -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m foreign &&
        git_fixture -C "$git_foreign_path" tag foreign-tag
}

git_submodule_project() {
    mkdir -p "$t/submodule-source" &&
        git_fixture -C "$t/submodule-source" init -q &&
        printf child >"$t/submodule-source/tracked.txt" &&
        git_fixture -C "$t/submodule-source" add tracked.txt &&
        git_fixture -C "$t/submodule-source" -c user.name=probe -c user.email=probe@example.invalid commit -q -m child &&
        git_in_project -c protocol.file.allow=always submodule add -q "$t/submodule-source" child &&
        git_in_project -c user.name=probe -c user.email=probe@example.invalid commit -q -m submodule
}

git_flagged_submodule_project() {
    git_child_flag=$1
    git_project && git_submodule_project &&
        git_fixture -C "$t/sandbox/project/child" update-index "$git_child_flag" -- tracked.txt || return 1
    git_child_flag_entry=$(git_fixture -C "$t/sandbox/project/child" ls-files -v -- tracked.txt) || return 1
    case "$git_child_flag:$git_child_flag_entry" in
        --assume-unchanged:h\ tracked.txt) ;;
        --skip-worktree:S\ tracked.txt) ;;
        *) return 1 ;;
    esac
    printf changed >"$t/sandbox/project/child/tracked.txt" || return 1
    git_child_parent_status=$(git_in_project status --porcelain --untracked-files=all --ignore-submodules=none) || return 1
    [ -z "$git_child_parent_status" ]
}

git_flagged_project() {
    git_flag=$1
    git_change=$2
    git_project &&
        printf original >"$t/sandbox/project/tracked.txt" &&
        git_in_project add tracked.txt &&
        git_in_project -c user.name=probe -c user.email=probe@example.invalid commit -q -m tracked &&
        git_in_project update-index "$git_flag" -- tracked.txt || return 1
    git_flag_entry=$(git_in_project ls-files -v -- tracked.txt) || return 1
    case "$git_flag:$git_flag_entry" in
        --assume-unchanged:h\ tracked.txt) ;;
        --skip-worktree:S\ tracked.txt) ;;
        *) return 1 ;;
    esac
    if [ "$git_change" = changed ]; then
        printf changed >"$t/sandbox/project/tracked.txt" || return 1
    fi
    git_flag_status=$(git_in_project status --porcelain --untracked-files=all) || return 1
    [ -z "$git_flag_status" ]
}

mk j13_clean_work_tree
if git_project; then
    begin j13_clean_work_tree sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect head PASS ''
    expect work_tree_status PASS 'git status ran'
    fact '.clean' true
    finish_case
else
    setup_failed j13_clean_work_tree
fi

mk j13_unreadable_index_is_not_a_clean_work_tree
if git_project; then
    printf 'garbage' >"$t/sandbox/project/.git/index"
    begin j13_unreadable_index_is_not_a_clean_work_tree sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status FAIL 'cleanliness of the work tree is unknown'
    fact '.clean' false
    finish_case
else
    setup_failed j13_unreadable_index_is_not_a_clean_work_tree
fi

mk j13_a_broken_ref_fails_the_refs_check
if git_project; then
    echo garbage >"$t/sandbox/project/.git/refs/heads/other"
    begin j13_a_broken_ref_fails_the_refs_check sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect refs FAIL 'broken ref'
    finish_case
else
    setup_failed j13_a_broken_ref_fails_the_refs_check
fi

mk j13_branches_are_listed_when_the_refs_are_readable
if git_project; then
    begin j13_branches_are_listed_when_the_refs_are_readable sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect refs PASS '1 local branches'
    fact '.branches | length' 1
    finish_case
else
    setup_failed j13_branches_are_listed_when_the_refs_are_readable
fi

mk j13_a_broken_stash_ref_fails_the_refs_check
if git_project; then
    echo garbage >"$t/sandbox/project/.git/refs/stash"
    begin j13_a_broken_stash_ref_fails_the_refs_check sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect refs FAIL 'broken ref'
    finish_case
else
    setup_failed j13_a_broken_stash_ref_fails_the_refs_check
fi

mk j13_a_readable_stash_is_counted
if git_project; then
    printf s >"$t/sandbox/project/stashed.txt"
    git_in_project add stashed.txt &&
        git_in_project -c core.hooksPath=/dev/null -c user.name=probe -c user.email=probe@example.invalid stash -q
    begin j13_a_readable_stash_is_counted sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect refs PASS '1 local branches'
    fact '.stash' 1
    finish_case
else
    setup_failed j13_a_readable_stash_is_counted
fi

mk j13_a_bare_repository_is_not_a_work_tree
if git_in_project init -q --bare; then
    begin j13_a_bare_repository_is_not_a_work_tree sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree FAIL 'not a git work tree'
    expect work_tree_status SKIP 'git status not run'
    fact '.work_tree' false
    fact '.clean' false
    finish_case
else
    setup_failed j13_a_bare_repository_is_not_a_work_tree
fi

mk j05_a_bare_repository_is_not_a_work_tree
if git_in_project init -q --bare; then
    begin j05_a_bare_repository_is_not_a_work_tree sh "$t/probe" --only J05
    expect_rc 0
    expect_report J05 sandbox
    expect git_work_tree FAIL 'not a git work tree'
    fact '.git_work_tree' false
    finish_case
else
    setup_failed j05_a_bare_repository_is_not_a_work_tree
fi

mk j13_not_a_work_tree_does_not_claim_git_status_ran
begin j13_not_a_work_tree_does_not_claim_git_status_ran sh "$t/probe" --only J13
expect_rc 0
expect_report J13 sandbox
expect work_tree FAIL 'not a git work tree'
expect work_tree_status SKIP 'git status not run'
fact '.clean' false
finish_case

mk j13_missing_project_does_not_claim_cleanliness
rmdir "$t/sandbox/project"
begin j13_missing_project_does_not_claim_cleanliness sh "$t/probe" --only J13
expect_rc 0
expect_report J13 sandbox
expect work_tree FAIL 'not a git work tree'
expect work_tree_status SKIP 'git status not run'
fact '.clean' false
finish_case

mk j14_existing_valid_marker_preserves_its_id
mkdir -p "$t/sandbox/.sentinel"
known_id=0123456789abcdef0123456789abcdef
printf '%s\n' '01234567-89ab-cdef-0123-456789abcdef' >"$t/proc/sys/kernel/random/boot_id"
printf '%s\n' "$known_id" >"$t/sandbox/.sentinel/marker"
begin j14_existing_valid_marker_preserves_its_id sh "$t/probe" --only J14
expect_rc 0
expect_report J14 sandbox
expect marker PASS "created=false id=$known_id"
fact '.marker.id' "$known_id"
fact '.marker.created' false
finish_case

mk j14_existing_invalid_marker_does_not_disclose_its_id
mkdir -p "$t/sandbox/.sentinel"
synthetic_marker_id=jackin-sentinel-sensitive-marker-synthetic-9d5210a4
printf '%s\n' '01234567-89ab-cdef-0123-456789abcdef' >"$t/proc/sys/kernel/random/boot_id"
printf '%s\n' "$synthetic_marker_id" >"$t/sandbox/.sentinel/marker"
begin j14_existing_invalid_marker_does_not_disclose_its_id sh "$t/probe" --only J14
expect_rc 0
expect_report J14 sandbox
expect marker FAIL 'holds no valid id'
fact '.marker.id' ''
not_disclosed "$synthetic_marker_id"
finish_case

mk j14_existing_marker_with_leading_nul_does_not_disclose_its_id
mkdir -p "$t/sandbox/.sentinel"
known_id=11223344556677889900aabbccddeeff
printf '%s\n' '01234567-89ab-cdef-0123-456789abcdef' >"$t/proc/sys/kernel/random/boot_id"
printf '\000%s\n' "$known_id" >"$t/sandbox/.sentinel/marker"
begin j14_existing_marker_with_leading_nul_does_not_disclose_its_id sh "$t/probe" --only J14
expect_rc 0
expect_report J14 sandbox
expect marker FAIL 'holds no valid id'
fact '.marker.id' ''
not_disclosed "$known_id"
no_raw_nul
finish_case

mk j14_existing_marker_with_internal_nul_does_not_disclose_its_id
mkdir -p "$t/sandbox/.sentinel"
known_id=22334455667788990011aabbccddeeff
printf '%s\n' '01234567-89ab-cdef-0123-456789abcdef' >"$t/proc/sys/kernel/random/boot_id"
printf '%s\000%s\n' "${known_id%????????????????}" "${known_id#????????????????}" >"$t/sandbox/.sentinel/marker"
begin j14_existing_marker_with_internal_nul_does_not_disclose_its_id sh "$t/probe" --only J14
expect_rc 0
expect_report J14 sandbox
expect marker FAIL 'holds no valid id'
fact '.marker.id' ''
not_disclosed "$known_id"
no_raw_nul
finish_case

mk j14_existing_marker_with_trailing_nul_does_not_disclose_its_id
mkdir -p "$t/sandbox/.sentinel"
known_id=33445566778899001122aabbccddeeff
printf '%s\000\n' "$known_id" >"$t/sandbox/.sentinel/marker"
printf '%s\n' '01234567-89ab-cdef-0123-456789abcdef' >"$t/proc/sys/kernel/random/boot_id"
begin j14_existing_marker_with_trailing_nul_does_not_disclose_its_id sh "$t/probe" --only J14
expect_rc 0
expect_report J14 sandbox
expect marker FAIL 'holds no valid id'
fact '.marker.id' ''
not_disclosed "$known_id"
no_raw_nul
finish_case

mk j14_existing_valid_marker_without_lf_preserves_its_id
known_id=0123456789abcdef0123456789abcdef
if mkdir -p "$t/sandbox/.sentinel" &&
    printf '%s\n' '01234567-89ab-cdef-0123-456789abcdef' >"$t/proc/sys/kernel/random/boot_id" &&
    printf '%s' "$known_id" >"$t/sandbox/.sentinel/marker" &&
    [ -f "$t/sandbox/.sentinel/marker" ]; then
    begin j14_existing_valid_marker_without_lf_preserves_its_id sh "$t/probe" --only J14
    expect_rc 0
    expect_report J14 sandbox
    expect marker PASS "created=false id=$known_id"
    fact '.marker.id' "$known_id"
    fact '.marker.created' false
    finish_case
else
    setup_failed j14_existing_valid_marker_without_lf_preserves_its_id
fi

mk j14_existing_marker_with_byte_34_ascii_does_not_disclose_its_id
known_id=11223344556677889900aabbccddeeff
if mkdir -p "$t/sandbox/.sentinel" &&
    printf '%s\n' '01234567-89ab-cdef-0123-456789abcdef' >"$t/proc/sys/kernel/random/boot_id" &&
    printf '%s\nX' "$known_id" >"$t/sandbox/.sentinel/marker" &&
    [ -f "$t/sandbox/.sentinel/marker" ]; then
    begin j14_existing_marker_with_byte_34_ascii_does_not_disclose_its_id sh "$t/probe" --only J14
    expect_rc 0
    expect_report J14 sandbox
    expect marker FAIL 'holds no valid id'
    fact '.marker.id' ''
    fact '.marker.created' false
    not_disclosed "$known_id"
    no_raw_nul
    finish_case
else
    setup_failed j14_existing_marker_with_byte_34_ascii_does_not_disclose_its_id
fi

mk j14_existing_marker_with_byte_34_lf_does_not_disclose_its_id
known_id=22334455667788990011aabbccddeeff
if mkdir -p "$t/sandbox/.sentinel" &&
    printf '%s\n' '01234567-89ab-cdef-0123-456789abcdef' >"$t/proc/sys/kernel/random/boot_id" &&
    printf '%s\n\n' "$known_id" >"$t/sandbox/.sentinel/marker" &&
    [ -f "$t/sandbox/.sentinel/marker" ]; then
    begin j14_existing_marker_with_byte_34_lf_does_not_disclose_its_id sh "$t/probe" --only J14
    expect_rc 0
    expect_report J14 sandbox
    expect marker FAIL 'holds no valid id'
    fact '.marker.id' ''
    fact '.marker.created' false
    not_disclosed "$known_id"
    no_raw_nul
    finish_case
else
    setup_failed j14_existing_marker_with_byte_34_lf_does_not_disclose_its_id
fi

mk j14_existing_marker_with_byte_34_nul_does_not_disclose_its_id
known_id=33445566778899001122aabbccddeeff
if mkdir -p "$t/sandbox/.sentinel" &&
    printf '%s\n' '01234567-89ab-cdef-0123-456789abcdef' >"$t/proc/sys/kernel/random/boot_id" &&
    printf '%s\n\000' "$known_id" >"$t/sandbox/.sentinel/marker" &&
    [ -f "$t/sandbox/.sentinel/marker" ]; then
    begin j14_existing_marker_with_byte_34_nul_does_not_disclose_its_id sh "$t/probe" --only J14
    expect_rc 0
    expect_report J14 sandbox
    expect marker FAIL 'holds no valid id'
    fact '.marker.id' ''
    fact '.marker.created' false
    not_disclosed "$known_id"
    no_raw_nul
    finish_case
else
    setup_failed j14_existing_marker_with_byte_34_nul_does_not_disclose_its_id
fi

mk j05_parent_repository_is_not_the_project_repository
if git_fixture -C "$t/sandbox" init -q && git_fixture -C "$t/sandbox" -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m parent && git_fixture -C "$t/sandbox" tag parent-tag && printf project >"$t/sandbox/project/file.txt" && parent_state=$(git_public_state "$t/sandbox"); then
    begin j05_parent_repository_is_not_the_project_repository sh "$t/probe" --only J05
    expect_rc 0
    expect_report J05 sandbox
    expect git_work_tree FAIL 'not a git work tree'
    fact '.git_work_tree' false
    parent_state_after=$(git_public_state "$t/sandbox") || problems="$problems parent-state-unreadable"
    [ "$parent_state_after" = "$parent_state" ] || problems="$problems parent-state-changed"
    finish_git_case
else
    setup_failed j05_parent_repository_is_not_the_project_repository
fi

mk j13_parent_repository_is_not_the_project_repository
if git_fixture -C "$t/sandbox" init -q && git_fixture -C "$t/sandbox" -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m parent && git_fixture -C "$t/sandbox" tag parent-tag && printf project >"$t/sandbox/project/file.txt" && parent_head=$(git_fixture -C "$t/sandbox" rev-parse --verify HEAD) && parent_state=$(git_public_state "$t/sandbox"); then
    begin j13_parent_repository_is_not_the_project_repository sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree FAIL 'not a git work tree'
    expect work_tree_status SKIP 'git status not run'
    fact '.branch' null
    fact '.head' null
    [ -n "$parent_head" ] || problems="$problems parent-head-not-captured"
    parent_state_after=$(git_public_state "$t/sandbox") || problems="$problems parent-state-unreadable"
    [ "$parent_state_after" = "$parent_state" ] || problems="$problems parent-state-changed"
    finish_git_case
else
    setup_failed j13_parent_repository_is_not_the_project_repository
fi

mk j13_symlinked_project_root_is_accepted
if mkdir -p "$t/sandbox/real-project" && git_fixture -C "$t/sandbox/real-project" init -q && git_fixture -C "$t/sandbox/real-project" -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m project && project_head=$(git_fixture -C "$t/sandbox/real-project" rev-parse --verify HEAD) && project_branch=$(git_fixture -C "$t/sandbox/real-project" symbolic-ref --short HEAD) && rmdir "$t/sandbox/project" && ln -s "$t/sandbox/real-project" "$t/sandbox/project"; then
    begin j13_symlinked_project_root_is_accepted sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree PASS "$t/sandbox/project"
    expect work_tree_status PASS 'git status ran'
    fact '.branch' "$project_branch"
    fact '.head' "$project_head"
    fact '.clean' true
    finish_git_case
else
    setup_failed j13_symlinked_project_root_is_accepted
fi

mk j13_untracked_file_is_dirty_despite_local_configuration
if git_project && git_in_project config status.showUntrackedFiles no && printf x >"$t/sandbox/project/untracked.txt"; then
    begin j13_untracked_file_is_dirty_despite_local_configuration sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_untracked_file_is_dirty_despite_local_configuration
fi

mk j13_tracked_edit_is_dirty
if git_project && printf tracked >"$t/sandbox/project/tracked.txt" && git_in_project add tracked.txt && git_in_project -c user.name=probe -c user.email=probe@example.invalid commit -q -m tracked && printf changed >"$t/sandbox/project/tracked.txt"; then
    begin j13_tracked_edit_is_dirty sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_tracked_edit_is_dirty
fi

mk j13_unchanged_tracked_mode_is_clean_under_configuration
if git_project && printf '#!/bin/sh\n' >"$t/sandbox/project/tracked.sh" && chmod 0644 "$t/sandbox/project/tracked.sh" && git_in_project add tracked.sh && git_in_project -c user.name=probe -c user.email=probe@example.invalid commit -q -m executable && git_in_project config core.filemode false; then
    begin j13_unchanged_tracked_mode_is_clean_under_configuration sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' true
    finish_git_case
else
    setup_failed j13_unchanged_tracked_mode_is_clean_under_configuration
fi

mk j13_tracked_executable_mode_change_is_dirty_despite_configuration
if git_project && printf '#!/bin/sh\n' >"$t/sandbox/project/tracked.sh" && chmod 0644 "$t/sandbox/project/tracked.sh" && git_in_project add tracked.sh && git_in_project -c user.name=probe -c user.email=probe@example.invalid commit -q -m executable && git_in_project config core.filemode false && chmod 0755 "$t/sandbox/project/tracked.sh" && [ -x "$t/sandbox/project/tracked.sh" ] && ordinary_status=$(git_in_project status --porcelain --untracked-files=all) && [ -z "$ordinary_status" ] && required_status=$(git_in_project -c core.fileMode=true -c core.trustctime=true -c core.checkStat=default status --porcelain --untracked-files=all) && [ -n "$required_status" ]; then
    begin j13_tracked_executable_mode_change_is_dirty_despite_configuration sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_tracked_executable_mode_change_is_dirty_despite_configuration
fi

mk j13_dirty_submodule_file_is_dirty_despite_local_ignore
if git_project && git_submodule_project && git_in_project config submodule.child.ignore all && printf changed >"$t/sandbox/project/child/tracked.txt" && ordinary_status=$(git_in_project status --porcelain --untracked-files=all) && [ -z "$ordinary_status" ] && required_status=$(git_in_project status --porcelain --untracked-files=all --ignore-submodules=none) && [ -n "$required_status" ]; then
    begin j13_dirty_submodule_file_is_dirty_despite_local_ignore sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_dirty_submodule_file_is_dirty_despite_local_ignore
fi

mk j13_changed_submodule_head_is_dirty_despite_global_ignore
if git_project && git_submodule_project && mkdir -p "$t/home" && git_fixture config --file "$t/home/.gitconfig" diff.ignoreSubmodules all && printf next >"$t/submodule-source/tracked.txt" && git_fixture -C "$t/submodule-source" add tracked.txt && git_fixture -C "$t/submodule-source" -c user.name=probe -c user.email=probe@example.invalid commit -q -m next && child_head=$(git_fixture -C "$t/submodule-source" rev-parse --verify HEAD) && git_fixture -C "$t/sandbox/project/child" fetch -q "$t/submodule-source" && git_fixture -C "$t/sandbox/project/child" checkout -q "$child_head" && ordinary_status=$(git_global_fixture -C "$t/sandbox/project" status --porcelain --untracked-files=all) && [ -z "$ordinary_status" ] && required_status=$(git_global_fixture -C "$t/sandbox/project" status --porcelain --untracked-files=all --ignore-submodules=none) && [ -n "$required_status" ]; then
    begin j13_changed_submodule_head_is_dirty_despite_global_ignore env HOME="$t/home" GIT_CONFIG_NOSYSTEM=1 sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_changed_submodule_head_is_dirty_despite_global_ignore
fi

mk j13_clean_submodule_is_clean
if git_project && git_submodule_project; then
    begin j13_clean_submodule_is_clean sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' true
    finish_git_case
else
    setup_failed j13_clean_submodule_is_clean
fi

mk j13_child_assume_unchanged_edit_is_dirty
if git_flagged_submodule_project --assume-unchanged; then
    begin j13_child_assume_unchanged_edit_is_dirty sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_child_assume_unchanged_edit_is_dirty
fi

mk j13_child_skip_worktree_edit_is_dirty
if git_flagged_submodule_project --skip-worktree; then
    begin j13_child_skip_worktree_edit_is_dirty sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_child_skip_worktree_edit_is_dirty
fi

mk j13_assume_unchanged_edit_is_dirty
if git_flagged_project --assume-unchanged changed; then
    begin j13_assume_unchanged_edit_is_dirty sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_assume_unchanged_edit_is_dirty
fi

mk j13_assume_unchanged_entry_is_dirty_without_an_edit
if git_flagged_project --assume-unchanged unchanged; then
    begin j13_assume_unchanged_entry_is_dirty_without_an_edit sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_assume_unchanged_entry_is_dirty_without_an_edit
fi

mk j13_skip_worktree_edit_is_dirty
if git_flagged_project --skip-worktree changed; then
    begin j13_skip_worktree_edit_is_dirty sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_skip_worktree_edit_is_dirty
fi

mk j13_skip_worktree_entry_is_dirty_without_an_edit
if git_flagged_project --skip-worktree unchanged; then
    begin j13_skip_worktree_entry_is_dirty_without_an_edit sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_skip_worktree_entry_is_dirty_without_an_edit
fi

mk j13_stat_cache_configuration_cannot_hide_a_tracked_edit
if git_project && printf aaaa >"$t/sandbox/project/tracked.txt" && touch -t 200001010000.00 "$t/sandbox/project/tracked.txt" && git_in_project add tracked.txt && git_in_project -c user.name=probe -c user.email=probe@example.invalid commit -q -m tracked && git_in_project config core.trustctime false && git_in_project config core.checkStat minimal && printf bbbb >"$t/sandbox/project/replacement.txt" && touch -t 200001010000.00 "$t/sandbox/project/replacement.txt" && chmod 0644 "$t/sandbox/project/replacement.txt" && mv -f "$t/sandbox/project/replacement.txt" "$t/sandbox/project/tracked.txt" && ordinary_status=$(git_in_project status --porcelain --untracked-files=all) && [ -z "$ordinary_status" ] && required_status=$(git_in_project -c core.trustctime=true -c core.checkStat=default status --porcelain --untracked-files=all) && [ -n "$required_status" ]; then
    begin j13_stat_cache_configuration_cannot_hide_a_tracked_edit sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_stat_cache_configuration_cannot_hide_a_tracked_edit
fi

mk j13_stat_cache_configuration_keeps_unchanged_file_clean
if git_project && printf aaaa >"$t/sandbox/project/tracked.txt" && touch -t 200001010000.00 "$t/sandbox/project/tracked.txt" && git_in_project add tracked.txt && git_in_project -c user.name=probe -c user.email=probe@example.invalid commit -q -m tracked && git_in_project config core.trustctime false && git_in_project config core.checkStat minimal; then
    begin j13_stat_cache_configuration_keeps_unchanged_file_clean sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' true
    finish_git_case
else
    setup_failed j13_stat_cache_configuration_keeps_unchanged_file_clean
fi

mk j13_untracked_file_is_dirty_despite_global_configuration
if git_project && mkdir -p "$t/home" && git_fixture config --file "$t/home/.gitconfig" status.showUntrackedFiles no && printf x >"$t/sandbox/project/untracked.txt"; then
    begin j13_untracked_file_is_dirty_despite_global_configuration env HOME="$t/home" GIT_CONFIG_NOSYSTEM=1 sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_untracked_file_is_dirty_despite_global_configuration
fi

mk j13_untracked_file_is_dirty_despite_config_count_injection
if git_project && printf x >"$t/sandbox/project/untracked.txt"; then
    begin j13_untracked_file_is_dirty_despite_config_count_injection env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=status.showUntrackedFiles GIT_CONFIG_VALUE_0=no sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_untracked_file_is_dirty_despite_config_count_injection
fi

mk j13_untracked_file_is_dirty_despite_config_parameters_injection
if git_project && printf x >"$t/sandbox/project/untracked.txt"; then
    begin j13_untracked_file_is_dirty_despite_config_parameters_injection env "GIT_CONFIG_PARAMETERS='status.showUntrackedFiles=no'" sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_untracked_file_is_dirty_despite_config_parameters_injection
fi

mk j13_replace_ref_base_cannot_change_project_cleanliness
if git_project && printf original >"$t/sandbox/project/tracked.txt" && git_in_project add tracked.txt && git_in_project -c user.name=probe -c user.email=probe@example.invalid commit -q -m original && original_head=$(git_in_project rev-parse --verify HEAD) && printf changed >"$t/sandbox/project/tracked.txt" && git_in_project add tracked.txt && git_in_project -c user.name=probe -c user.email=probe@example.invalid commit -q -m changed && changed_head=$(git_in_project rev-parse --verify HEAD) && git_in_project checkout -q "$original_head" && git_in_project update-ref "refs/custom/replace/$original_head" "$changed_head"; then
    begin j13_replace_ref_base_cannot_change_project_cleanliness env GIT_REPLACE_REF_BASE=refs/custom/replace/ sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.head' "$original_head"
    fact '.clean' true
    finish_git_case
else
    setup_failed j13_replace_ref_base_cannot_change_project_cleanliness
fi

mk j13_no_replace_objects_cannot_change_project_cleanliness
if git_project && printf original >"$t/sandbox/project/tracked.txt" && git_in_project add tracked.txt && git_in_project -c user.name=probe -c user.email=probe@example.invalid commit -q -m original && original_head=$(git_in_project rev-parse --verify HEAD) && printf changed >"$t/sandbox/project/tracked.txt" && git_in_project add tracked.txt && git_in_project -c user.name=probe -c user.email=probe@example.invalid commit -q -m changed && changed_head=$(git_in_project rev-parse --verify HEAD) && git_in_project checkout -q "$original_head" && git_in_project update-ref "refs/replace/$original_head" "$changed_head"; then
    begin j13_no_replace_objects_cannot_change_project_cleanliness env GIT_NO_REPLACE_OBJECTS=1 sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.head' "$original_head"
    fact '.clean' false
    finish_git_case
else
    setup_failed j13_no_replace_objects_cannot_change_project_cleanliness
fi

mk j05_foreign_git_dir_cannot_select_a_nonrepo_project
if git_foreign_repo "$t/foreign" && printf project >"$t/sandbox/project/file.txt" && foreign_head=$(git_fixture -C "$t/foreign" rev-parse --verify HEAD) && foreign_state=$(git_public_state "$t/foreign"); then
    begin j05_foreign_git_dir_cannot_select_a_nonrepo_project env GIT_DIR="$t/foreign/.git" GIT_WORK_TREE="$t/sandbox/project" sh "$t/probe" --only J05
    expect_rc 0
    expect_report J05 sandbox
    expect git_work_tree FAIL 'not a git work tree'
    fact '.git_work_tree' false
    [ -n "$foreign_head" ] || problems="$problems foreign-head-not-captured"
    foreign_state_after=$(git_public_state "$t/foreign") || problems="$problems foreign-state-unreadable"
    [ "$foreign_state_after" = "$foreign_state" ] || problems="$problems foreign-state-changed"
    finish_git_case
else
    setup_failed j05_foreign_git_dir_cannot_select_a_nonrepo_project
fi

mk j13_foreign_git_dir_cannot_select_a_nonrepo_project
if git_foreign_repo "$t/foreign" && printf project >"$t/sandbox/project/file.txt" && foreign_head=$(git_fixture -C "$t/foreign" rev-parse --verify HEAD) && foreign_state=$(git_public_state "$t/foreign"); then
    begin j13_foreign_git_dir_cannot_select_a_nonrepo_project env GIT_DIR="$t/foreign/.git" GIT_WORK_TREE="$t/sandbox/project" sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree FAIL 'not a git work tree'
    expect work_tree_status SKIP 'git status not run'
    fact '.branch' null
    fact '.head' null
    [ -n "$foreign_head" ] || problems="$problems foreign-head-not-captured"
    foreign_state_after=$(git_public_state "$t/foreign") || problems="$problems foreign-state-unreadable"
    [ "$foreign_state_after" = "$foreign_state" ] || problems="$problems foreign-state-changed"
    finish_git_case
else
    setup_failed j13_foreign_git_dir_cannot_select_a_nonrepo_project
fi

mk j13_foreign_common_dir_cannot_change_project_state
if mkdir -p "$t/source" && git_fixture -C "$t/source" init -q && git_fixture -C "$t/source" -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m project && git_fixture -C "$t/source" worktree add -q -b project-only "$t/sandbox/project" && git_foreign_repo "$t/foreign" && project_head=$(git_fixture -C "$t/sandbox/project" rev-parse --verify HEAD) && foreign_state=$(git_public_state "$t/foreign"); then
    begin j13_foreign_common_dir_cannot_change_project_state env GIT_COMMON_DIR="$t/foreign/.git" sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.branch' project-only
    fact '.head' "$project_head"
    fact '.clean' true
    foreign_state_after=$(git_public_state "$t/foreign") || problems="$problems foreign-state-unreadable"
    [ "$foreign_state_after" = "$foreign_state" ] || problems="$problems foreign-state-changed"
    finish_git_case
else
    setup_failed j13_foreign_common_dir_cannot_change_project_state
fi

mk j13_foreign_index_cannot_change_project_cleanliness
if git_project && printf project >"$t/sandbox/project/tracked.txt" && git_in_project add tracked.txt && git_in_project -c user.name=probe -c user.email=probe@example.invalid commit -q -m project && project_head=$(git_in_project rev-parse --verify HEAD) && git_foreign_repo "$t/foreign" && printf foreign >"$t/foreign/tracked.txt" && git_fixture -C "$t/foreign" add tracked.txt && git_fixture -C "$t/foreign" -c user.name=probe -c user.email=probe@example.invalid commit -q -m foreign-file && foreign_state=$(git_public_state "$t/foreign"); then
    begin j13_foreign_index_cannot_change_project_cleanliness env GIT_INDEX_FILE="$t/foreign/.git/index" sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.head' "$project_head"
    fact '.clean' true
    foreign_state_after=$(git_public_state "$t/foreign") || problems="$problems foreign-state-unreadable"
    [ "$foreign_state_after" = "$foreign_state" ] || problems="$problems foreign-state-changed"
    finish_git_case
else
    setup_failed j13_foreign_index_cannot_change_project_cleanliness
fi

mk j13_foreign_object_directory_cannot_break_project_status
if git_project && project_head=$(git_in_project rev-parse --verify HEAD) && git_foreign_repo "$t/foreign" && foreign_state=$(git_public_state "$t/foreign"); then
    begin j13_foreign_object_directory_cannot_break_project_status env GIT_OBJECT_DIRECTORY="$t/foreign/.git/objects" sh "$t/probe" --only J13
    expect_rc 0
    expect_report J13 sandbox
    expect work_tree_status PASS 'git status ran'
    fact '.head' "$project_head"
    fact '.clean' true
    foreign_state_after=$(git_public_state "$t/foreign") || problems="$problems foreign-state-unreadable"
    [ "$foreign_state_after" = "$foreign_state" ] || problems="$problems foreign-state-changed"
    finish_git_case
else
    setup_failed j13_foreign_object_directory_cannot_break_project_status
fi

mk j05_hashes_every_file_by_its_exact_name
if git_project; then
    printf a >"$t/sandbox/project/plain.txt"
    printf n >"$t/sandbox/project/$(printf 'new\nline')"
    printf b >"$t/sandbox/project/back\\slash"
    printf h >"$t/sandbox/project/.hidden"
    begin j05_hashes_every_file_by_its_exact_name sh "$t/probe" --only J05
    expect_rc 0
    expect_report J05 sandbox
    expect files PASS '4 files'
    fact '[.files[].path] | sort | join(",")' '.hidden,back\slash,new
line,plain.txt'
    fact '.files[] | select(.path == "new\nline") | .sha256' "$(printf n | sha256sum | cut -d' ' -f1)"
    fact '.files[] | select(.path == "back\\slash") | .sha256' "$(printf b | sha256sum | cut -d' ' -f1)"
    finish_case
else
    setup_failed j05_hashes_every_file_by_its_exact_name
fi

mk j05_a_file_that_cannot_be_hashed_fails_the_files_check
if git_project; then
    printf a >"$t/sandbox/project/plain.txt"
    printf u >"$t/sandbox/project/unreadable.txt"
    mkdir -p "$t/bin"
    real_sum=$(command -v sha256sum)
    cat >"$t/bin/sha256sum" <<EOF
#!/bin/sh
rc=0
n=\$#
while [ \$n -gt 0 ]; do
    arg=\$1
    shift
    n=\$((n - 1))
    case \$arg in
        *unreadable.txt)
            echo "sha256sum: \$arg: Permission denied" >&2
            rc=1
            ;;
        *) set -- "\$@" "\$arg" ;;
    esac
done
$real_sum "\$@"
[ \$rc -eq 0 ] || exit 1
EOF
    chmod +x "$t/bin/sha256sum"
    begin j05_a_file_that_cannot_be_hashed_fails_the_files_check env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J05
    expect_rc 0
    expect_report J05 sandbox
    expect files FAIL 'unreadable.txt: Permission denied'
    finish_case
else
    setup_failed j05_a_file_that_cannot_be_hashed_fails_the_files_check
fi

mk j15_runs_the_hello_world_image_by_digest
mkdir -p "$t/bin/docker-data"
cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
data=$(dirname "$0")/docker-data
case "$#:$1:${2-}:${3-}" in
    "3:run:--rm:hello-world@sha256:c567b231f65614688711a75f31518a064258a51d442117a3e771a3a8fdba78ef")
        : >"$data/run.called"
        if [ "$(cat "$data/run.stream")" = stderr ]; then
            cat "$data/run.out" >&2 || exit 91
        else
            cat "$data/run.out" || exit 91
        fi
        status=$(cat "$data/run.status")
        printf '%s\n' "$status" >"$data/run.complete"
        exit "$status"
        ;;
    "3:info:--format:{{.ID}} {{.ServerVersion}}")
        : >"$data/info.called"
        cat "$data/info.out" || exit 92
        status=$(cat "$data/info.status")
        printf '%s\n' "$status" >"$data/info.complete"
        exit "$status"
        ;;
    *) exit 93 ;;
esac
EOF
chmod +x "$t/bin/docker"

j15_docker_case() {
    printf '%b' "$1" >"$t/bin/docker-data/run.out"
    printf '%b' "$2" >"$t/bin/docker-data/info.out"
    printf '%s\n' "${3:-0}" >"$t/bin/docker-data/run.status"
    printf '%s\n' "${4:-0}" >"$t/bin/docker-data/info.status"
    printf '%s\n' "${5:-stdout}" >"$t/bin/docker-data/run.stream"
    rm -f "$t/bin/docker-data"/*.called "$t/bin/docker-data"/*.complete
}

j15_begin() {
    begin "$1" env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J15 --docker on
    expect_rc 0
    expect_report J15 sandbox
    [ -f "$t/bin/docker-data/run.called" ] || problems="$problems run-not-invoked"
    [ -f "$t/bin/docker-data/info.called" ] || problems="$problems info-not-invoked"
    [ -f "$t/bin/docker-data/run.complete" ] || problems="$problems run-not-drained"
    [ -f "$t/bin/docker-data/info.complete" ] || problems="$problems info-not-drained"
}

j15_marker() {
    path=$1
    want=$2
    got=$(cat "$path" 2>/dev/null)
    [ "$got" = "$want" ] || problems="$problems marker[$path]=[$got](want [$want])"
}

j15_install_receipt_fixture() {
    mkdir -p "$t/bin/docker-data"
    cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
data=$(dirname "$0")/docker-data
case "$#:$1:${2-}:${3-}" in
    "3:run:--rm:hello-world@sha256:c567b231f65614688711a75f31518a064258a51d442117a3e771a3a8fdba78ef") : >"$data/run.called"; cat "$data/run.out" || exit 91; status=$(cat "$data/run.status") || exit 92; printf '%s\n' "$status" >"$data/run.complete"; exit "$status" ;;
    "3:info:--format:{{.ID}} {{.ServerVersion}}") : >"$data/info.called"; cat "$data/info.out" || exit 93; status=$(cat "$data/info.status") || exit 94; printf '%s\n' "$status" >"$data/info.complete"; exit "$status" ;;
    *) exit 95 ;;
esac
EOF
    chmod +x "$t/bin/docker"
}

j15_docker_case 'prefix Hello from Docker! suffix\n' 'ENGINE-ID 1.2.3\n'
j15_begin j15_docker_run_and_info_are_recognized_independently
expect hello_world PASS '@sha256:'
expect engine PASS 'ENGINE-ID'
fact '.run.hello' true
fact '.run.exit_code' 0
fact '.engine.id' ENGINE-ID
fact '.engine.server_version' 1.2.3
finish_case

j15_docker_case 'prefix Hello from Docker! suffix\n' ' ENGINE-ID 1.2.3\n' 0 0 stderr
j15_begin j15_docker_run_merged_stderr_and_info_whitespace_are_accepted
expect hello_world PASS '@sha256:'
expect engine PASS 'ENGINE-ID'
fact '.run.hello' true
fact '.engine.id' ENGINE-ID
fact '.engine.server_version' 1.2.3
finish_case

mk j15_odd_nibble_greeting_is_not_a_run_greeting
j15_install_receipt_fixture
python3 - "$t/bin/docker-data/run.out" <<'PY'
import sys

greeting = b"Hello from Docker!"
data = bytes.fromhex("0" + greeting.hex() + "0")
if greeting.hex() not in data.hex() or data.hex().find(greeting.hex()) != 1 or greeting in data:
    raise SystemExit(1)
with open(sys.argv[1], "wb") as output:
    output.write(data)
PY
fixture_rc=$?
printf 'ENGINE-ID 1.2.3\n' >"$t/bin/docker-data/info.out"
printf '0\n' >"$t/bin/docker-data/run.status"
printf '0\n' >"$t/bin/docker-data/info.status"
if [ "$fixture_rc" -eq 0 ]; then
    j15_begin j15_odd_nibble_greeting_is_not_a_run_greeting
    j15_marker "$t/bin/docker-data/run.complete" 0
    j15_marker "$t/bin/docker-data/info.complete" 0
    expect hello_world FAIL ''
    fact '.run.hello' false
    fact '.run.exit_code' 0
    expect engine PASS 'ENGINE-ID'
    fact '.engine.id' ENGINE-ID
    fact '.engine.server_version' 1.2.3
    finish_case
else
    setup_failed j15_odd_nibble_greeting_is_not_a_run_greeting
fi

mk j15_aligned_greeting_after_odd_nibble_match_is_found
j15_install_receipt_fixture
python3 - "$t/bin/docker-data/run.out" <<'PY'
import sys

greeting = b"Hello from Docker!"
misleading = bytes.fromhex("0" + greeting.hex() + "0")
data = misleading + greeting
if greeting.hex() not in data.hex() or data.hex().find(greeting.hex()) != 1:
    raise SystemExit(1)
if data.find(greeting) != len(misleading):
    raise SystemExit(1)
with open(sys.argv[1], "wb") as output:
    output.write(data)
PY
fixture_rc=$?
printf 'ENGINE-ID 1.2.3\n' >"$t/bin/docker-data/info.out"
printf '0\n' >"$t/bin/docker-data/run.status"
printf '0\n' >"$t/bin/docker-data/info.status"
if [ "$fixture_rc" -eq 0 ]; then
    j15_begin j15_aligned_greeting_after_odd_nibble_match_is_found
    j15_marker "$t/bin/docker-data/run.complete" 0
    j15_marker "$t/bin/docker-data/info.complete" 0
    expect hello_world PASS '@sha256:'
    fact '.run.hello' true
    fact '.run.exit_code' 0
    expect engine PASS 'ENGINE-ID'
    fact '.engine.id' ENGINE-ID
    fact '.engine.server_version' 1.2.3
    finish_case
else
    setup_failed j15_aligned_greeting_after_odd_nibble_match_is_found
fi

mk j15_info_preserves_first_line_version_remainder
j15_install_receipt_fixture
printf 'Hello from Docker!\n' >"$t/bin/docker-data/run.out"
python3 - "$t/bin/docker-data/info.out" <<'PY'
import sys

with open(sys.argv[1], "wb") as output:
    output.write(b" \tENGINE-ID  1.2.3  build\tflavor \t\nSECOND-ID 9.9\n")
PY
printf '0\n' >"$t/bin/docker-data/run.status"
printf '0\n' >"$t/bin/docker-data/info.status"
j15_ifs=$(printf ' \t\n')
IFS=$j15_ifs read -r j15_expected_id j15_expected_version <"$t/bin/docker-data/info.out"
expected_version=$(printf '1.2.3  build\tflavor')
if [ "$j15_expected_id" != ENGINE-ID ] || [ "$j15_expected_version" != "$expected_version" ]; then
    setup_failed j15_info_preserves_first_line_version_remainder
else
    j15_begin j15_info_preserves_first_line_version_remainder
    j15_marker "$t/bin/docker-data/run.complete" 0
    j15_marker "$t/bin/docker-data/info.complete" 0
    expect hello_world PASS '@sha256:'
    fact '.run.hello' true
    fact '.run.exit_code' 0
    expect engine PASS 'ENGINE-ID'
    fact '.engine.id' ENGINE-ID
    fact '.engine.server_version' "$expected_version"
    finish_case
fi

mk j15_greeting_crosses_encoded_line_boundary
mkdir -p "$t/bin/docker-data"
cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
data=$(dirname "$0")/docker-data
case "$#:$1:${2-}:${3-}" in
    "3:run:--rm:hello-world@sha256:c567b231f65614688711a75f31518a064258a51d442117a3e771a3a8fdba78ef") : >"$data/run.called"; cat "$data/run.out" || exit 91; : >"$data/run.complete"; exit 0 ;;
    "3:info:--format:{{.ID}} {{.ServerVersion}}") : >"$data/info.called"; printf 'ENGINE-ID 1.2.3\n'; : >"$data/info.complete"; exit 0 ;;
    *) exit 93 ;;
esac
EOF
chmod +x "$t/bin/docker"
j15_docker_case 'x' ' \tENGINE-ID 1.2.3\n'
python3 - "$t/bin/docker-data/run.out" <<'PY'
import sys

with open(sys.argv[1], "wb") as output:
    output.write(b"x" * 15 + b"Hello from Docker!\n")
PY
begin j15_greeting_crosses_encoded_line_boundary env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J15 --docker on
expect_rc 0
expect_report J15 sandbox
expect hello_world PASS '@sha256:'
expect engine PASS 'ENGINE-ID'
fact '.run.hello' true
fact '.engine.id' ENGINE-ID
fact '.engine.server_version' 1.2.3
[ -f "$t/bin/docker-data/run.complete" ] || problems="$problems run-not-drained"
[ -f "$t/bin/docker-data/info.complete" ] || problems="$problems info-not-drained"
finish_case

j15_write_exact() {
    output=$1
    size=$2
    prefix=$3
    python3 - "$output" "$size" "$prefix" <<'PY'
import sys

path, size, prefix = sys.argv[1], int(sys.argv[2]), sys.argv[3].encode().decode("unicode_escape").encode()
if len(prefix) > size:
    raise SystemExit(2)
with open(path, "wb") as output:
    output.write(prefix)
    output.write(b"x" * (size - len(prefix)))
PY
}

j15_run_below=1000
j15_run_exact=65536
j15_run_over=65537
j15_run_pipe=4194304
j15_info_below=1000
j15_info_exact=65536
j15_info_over=65537
j15_info_pipe=4194304

for size in "$j15_run_below" "$j15_run_exact"; do
    mk "j15_run_complete_$size"
    mkdir -p "$t/bin/docker-data"
    cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
data=$(dirname "$0")/docker-data
case "$#:$1:${2-}:${3-}" in
    "3:run:--rm:hello-world@sha256:c567b231f65614688711a75f31518a064258a51d442117a3e771a3a8fdba78ef") : >"$data/run.called"; cat "$data/run.out" || exit 91; printf '0\n' >"$data/run.complete"; exit 0 ;;
    "3:info:--format:{{.ID}} {{.ServerVersion}}") : >"$data/info.called"; cat "$data/info.out" || exit 92; printf '0\n' >"$data/info.complete"; exit 0 ;;
    *) exit 93 ;;
esac
EOF
    chmod +x "$t/bin/docker"
    j15_write_exact "$t/bin/docker-data/run.out" "$size" 'Hello from Docker!'
    printf 'ENGINE-ID 1.2.3\n' >"$t/bin/docker-data/info.out"
    printf 0 >"$t/bin/docker-data/run.status"
    printf 0 >"$t/bin/docker-data/info.status"
    printf stdout >"$t/bin/docker-data/run.stream"
    begin "j15_run_complete_$size" env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J15 --docker on
    expect_rc 0
    expect_report J15 sandbox
    expect hello_world PASS '@sha256:'
    expect engine PASS 'ENGINE-ID'
    fact '.run.hello' true
    fact '.run.exit_code' 0
    fact '.engine.id' ENGINE-ID
    j15_marker "$t/bin/docker-data/run.complete" 0
    j15_marker "$t/bin/docker-data/info.complete" 0
    finish_case
done

for size in "$j15_info_below" "$j15_info_exact"; do
    mk "j15_info_complete_$size"
    mkdir -p "$t/bin/docker-data"
    cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
data=$(dirname "$0")/docker-data
case "$#:$1:${2-}:${3-}" in
    "3:run:--rm:hello-world@sha256:c567b231f65614688711a75f31518a064258a51d442117a3e771a3a8fdba78ef") : >"$data/run.called"; printf 'Hello from Docker!\n'; printf '0\n' >"$data/run.complete"; exit 0 ;;
    "3:info:--format:{{.ID}} {{.ServerVersion}}") : >"$data/info.called"; cat "$data/info.out" || exit 92; printf '0\n' >"$data/info.complete"; exit 0 ;;
    *) exit 93 ;;
esac
EOF
    chmod +x "$t/bin/docker"
    printf 'Hello from Docker!\n' >"$t/bin/docker-data/run.out"
    j15_write_exact "$t/bin/docker-data/info.out" "$size" ' ENGINE-ID 1.2.3\n'
    printf 0 >"$t/bin/docker-data/run.status"
    printf 0 >"$t/bin/docker-data/info.status"
    printf stdout >"$t/bin/docker-data/run.stream"
    begin "j15_info_complete_$size" env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J15 --docker on
    expect_rc 0
    expect_report J15 sandbox
    expect engine PASS 'ENGINE-ID'
    expect hello_world PASS '@sha256:'
    fact '.run.hello' true
    fact '.run.exit_code' 0
    fact '.engine.id' ENGINE-ID
    fact '.engine.server_version' 1.2.3
    j15_marker "$t/bin/docker-data/run.complete" 0
    j15_marker "$t/bin/docker-data/info.complete" 0
    finish_case
done

j15_capture_overflow_case() {
    command=$1
    size=$2
    mk "j15_${command}_overflow_$size"
    mkdir -p "$t/bin/docker-data"
    cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
data=$(dirname "$0")/docker-data
case "$#:$1:${2-}:${3-}" in
    "3:run:--rm:hello-world@sha256:c567b231f65614688711a75f31518a064258a51d442117a3e771a3a8fdba78ef") : >"$data/run.called"; cat "$data/run.out" || exit 91; printf '0\n' >"$data/run.complete"; exit 0 ;;
    "3:info:--format:{{.ID}} {{.ServerVersion}}") : >"$data/info.called"; cat "$data/info.out" || exit 92; printf '0\n' >"$data/info.complete"; exit 0 ;;
    *) exit 93 ;;
esac
EOF
    chmod +x "$t/bin/docker"
    printf 'Hello from Docker!\n' >"$t/bin/docker-data/run.out"
    printf 'ENGINE-ID 1.2.3\n' >"$t/bin/docker-data/info.out"
    if [ "$command" = run ]; then
        j15_write_exact "$t/bin/docker-data/run.out" "$size" 'prefix Hello from Docker!\n!P\t17\n!H\n4869\n!O\t0\n!D\t0\n!E\t0\t0\t0\n'
    else
        j15_write_exact "$t/bin/docker-data/info.out" "$size" 'ENGINE-ID 1.2.3\n!P\t17\n!H\n4869\n!O\t0\n!D\t0\n!E\t0\t0\t0\n'
    fi
    printf 0 >"$t/bin/docker-data/run.status"
    printf 0 >"$t/bin/docker-data/info.status"
    printf stdout >"$t/bin/docker-data/run.stream"
    begin "j15_${command}_overflow_$size" env PATH="$t/bin:$scratch/shim:$scratch/tools" sh "$t/probe" --only J15 --docker on
    expect_rc 0
    expect_report J15 sandbox
    if [ "$command" = run ]; then
        expect hello_world FAIL 'incomplete'
        fact '.run.hello' false
        fact '.run.exit_code' 0
        expect engine PASS 'ENGINE-ID'
        fact '.engine.id' ENGINE-ID
    else
        expect hello_world PASS '@sha256:'
        fact '.run.hello' true
        expect engine FAIL ''
        fact '.engine.id' null
        fact '.engine.server_version' null
    fi
    j15_marker "$t/bin/docker-data/run.complete" 0
    j15_marker "$t/bin/docker-data/info.complete" 0
    finish_case
}

for size in "$j15_run_over" "$j15_run_pipe"; do j15_capture_overflow_case run "$size"; done
for size in "$j15_info_over" "$j15_info_pipe"; do j15_capture_overflow_case info "$size"; done

mk j15_run_nonzero_preserves_complete_greeting_and_exit_status
mkdir -p "$t/bin/docker-data"
cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
data=$(dirname "$0")/docker-data
case "$#:$1:${2-}:${3-}" in
    "3:run:--rm:hello-world@sha256:c567b231f65614688711a75f31518a064258a51d442117a3e771a3a8fdba78ef") : >"$data/run.called"; cat "$data/run.out" || exit 91; status=$(cat "$data/run.status"); printf '%s\n' "$status" >"$data/run.complete"; exit "$status" ;;
    "3:info:--format:{{.ID}} {{.ServerVersion}}") : >"$data/info.called"; cat "$data/info.out" || exit 92; status=$(cat "$data/info.status"); printf '%s\n' "$status" >"$data/info.complete"; exit "$status" ;;
    *) exit 93 ;;
esac
EOF
chmod +x "$t/bin/docker"
j15_docker_case 'Hello from Docker!\n' 'ENGINE-ID 1.2.3\n' 23 0
j15_begin j15_run_nonzero_preserves_complete_greeting_and_exit_status
j15_marker "$t/bin/docker-data/run.complete" 23
j15_marker "$t/bin/docker-data/info.complete" 0
expect hello_world FAIL '@sha256:'
fact '.run.hello' true
fact '.run.exit_code' 23
expect engine PASS 'ENGINE-ID'
finish_case

mk j15_info_nonzero_does_not_trust_engine_data
mkdir -p "$t/bin/docker-data"
cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
data=$(dirname "$0")/docker-data
case "$#:$1:${2-}:${3-}" in
    "3:run:--rm:hello-world@sha256:c567b231f65614688711a75f31518a064258a51d442117a3e771a3a8fdba78ef") : >"$data/run.called"; cat "$data/run.out" || exit 91; status=$(cat "$data/run.status"); printf '%s\n' "$status" >"$data/run.complete"; exit "$status" ;;
    "3:info:--format:{{.ID}} {{.ServerVersion}}") : >"$data/info.called"; cat "$data/info.out" || exit 92; status=$(cat "$data/info.status"); printf '%s\n' "$status" >"$data/info.complete"; exit "$status" ;;
    *) exit 93 ;;
esac
EOF
chmod +x "$t/bin/docker"
j15_docker_case 'Hello from Docker!\n' 'ENGINE-ID 1.2.3\n' 0 24
j15_begin j15_info_nonzero_does_not_trust_engine_data
j15_marker "$t/bin/docker-data/run.complete" 0
j15_marker "$t/bin/docker-data/info.complete" 24
expect hello_world PASS '@sha256:'
expect engine FAIL ''
fact '.engine.id' null
fact '.engine.server_version' null
finish_case

j15_docker_case 'no greeting\n' '\n'
j15_begin j15_missing_greeting_and_empty_engine_id_fail
expect hello_world FAIL '@sha256:'
fact '.run.hello' false
fact '.run.exit_code' 0
expect engine FAIL ''
fact '.engine.id' null
fact '.engine.server_version' null
finish_case

mk j15_od_execution_failure
mkdir -p "$t/bin/docker-data" "$t/private-tools"
for tool in awk basename cat chmod cp cut date dirname env find grep head jq ls mkdir mkfifo mktemp mv od python3 readlink rm rmdir sed sha256sum sh sleep sort stat tail tee timeout touch tr wc git; do
    found=$(command -v "$tool") || exit 70
    ln -s "$found" "$t/private-tools/$tool"
done
cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
data=$(dirname "$0")/docker-data
case "$#:$1:${2-}:${3-}" in
    "3:run:--rm:hello-world@sha256:c567b231f65614688711a75f31518a064258a51d442117a3e771a3a8fdba78ef") : >"$data/run.called"; cat "$data/run.out" || exit 91; status=$(cat "$data/run.status") || exit 92; printf '%s\n' "$status" >"$data/run.complete"; exit "$status" ;;
    "3:info:--format:{{.ID}} {{.ServerVersion}}") : >"$data/info.called"; cat "$data/info.out" || exit 93; status=$(cat "$data/info.status") || exit 94; printf '%s\n' "$status" >"$data/info.complete"; exit "$status" ;;
    *) exit 93 ;;
esac
EOF
chmod +x "$t/bin/docker"
printf 'Hello from Docker!\n' >"$t/bin/docker-data/run.out"
printf 'ENGINE-ID 1.2.3\n' >"$t/bin/docker-data/info.out"
printf '0\n' >"$t/bin/docker-data/run.status"
printf '0\n' >"$t/bin/docker-data/info.status"
seam SANDBOX_PATH "$t/bin:$scratch/shim:$t/private-tools"
begin j15_private_od_control_succeeds env PATH="$t/bin:$scratch/shim:$t/private-tools" sh "$t/probe" --only J15 --docker on
expect_rc 0
expect_report J15 sandbox
expect hello_world PASS '@sha256:'
expect engine PASS 'ENGINE-ID'
fact '.run.hello' true
fact '.engine.id' ENGINE-ID
[ -f "$t/bin/docker-data/run.called" ] || problems="$problems run-not-invoked"
[ -f "$t/bin/docker-data/info.called" ] || problems="$problems info-not-invoked"
[ -f "$t/bin/docker-data/run.complete" ] || problems="$problems run-not-drained"
[ -f "$t/bin/docker-data/info.complete" ] || problems="$problems info-not-drained"
finish_case
rm -f "$t/seams.sed"

rm -f "$t/bin/docker-data"/*.called "$t/bin/docker-data"/*.complete
printf '11\n' >"$t/bin/docker-data/run.status"
printf '12\n' >"$t/bin/docker-data/info.status"
rm "$t/private-tools/od"
: >"$t/private-tools/od"
chmod -x "$t/private-tools/od"
if env PATH="$t/bin:$scratch/shim:$t/private-tools" timeout 5 od </dev/null >/dev/null 2>&1; then
    setup_failed j15_od_execution_failure_unavailable
else
    od_rc=$?
    if [ "$od_rc" -ne 126 ]; then
        setup_failed j15_od_execution_failure_unavailable
    else
        seam SANDBOX_PATH "$t/bin:$scratch/shim:$t/private-tools"
        begin j15_od_execution_failure_does_not_trust_either_capture env PATH="$t/bin:$scratch/shim:$t/private-tools" sh "$t/probe" --only J15 --docker on
        expect_rc 0
        expect_report J15 sandbox
        expect hello_world FAIL 'incomplete'
        fact '.run.hello' false
        fact '.run.exit_code' "$(cat "$t/bin/docker-data/run.complete" 2>/dev/null)"
        expect engine FAIL ''
        fact '.engine.id' null
        fact '.engine.server_version' null
        j15_marker "$t/bin/docker-data/run.complete" 11
        j15_marker "$t/bin/docker-data/info.complete" 12
        [ -f "$t/bin/docker-data/run.called" ] || problems="$problems run-not-invoked"
        [ -f "$t/bin/docker-data/info.called" ] || problems="$problems info-not-invoked"
        [ -f "$t/bin/docker-data/run.complete" ] || problems="$problems run-not-drained"
        [ -f "$t/bin/docker-data/info.complete" ] || problems="$problems info-not-drained"
        finish_case
        rm -f "$t/seams.sed"
    fi
fi
rm -f "$t/private-tools/od"
ln -s "$(command -v od)" "$t/private-tools/od"

codex_prints() {
    mkdir -p "$t/bin"
    printf '#!/bin/sh\nprintf "%%s" "%s"\nexit %s\n' "$1" "$2" >"$t/bin/codex"
    chmod +x "$t/bin/codex"
    if [ -n "$1" ]; then
        printf '%s' "$1" >"$t/expected-version"
    else
        printf 'expected-nonempty-version' >"$t/expected-version"
    fi
    seam AGENT_BIN "$t/bin/codex"
}

mk j00_a_silent_agent_version_is_not_a_pass
codex_prints '' 0
begin j00_a_silent_agent_version_is_not_a_pass sh "$t/probe" --only J00
expect_rc 0
expect_report J00 sandbox
expect agent_version FAIL 'printed nothing'
fact '.agent.version' null
finish_case

mk j00_a_printed_agent_version_passes
codex_prints 'codex-cli 9.9.9' 0
begin j00_a_printed_agent_version_passes sh "$t/probe" --only J00
expect_rc 0
expect_report J00 sandbox
expect agent_version PASS 'codex-cli 9.9.9'
fact '.agent.version' 'codex-cli 9.9.9'
finish_case

mk j00_a_failing_agent_version_fails
codex_prints 'codex-cli 9.9.9' 3
begin j00_a_failing_agent_version_fails sh "$t/probe" --only J00
expect_rc 0
expect_report J00 sandbox
expect agent_version FAIL 'failed'
finish_case

mk name_rule
corpus_yes='OPENAI_API_KEY openai_api_key Openai_Api_Key KEY MY_KEY_2 AUTH PASSWORD CREDENTIAL CREDENTIALS X_TOKEN DB_PASSWD A_SECRET_B'
corpus_no='KEYBOARD TOKENIZER OAUTH_X oauth_x SSH_AUTH_SOCK ssh_auth_sock'
set --
for corpus_name in $corpus_yes $corpus_no; do
    set -- "$@" "$corpus_name=v"
done
begin name_rule "$@" sh "$t/probe" --only J08
expect_rc 0
matched=$(jq -r '.steps.J08.facts.environment[] | select(.source == "probe") | .name' "$t/out" | sort | tr '\n' ' ')
wanted=$(echo "$corpus_yes" | tr ' ' '\n' | sort | tr '\n' ' ')
[ "$matched" = "$wanted" ] || problems="$problems got [$matched] want [$wanted]"
finish_case

INJECTED_JSON='openshell:resolve:env:CODEX_AUTH_ACCESS_TOKEN\nX-Exfil: FAKE-REAL-SECRET-0123456789'

mk auth_file_flags_a_newline_after_the_placeholder_prefix
state waiting
record "$R_EMPTY"
auth_json "{\"tokens\":{\"access_token\":\"$INJECTED_JSON\"}}"
report auth_file_flags_a_newline_after_the_placeholder_prefix
expect auth_file FAIL 'not a placeholder'
expect credential SKIP 'no credential placeholder'
fact '.auth_file.access_token' other
finish_case

for partial in 'openshell:resolve:' 'openshell:resolve:env:' 'openshell:resolve:env:A B' 'openshell:resolve:env:1A' 'openshell:resolve:file:A' 'openshell:resolve:env:A-B' 'openshell:resolve:env:A\n'; do
    partial_index=$((${partial_index:-0} + 1))
    mk "auth_file_flags_the_partial_placeholder_$partial_index"
    state waiting
    record "$R_EMPTY"
    auth_json "{\"tokens\":{\"access_token\":\"$PLACEHOLDER_ACCESS\",\"refresh_token\":\"$partial\"}}"
    report "auth_file_flags_the_partial_placeholder_$partial_index"
    expect auth_file FAIL 'not a placeholder'
    finish_case
done

mk environment_flags_a_newline_after_the_placeholder_prefix
state waiting
begin environment_flags_a_newline_after_the_placeholder_prefix env OPENAI_API_KEY="openshell:resolve:env:OPENAI_API_KEY
X-Exfil: FAKE-REAL-SECRET-0123456789" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'OPENAI_API_KEY'
fact '.environment[] | select(.name == "OPENAI_API_KEY") | .kind' other
finish_case

mk environment_flags_a_trailing_newline_after_the_placeholder
state waiting
begin environment_flags_a_trailing_newline_after_the_placeholder env OPENAI_API_KEY="openshell:resolve:env:OPENAI_API_KEY
" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'OPENAI_API_KEY'
finish_case

mk environment_reads_the_continuation_of_a_credential_in_the_main_environment
state waiting
proc_main
{
    printf 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY\nX-Exfil: FAKE-REAL-SECRET-0123456789\0'
} >"$t/proc/100/environ"
verify environment_reads_the_continuation_of_a_credential_in_the_main_environment FAIL 'OPENAI_API_KEY' absent

mk environment_flags_an_assignment_shaped_continuation_in_the_probe_environment
state 'exited 1 0'
record "$R_OK1"
begin environment_flags_an_assignment_shaped_continuation_in_the_probe_environment env OPENAI_API_KEY="openshell:resolve:env:OPENAI_API_KEY
EXFIL=FAKE-REAL-SECRET-0123456789" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'OPENAI_API_KEY'
not_disclosed 'FAKE-REAL-SECRET-0123456789'
finish_case

mk environment_keeps_a_separate_noncredential_entry_separate
state 'exited 1 0'
record "$R_OK1"
begin environment_keeps_a_separate_noncredential_entry_separate env OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY GITHUB_TOKEN= EXFIL=FAKE-REAL-SECRET-0123456789 sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment PASS 'every credential variable is a placeholder or empty'
fact '.environment[] | select(.name == "OPENAI_API_KEY" and .source == "probe") | .kind' placeholder
fact '.environment[] | select(.name == "GITHUB_TOKEN" and .source == "probe") | .kind' empty
not_disclosed 'FAKE-REAL-SECRET-0123456789'
finish_case

mk main_environment_flags_an_assignment_shaped_continuation
state 'exited 1 0'
record "$R_OK1"
proc_main
proc_codex
environ 100 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY
EXFIL=FAKE-REAL-SECRET-0123456789'
environ 101 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
begin main_environment_flags_an_assignment_shaped_continuation sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'OPENAI_API_KEY'
not_disclosed 'FAKE-REAL-SECRET-0123456789'
finish_case

mk codex_environment_flags_an_assignment_shaped_continuation
state 'exited 1 0'
record "$R_OK1"
proc_main
proc_codex
environ 100 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
environ 101 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY
EXFIL=FAKE-REAL-SECRET-0123456789'
begin codex_environment_flags_an_assignment_shaped_continuation sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'OPENAI_API_KEY'
not_disclosed 'FAKE-REAL-SECRET-0123456789'
finish_case

for partial in 'openshell:resolve:' 'openshell:resolve:env:' 'openshell:resolve:env:A B' 'openshell:resolve:env:1A' 'openshell:resolve:file:A' 'openshell:resolve:env:A-B'; do
    partial_index=$((${partial_index:-0} + 1))
    mk "environment_flags_the_partial_placeholder_$partial_index"
    state waiting
    begin "environment_flags_the_partial_placeholder_$partial_index" env X_TOKEN="$partial" sh "$t/probe" --only J08
    expect_rc 0
    expect_report J08 sandbox
    expect environment FAIL 'X_TOKEN'
    finish_case
done

mk environment_accepts_the_full_placeholder_in_a_lower_case_name
state waiting
begin environment_accepts_the_full_placeholder_in_a_lower_case_name env openai_api_key="openshell:resolve:env:OPENAI_API_KEY" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect credential PASS '1 placeholder variables'
fact '.environment[] | select(.name == "openai_api_key") | .kind' placeholder
finish_case

mk environment_flags_a_real_value_in_a_lower_case_name
state waiting
begin environment_flags_a_real_value_in_a_lower_case_name env openai_api_key=FAKE-real-key sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect environment FAIL 'openai_api_key'
finish_case

mk file_scan_flags_sk_after_a_json_newline_escape
state waiting
record "$R_W0"
printf '{"k":"x\\nsk-%s"}\n' FAKEFAKEFAKEFAKEFAKE0123456789ABCD >"$t/sandbox/notes.json"
report file_scan_flags_sk_after_a_json_newline_escape
expect file_scan FAIL 'notes.json'
fact '.leaks | length' 1
finish_case

mk file_scan_flags_sk_after_a_json_unicode_escape
state waiting
record "$R_W0"
printf '{"k":"x\\u000ask-%s"}\n' FAKEFAKEFAKEFAKEFAKE0123456789ABCD >"$t/sandbox/notes.json"
report file_scan_flags_sk_after_a_json_unicode_escape
expect file_scan FAIL 'notes.json'
finish_case

mk file_scan_ignores_sk_inside_a_word_after_an_escape_letter
state waiting
record "$R_W0"
printf '{"k":"C:\\\\temp\\\\task-manager-configuration-value-for-the-job"}\n' >"$t/sandbox/notes.json"
report file_scan_ignores_sk_inside_a_word_after_an_escape_letter
expect file_scan PASS 'no token-shaped string'
finish_case

mk file_scan_flags_a_refresh_token_that_only_starts_like_a_placeholder
state waiting
record "$R_W0"
printf '{"refresh_token":"openshell:resolve:env:A-real-secret-0123456789"}\n' >"$t/sandbox/session.json"
report file_scan_flags_a_refresh_token_that_only_starts_like_a_placeholder
expect file_scan FAIL 'session.json'
finish_case

mk auth_file_fails_when_auth_json_is_absent
state waiting
record "$R_EMPTY"
report auth_file_fails_when_auth_json_is_absent
expect auth_file FAIL 'requires auth.json'
fact '.auth_file.state' absent
fact '.auth_file.path' "$t/sandbox/.codex/auth.json"
fact '.auth_file.mode' null
finish_case

mk auth_file_fails_when_auth_json_is_a_directory
state waiting
record "$R_EMPTY"
mkdir -p "$t/sandbox/.codex/auth.json"
report auth_file_fails_when_auth_json_is_a_directory
expect auth_file FAIL 'not a regular file'
fact '.auth_file.state' malformed
fact '.auth_file.mode' null
finish_case

mk auth_file_fails_when_auth_json_is_a_dangling_symlink
state waiting
record "$R_EMPTY"
mkdir -p "$t/sandbox/.codex"
ln -s "$t/missing-target" "$t/sandbox/.codex/auth.json"
report auth_file_fails_when_auth_json_is_a_dangling_symlink
expect auth_file FAIL 'not a regular file'
finish_case

shadow_case() {
    name=$1
    tool=$2
    shift 2
    problems=
    mk "$name"
    state 'exited 1 0'
    record "$R_OK1"
    printf '#!/bin/sh\necho selected >>"%s"\nexit 91\n' "$t/$tool.selected" >"$t/bad-bin/$tool"
    chmod +x "$t/bad-bin/$tool"
    total=$((total + 1))
    prepare_probe || exit 70
    bounded 20 env -i PATH="$t/bad-bin:$scratch/shim:$scratch/tools" TMPDIR="$t/tmp" "$t/probe" "$@"
    rc=$?
    cp "$scratch/bounded.out" "$t/out"
    cp "$scratch/bounded.err" "$t/err"
    [ "$rc" -eq 0 ] || problems=" rc=$rc"
    jq -e '.schema == 3 and .mode == "sandbox" and (.steps | keys) == ["J08"] and ([.steps.J08.checks[] | select(.name == "environment")] | length) == 1 and ([.steps.J08.checks[] | select(.name == "environment")][0].result == "PASS") and .steps.J08.facts.start_record.state == "read"' "$t/out" >/dev/null 2>&1 || problems="$problems report-shape-or-result"
    [ ! -e "$t/$tool.selected" ] || problems="$problems inherited-$tool-selected"
    finish_case
}

shadow_case direct_sh_shadow sh --only J08
shadow_case sandbox_jq_shadow jq --only J08
shadow_case sandbox_tr_shadow tr --only J08

mk sandbox_path_positive_control
name=sandbox_path_positive_control
state 'exited 1 0'
record "$R_OK1"
total=$((total + 1))
problems=
prepare_probe || exit 70
bounded 20 env -i PATH="$scratch/shim:$scratch/tools" TMPDIR="$t/tmp" "$t/probe" --only J08
rc=$?
cp "$scratch/bounded.out" "$t/out"
cp "$scratch/bounded.err" "$t/err"
[ "$rc" -eq 0 ] || problems=" rc=$rc"
jq -e '.schema == 3 and .mode == "sandbox" and (.steps | keys) == ["J08"] and ([.steps.J08.checks[] | select(.name == "environment")] | length) == 1 and ([.steps.J08.checks[] | select(.name == "environment")][0].result == "PASS") and .steps.J08.facts.start_record.state == "read"' "$t/out" >/dev/null 2>&1 || problems="$problems report-shape-or-result"
finish_case

mk host_tools_outside_sandbox_path
name=host_tools_outside_sandbox_path
mkdir -p "$t/host-tools"
for tool in jq sh tr mktemp rm cat; do
    ln -s "$scratch/tools/$tool" "$t/host-tools/$tool"
done
total=$((total + 1))
problems=
prepare_probe "$t/absent-sandbox-tools" || exit 70
[ ! -e "$t/absent-sandbox-tools" ] || {
    echo "FAIL setup: absent sandbox PATH fixture exists"
    exit 70
}
bounded 20 env -i PATH="$t/host-tools" TMPDIR="$t/tmp" "$t/probe" --host --only J08
rc=$?
cp "$scratch/bounded.out" "$t/out"
cp "$scratch/bounded.err" "$t/err"
[ "$rc" -eq 0 ] || problems=" rc=$rc"
jq -e '.schema == 3 and .mode == "host" and .steps.J08.result == "SKIP" and .steps.J08.facts == null and ([.steps.J08.checks[].result] | all(. == "SKIP"))' "$t/out" >/dev/null 2>&1 || problems="$problems host-skip-null-boundary"
finish_case

mk sandbox_git_shadow
name=sandbox_git_shadow
if git_project; then
    printf '#!/bin/sh\necho selected >>"%s/git.selected"\nexit 91\n' "$t" >"$t/bad-bin/git"
    chmod +x "$t/bad-bin/git"
    total=$((total + 1))
    problems=
    prepare_probe || exit 70
    bounded 20 env -i PATH="$t/bad-bin:$scratch/shim:$scratch/tools" TMPDIR="$t/tmp" "$t/probe" --only J13
    rc=$?
    cp "$scratch/bounded.out" "$t/out"
    cp "$scratch/bounded.err" "$t/err"
    [ "$rc" -eq 0 ] || problems=" rc=$rc"
    jq -e '.schema == 3 and .mode == "sandbox" and .steps.J13.result == "PASS" and .steps.J13.facts.work_tree == true and .steps.J13.facts.clean == true' "$t/out" >/dev/null 2>&1 || problems="$problems report-shape-or-git-facts"
    [ ! -e "$t/git.selected" ] || problems="$problems inherited-git-selected"
    finish_case
else
    setup_failed sandbox_git_shadow
fi

echo "$total cases, $failures failed"
[ "$failures" -eq 0 ]
