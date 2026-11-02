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

R_OK1='jackin-env-kinds 1\nattempt 1\nmain GITHUB_TOKEN empty\nmain OPENAI_API_KEY placeholder\ncodex GITHUB_TOKEN empty\ncodex OPENAI_API_KEY placeholder\n'
R_W0='jackin-env-kinds 1\nattempt 0\nmain OPENAI_API_KEY placeholder\n'
R_NOCODEX='jackin-env-kinds 1\nattempt 1\nmain OPENAI_API_KEY placeholder\n'

mk() {
    t=$scratch/$1
    rm -rf "$t"
    mkdir -p "$t/sandbox/.jackin/run" "$t/sandbox/project" "$t/proc/sys/kernel/random" "$t/work"
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

bounded() {
    limit=$1
    shift
    "$@" >"$scratch/bounded.out" 2>&1 &
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

cat >"$scratch/driver.sh" <<'EOF'
set -u
. "$1"
work=$2
: >"$work/checks"
: >"$work/facts"
step_J08
cat "$work/checks"
cat "$work/facts"
EOF

execute() {
    sed -e "s#/sandbox#$t/sandbox#g" -e "s#/proc#$t/proc#g" -e '$d' "$probe" >"$t/probe"
    bounded 20 env -i PATH="$PATH" sh "$scratch/driver.sh" "$t/probe" "$t/work"
    rc=$?
    cp "$scratch/bounded.out" "$t/out"
    return "$rc"
}

verify() {
    total=$((total + 1))
    name=$1
    want_result=$2
    want_detail=$3
    want_record=$4
    if ! execute; then
        failures=$((failures + 1))
        echo "FAIL $name: the probe did not finish in time or failed"
        return 0
    fi
    got_result=$(jq -r 'select(.name == "environment") | .result' "$t/out" 2>/dev/null)
    got_detail=$(jq -r 'select(.name == "environment") | .detail' "$t/out" 2>/dev/null)
    got_record=$(jq -r 'select(has("start_record")) | .start_record.state' "$t/out" 2>/dev/null)
    problems=
    [ "$got_result" = "$want_result" ] || problems="$problems result=$got_result(want $want_result)"
    case $got_detail in
        *"$want_detail"*) ;;
        *) problems="$problems detail=[$got_detail](want [$want_detail])" ;;
    esac
    [ "$got_record" = "$want_record" ] || problems="$problems record=$got_record(want $want_record)"
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

mk pass_via_record
state 'exited 1 0'
record "$R_OK1"
verify pass_via_record PASS 'via record' read

mk fail_other_in_main_at_attempt_zero
state waiting
record 'jackin-env-kinds 1\nattempt 0\nmain P73_FAKE_API_KEY other\n'
verify fail_other_in_main_at_attempt_zero FAIL 'P73_FAKE_API_KEY' read

mk fail_other_in_codex
state 'exited 1 0'
record 'jackin-env-kinds 1\nattempt 1\nmain GITHUB_TOKEN empty\ncodex STRIPE_SECRET other\n'
verify fail_other_in_codex FAIL 'STRIPE_SECRET' read

mk fail_invalid_name_other
state waiting
record 'jackin-env-kinds 1\nattempt 0\nmain INVALID_NAME other\n'
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

mk skip_codex_not_yet_started
state waiting
record "$R_W0"
verify skip_codex_not_yet_started SKIP 'Codex environment is not known' read

mk skip_codex_rejected
state 'exited 1 65'
record "$R_NOCODEX"
verify skip_codex_rejected SKIP 'Codex environment is not known' read

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
record 'jackin-env-kinds 1\nattempt 1\nmain OPENAI_API_KEY other\ncodex OPENAI_API_KEY placeholder\n'
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
    printf 'jackin-env-kinds 1\nattempt 0\n'
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
    printf 'jackin-env-kinds 1\nattempt 0\n'
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
record 'jackin-env-kinds 1\nattempt 0\nmain A\0KEY other\n'
verify malformed_nul_byte FAIL 'malformed start record' malformed

for variant in \
    'bad_version|jackin-env-kinds 2\nattempt 0\n' \
    'missing_attempt|jackin-env-kinds 1\nmain OPENAI_API_KEY placeholder\n' \
    'leading_zero_attempt|jackin-env-kinds 1\nattempt 00\n' \
    'duplicate_main_name|jackin-env-kinds 1\nattempt 0\nmain A_KEY empty\nmain A_KEY empty\n' \
    'main_after_codex|jackin-env-kinds 1\nattempt 0\ncodex A_KEY empty\nmain A_KEY empty\n' \
    'escape_in_name|jackin-env-kinds 1\nattempt 0\nmain X\033]0;pwn other\n' \
    'capitalised_kind|jackin-env-kinds 1\nattempt 0\nmain A_KEY Placeholder\n' \
    'bad_name|jackin-env-kinds 1\nattempt 0\nmain 1A_KEY other\n' \
    'carriage_return|jackin-env-kinds 1\r\nattempt 0\r\n' \
    'blank_line|jackin-env-kinds 1\nattempt 0\n\n' \
    'unknown_section|jackin-env-kinds 1\nattempt 0\nextra A_KEY other\n' \
    'header_only|jackin-env-kinds 1\n'; do
    vname=${variant%%|*}
    mk "malformed_$vname"
    state waiting
    record "${variant#*|}"
    verify "malformed_$vname" FAIL 'malformed start record' malformed
done

total=$((total + 1))
mk name_rule
corpus_yes='OPENAI_API_KEY KEY MY_KEY_2 AUTH PASSWORD CREDENTIAL CREDENTIALS X_TOKEN DB_PASSWD A_SECRET_B'
corpus_no='KEYBOARD TOKENIZER OAUTH_X SSH_AUTH_SOCK openai_api_key'
for corpus_name in $corpus_yes $corpus_no; do
    printf '%s=v\n' "$corpus_name"
done >"$t/names.env"
sed -e "s#/sandbox#$t/sandbox#g" -e "s#/proc#$t/proc#g" -e '$d' "$probe" >"$t/probe"
matched=$(env -i PATH="$PATH" sh -c ". \"\$1\"; credential_variables x <\"\$2\"" sh "$t/probe" "$t/names.env" | cut -f1 | sort | tr '\n' ' ')
wanted=$(echo "$corpus_yes" | tr ' ' '\n' | sort | tr '\n' ' ')
if [ "$matched" = "$wanted" ]; then
    echo "ok   name_rule"
else
    failures=$((failures + 1))
    echo "FAIL name_rule: got [$matched] want [$wanted]"
fi

echo "$total cases, $failures failed"
[ "$failures" -eq 0 ]
