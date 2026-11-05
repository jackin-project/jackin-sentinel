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
    sed -e "s#/sandbox#$t/sandbox#g" -e "s#/proc/#$t/proc/#g" "$probe" >"$t/probe"
    if [ -f "$t/seams.sed" ]; then
        sed -f "$t/seams.sed" "$t/probe" >"$t/probe.seamed" && mv "$t/probe.seamed" "$t/probe"
    fi
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

mk j10_a_refusal_in_a_directory_the_mode_allows_is_attributed_to_the_policy
mkdir "$t/denied_policy"
j10_seams "$t/denied_policy"
cat >"$t/occupy_then_probe.sh" <<'WRAP'
: >"$1/jackin-sentinel-j10-$$"
exec sh "$2" --only J10
WRAP
begin j10_a_refusal_in_a_directory_the_mode_allows_is_attributed_to_the_policy \
    sh "$t/occupy_then_probe.sh" "$t/denied_policy" "$t/probe"
expect_rc 0
expect_report J10 sandbox
expect denied_writes PASS 'no file could be created'
expect denial_by_policy PASS 'denied_policy'
fact '[.writes[] | select(.expected == "denied") | .dac_writable] | map(tostring) | join(",")' true
j10_stays_inside
finish_case

proc_codex_child() {
    mkdir -p "$t/proc/$1"
    printf 'codex\0--sandbox\0' >"$t/proc/$1/cmdline"
    printf '%s (codex) S 100 100 100 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "$1" "$1" >"$t/proc/$1/stat"
}

processes() {
    begin "$1" sh "$t/probe" --only "$2"
    expect_rc 0
    expect_report "$2" sandbox
}

mk j11_one_codex_child_in_a_running_state_passes
state 'running 1'
proc_main
proc_codex
processes j11_one_codex_child_in_a_running_state_passes J11
expect codex_child PASS 'as a child of the main process'
finish_case

mk j11_a_state_that_is_not_running_skips_the_codex_child_check
state waiting
proc_main
processes j11_a_state_that_is_not_running_skips_the_codex_child_check J11
expect codex_child SKIP 'not running'
finish_case

for variant in 'running-bad' 'running' 'running ' 'running 0' 'running 01' 'running x' 'running -1'; do
    case_name=j11_the_state_$(printf '%s' "$variant" | tr -c 'A-Za-z0-9' _)_is_not_a_pass
    mk "$case_name"
    state "$variant"
    proc_main
    proc_codex
    processes "$case_name" J11
    expect codex_child FAIL 'not a valid running state'
    finish_case
done

mk j07_a_malformed_running_state_is_not_a_pass
state running-bad
proc_main
proc_codex
processes j07_a_malformed_running_state_is_not_a_pass J07
expect codex_child FAIL 'not a valid running state'
finish_case

mk j11_two_codex_children_are_not_a_pass
state 'running 1'
proc_main
proc_codex
proc_codex_child 102
processes j11_two_codex_children_are_not_a_pass J11
expect codex_child FAIL '2 Codex processes'
finish_case

mk j08_a_second_codex_child_with_a_real_credential_is_not_a_pass
state 'exited 1 0'
proc_main
proc_codex
proc_codex_child 102
environ 101 'OPENAI_API_KEY=openshell:resolve:env:OPENAI_API_KEY'
environ 102 'OPENAI_API_KEY=sk-real-value-0123456789abcdef'
record "$R_OK1"
verify j08_a_second_codex_child_with_a_real_credential_is_not_a_pass FAIL '2 Codex processes' read

sudo_shim() {
    mkdir -p "$t/bin"
    printf '#!/bin/sh\ncase "$*" in\n    "-n true") exit %s ;;\n    "-n -l") echo "    (root) NOPASSWD: /bin/sh"; exit %s ;;\nesac\nexit 1\n' "$1" "$2" >"$t/bin/sudo"
    chmod +x "$t/bin/sudo"
}

mk j04_a_passwordless_grant_other_than_true_fails_the_sudo_check
sudo_shim 1 0
begin j04_a_passwordless_grant_other_than_true_fails_the_sudo_check env PATH="$t/bin:$scratch/shim:$PATH" sh "$t/probe" --only J04
expect_rc 0
expect_report J04 sandbox
expect sudo FAIL 'sudo works'
fact '.sudo.works' true
finish_case

mk j04_a_passwordless_true_fails_the_sudo_check
sudo_shim 0 1
begin j04_a_passwordless_true_fails_the_sudo_check env PATH="$t/bin:$scratch/shim:$PATH" sh "$t/probe" --only J04
expect_rc 0
expect_report J04 sandbox
expect sudo FAIL 'sudo works'
fact '.sudo.works' true
finish_case

mk j04_a_sudo_without_a_passwordless_grant_passes_the_sudo_check
sudo_shim 1 1
begin j04_a_sudo_without_a_passwordless_grant_passes_the_sudo_check env PATH="$t/bin:$scratch/shim:$PATH" sh "$t/probe" --only J04
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
    begin j06_a_hook_tree_without_a_writable_ancestor_is_immutable sh "$t/probe" --only J06
    chmod 755 "$t/hookroot/lib/hooks" "$t/hookroot/lib" "$t/hookroot"
    expect_rc 0
    expect_report J06 sandbox
    hook_writable false,false
    finish_case
else
    echo "skip j06 ancestor cases: running as root"
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

jwt_flagged file_scan_flags_a_subless_jwt_of_another_issuer "$JWT_HEADER" "$(b64url '{"aud":["chatgpt.com"],"exp":1,"iss":"other-service"}')"
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

mk file_scan_skips_when_the_jwt_classifier_fails
state waiting
record "$R_W0"
mkdir "$t/bin"
exit_shim jq '*base64d*' 5
printf 'head\0Set-Cookie: __oailb=%s.%s.%s; Path=/\0tail\n' "$JWT_HEADER" "$JWT_NO_SUB" "$JWT_SIGNATURE" >"$t/sandbox/logs.sqlite"
begin file_scan_skips_when_the_jwt_classifier_fails env PATH="$t/bin:$scratch/shim:$PATH" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect file_scan SKIP 'not scanned'
finish_case

mk file_scan_accepts_a_placeholder_id_token
state waiting
record "$R_W0"
auth_json "{\"tokens\":{\"access_token\":\"$PLACEHOLDER_ACCESS\",\"refresh_token\":\"$PLACEHOLDER_REFRESH\",\"id_token\":\"$JWT_HEADER.$JWT_WITH_SUB.placeholder\"}}"
report file_scan_accepts_a_placeholder_id_token
expect auth_file PASS 'only placeholders'
expect file_scan PASS 'no token-shaped string'
fact '.leaks | length' 0
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
mkdir "$t/bin"
exit_shim grep '*bad.dat' 2
printf 'plain\n' >"$t/sandbox/bad.dat"
begin file_scan_skips_when_grep_fails env PATH="$t/bin:$scratch/shim:$PATH" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect file_scan SKIP 'bad.dat'
finish_case

mk file_scan_flags_a_token_next_to_a_failed_grep
state waiting
record "$R_W0"
mkdir "$t/bin"
exit_shim grep '*bad.dat' 2
printf 'plain\n' >"$t/sandbox/bad.dat"
printf 'sk-%s\n' abcdefghijklmnopqrstuvwxyz >"$t/sandbox/secret.txt"
begin file_scan_flags_a_token_next_to_a_failed_grep env PATH="$t/bin:$scratch/shim:$PATH" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect file_scan FAIL 'secret.txt'
finish_case

mk file_scan_skip_keeps_its_reason_before_a_long_path
state waiting
record "$R_W0"
mkdir "$t/bin"
exit_shim grep '*bad.dat' 2
long=$(printf 'd%.0s' $(seq 1 120))
mkdir -p "$t/sandbox/$long/$long"
printf 'plain\n' >"$t/sandbox/$long/$long/bad.dat"
begin file_scan_skip_keeps_its_reason_before_a_long_path env PATH="$t/bin:$scratch/shim:$PATH" sh "$t/probe" --only J08
expect_rc 0
expect_report J08 sandbox
expect file_scan SKIP '(grep failed)'
finish_case

mk file_scan_skips_when_grep_times_out
state waiting
record "$R_W0"
mkdir "$t/bin"
exit_shim timeout '*slow.dat' 124
printf 'plain\n' >"$t/sandbox/slow.dat"
begin file_scan_skips_when_grep_times_out env PATH="$t/bin:$scratch/shim:$PATH" sh "$t/probe" --only J08
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
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$t/sandbox/project" "$@"
}

git_project() {
    git_in_project init -q &&
        git_in_project -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m init
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
finish_case

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
    mkdir "$t/bin"
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
    begin j05_a_file_that_cannot_be_hashed_fails_the_files_check env PATH="$t/bin:$scratch/shim:$PATH" sh "$t/probe" --only J05
    expect_rc 0
    expect_report J05 sandbox
    expect files FAIL 'unreadable.txt: Permission denied'
    finish_case
else
    setup_failed j05_a_file_that_cannot_be_hashed_fails_the_files_check
fi

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

codex_prints() {
    mkdir -p "$t/bin"
    printf '#!/bin/sh\nprintf "%%s" "%s"\nexit %s\n' "$1" "$2" >"$t/bin/codex"
    chmod +x "$t/bin/codex"
    seam CODEX_BIN "$t/bin/codex"
}

mk j00_a_silent_codex_version_is_not_a_pass
codex_prints '' 0
begin j00_a_silent_codex_version_is_not_a_pass sh "$t/probe" --only J00
expect_rc 0
expect_report J00 sandbox
expect codex_version FAIL 'printed nothing'
fact '.codex.version' null
finish_case

mk j00_a_printed_codex_version_passes
codex_prints 'codex-cli 9.9.9' 0
begin j00_a_printed_codex_version_passes sh "$t/probe" --only J00
expect_rc 0
expect_report J00 sandbox
expect codex_version PASS 'codex-cli 9.9.9'
fact '.codex.version' 'codex-cli 9.9.9'
finish_case

mk j00_a_failing_codex_version_fails
codex_prints 'codex-cli 9.9.9' 3
begin j00_a_failing_codex_version_fails sh "$t/probe" --only J00
expect_rc 0
expect_report J00 sandbox
expect codex_version FAIL 'failed'
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

mk auth_file_skips_when_auth_json_is_absent
state waiting
record "$R_EMPTY"
report auth_file_skips_when_auth_json_is_absent
expect auth_file SKIP 'no auth.json'
fact '.auth_file' null
finish_case

mk auth_file_fails_when_auth_json_is_a_directory
state waiting
record "$R_EMPTY"
mkdir -p "$t/sandbox/.codex/auth.json"
report auth_file_fails_when_auth_json_is_a_directory
expect auth_file FAIL 'not a regular file'
fact '.auth_file' null
finish_case

mk auth_file_fails_when_auth_json_is_a_dangling_symlink
state waiting
record "$R_EMPTY"
mkdir -p "$t/sandbox/.codex"
ln -s "$t/missing-target" "$t/sandbox/.codex/auth.json"
report auth_file_fails_when_auth_json_is_a_dangling_symlink
expect auth_file FAIL 'not a regular file'
finish_case

echo "$total cases, $failures failed"
[ "$failures" -eq 0 ]
