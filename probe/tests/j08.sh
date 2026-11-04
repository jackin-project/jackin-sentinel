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
R_EMPTY='jackin-env-kinds 1\nattempt 0\nmain GITHUB_TOKEN empty\n'
R_NOCODEX='jackin-env-kinds 1\nattempt 1\nmain OPENAI_API_KEY placeholder\n'

mk() {
    t=$scratch/$1
    rm -rf "$t"
    mkdir -p "$t/sandbox/.jackin/run" "$t/sandbox/project" "$t/proc/sys/kernel/random" "$t/tmp"
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

mkdir "$scratch/shim"
real_id=$(command -v id) || exit 70
printf '#!/bin/sh\necho Linux\n' >"$scratch/shim/uname"
printf '#!/bin/sh\n[ "$*" = -un ] && echo sandbox && exit 0\nexec %s "$@"\n' "$real_id" >"$scratch/shim/id"
chmod +x "$scratch/shim/uname" "$scratch/shim/id"

begin() {
    total=$((total + 1))
    name=$1
    shift
    problems=
    sed -e "s#/sandbox#$t/sandbox#g" -e "s#/proc#$t/proc#g" "$probe" >"$t/probe"
    bounded 20 env -i PATH="$scratch/shim:$PATH" TMPDIR="$t/tmp" "$@"
    rc=$?
    cp "$scratch/bounded.out" "$t/out"
    cp "$scratch/bounded.err" "$t/err"
}

expect_rc() {
    [ "$rc" -eq "$1" ] || problems="$problems rc=$rc(want $1)"
}

expect_report() {
    jq -e --arg step "$1" --arg mode "$2" \
        '.schema == 1 and .probe == "jackin-sentinel-probe" and .mode == $mode and (.steps | keys) == [$step]' "$t/out" >/dev/null 2>&1 ||
        problems="$problems report-shape"
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

PLACEHOLDER_ACCESS=openshell:resolve:env:CODEX_AUTH_ACCESS_TOKEN
PLACEHOLDER_REFRESH=openshell:resolve:env:CODEX_AUTH_REFRESH_TOKEN

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

if [ "$(id -u)" -ne 0 ]; then
    mk j10_state_dir_cannot_be_created
    chmod 555 "$t/sandbox"
    begin j10_state_dir_cannot_be_created sh "$t/probe" --only J10
    chmod 755 "$t/sandbox"
    expect_rc 0
    expect_report J10 sandbox
    expect allowed_writes FAIL '.sentinel'
    finish_case
else
    echo "skip j10_state_dir_cannot_be_created: running as root"
fi

mk j10_state_dir_is_created
begin j10_state_dir_is_created sh "$t/probe" --only J10
expect_rc 0
expect_report J10 sandbox
expect allowed_writes PASS '.sentinel'
finish_case

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

git_project() {
    git -C "$t/sandbox/project" init -q
    git -C "$t/sandbox/project" -c core.hooksPath=/dev/null -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m init
}

mk j13_clean_work_tree
git_project
begin j13_clean_work_tree sh "$t/probe" --only J13
expect_rc 0
expect_report J13 sandbox
expect work_tree_status PASS 'git status ran'
fact '.clean' true
finish_case

mk j13_unreadable_index_is_not_a_clean_work_tree
git_project
printf 'garbage' >"$t/sandbox/project/.git/index"
begin j13_unreadable_index_is_not_a_clean_work_tree sh "$t/probe" --only J13
expect_rc 0
expect_report J13 sandbox
expect work_tree_status FAIL 'cleanliness of the work tree is unknown'
fact '.clean' false
finish_case

mk j15_runs_the_hello_world_image_by_digest
mkdir "$t/bin"
cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
case "$*" in
    "run --rm hello-world@sha256:"*) echo "Hello from Docker!" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$t/bin/docker"
begin j15_runs_the_hello_world_image_by_digest env PATH="$t/bin:$scratch/shim:$PATH" sh "$t/probe" --only J15 --docker on
expect_rc 0
expect_report J15 sandbox
expect hello_world PASS '@sha256:'
fact '.run.hello' true
finish_case

mk name_rule
corpus_yes='OPENAI_API_KEY KEY MY_KEY_2 AUTH PASSWORD CREDENTIAL CREDENTIALS X_TOKEN DB_PASSWD A_SECRET_B'
corpus_no='KEYBOARD TOKENIZER OAUTH_X SSH_AUTH_SOCK openai_api_key'
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

echo "$total cases, $failures failed"
[ "$failures" -eq 0 ]
