#!/bin/sh
# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0
set -u

here=$(cd "$(dirname "$0")" && pwd)
probe=$here/../jackin-sentinel-probe
scratch=$(mktemp -d) || exit 70
scratch=$(cd "$scratch" && pwd -P) || exit 70
trap 'rm -rf "$scratch"' EXIT
failures=0
total=0
mkdir "$scratch/tools"
for tool in sh base64 jq sed tr cat env awk grep mktemp rm wc head od mkdir cp; do
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
jq() {
    "$scratch/tools/jq" "$@"
}
real_id=$(command -v id) || exit 70
real_env=$(command -v env) || exit 70
printf '#!/bin/sh\necho Linux\n' >"$scratch/tools/uname"
printf '#!/bin/sh\n[ "$*" = -un ] && echo sandbox && exit 0\nexec %s "$@"\n' "$real_id" >"$scratch/tools/id"
printf '#!/bin/sh\ncase %s in --kill-after=*) shift ;; esac\nshift\nexec "%s"\n' "\${1-}" "\$@" >"$scratch/tools/timeout"
chmod +x "$scratch/tools/uname" "$scratch/tools/id" "$scratch/tools/timeout"
if PATH="$scratch/tools" command -v curl >/dev/null 2>&1; then
    echo "FAIL setup: the tool directory reaches a real curl"
    exit 70
fi

cat >"$scratch/stub-curl" <<'EOF'
#!/bin/sh
for last; do :; done
out=
header=
noproxy=
prev=
for arg; do
    [ "$prev" = -o ] && out=$arg
    [ "$prev" = -H ] && header=${arg#@}
    [ "$prev" = --noproxy ] && noproxy=$arg
    prev=$arg
done
if [ "${1-}" != -q ] && [ -f "${CURL_HOME:-${HOME-}}/.curlrc" ]; then
    printf '000'
    exit 7
fi
if [ "$noproxy" != '*' ] && [ -n "${http_proxy-}${https_proxy-}${all_proxy-}${HTTP_PROXY-}${HTTPS_PROXY-}${ALL_PROXY-}" ]; then
    printf '000'
    exit 7
fi
{
    echo "curl $last"
    [ -z "$header" ] || cat "$header"
} >>"$STUB_LOG"
while read -r url rc code body; do
    if [ "$url" = "$last" ]; then
        [ -z "$body" ] || [ -z "$out" ] || cat "$body" >"$out"
        printf '%s' "$code"
        exit "$rc"
    fi
done <"$STUB_TABLE"
printf '000'
exit 99
EOF
chmod +x "$scratch/stub-curl"

mk() {
    t=$scratch/$1
    rm -rf "$t"
    mkdir -p "$t/bin" "$t/bad-bin" "$t/home" "$t/sandbox" "$t/tmp"
    : >"$t/table"
    : >"$t/curl.log"
    pathvar=$t/bad-bin:$t/bin:$scratch/tools
}

prepare_probe() {
    fixture_path=$t/bin:$scratch/tools
    sed -e "s#/sandbox#$t/sandbox#g" -e "s#^AGENT_BIN=.*#AGENT_BIN=$t/bin/codex#" "$probe" >"$t/probe.impl"
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

codex_says() {
    printf '#!/bin/sh\necho ran >>"%s"\necho "%s"\nexit %s\n' "$t/codex.ran" "$1" "$2" >"$t/bin/codex"
    chmod +x "$t/bin/codex"
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

codex_streams() {
    fixture_kind=$1
    fixture_exit=$2
    cat >"$scratch/codex-output.py" <<'PY'
import sys

cases = {
    "ready_after_cap": (65541, 65536, b"ready"),
    "large": (4194304, 257, b"ready"),
}
payloads = {
    "below_cap": b"ready\n",
    "exact_cap": b"",
    "cap_plus_one_before": b"",
    "exact": b"ready",
    "space": b" ready ",
    "tab": b"\tready\t",
    "lf": b"\nready\n",
    "cr": b"\rready\r",
    "vt": b"\vready\v",
    "ff": b"\fready\f",
    "prompt_echo": b"Reply with the word ready",
    "already": b"already",
    "status": b"status: ready",
    "second_before": b"ready now",
    "second_after": b"now ready",
    "uppercase": b"READY",
    "mixed_case": b"ReAdY",
    "empty": b"",
    "whitespace_only": b" \t\n\r\v\f",
    "nul_before": b"\0ready",
    "nul_inside": b"r\0eady",
    "nul_after": b"ready\0",
    "nul_around": b"\0ready\0",
    "non_ascii": b"ready\xc3\xa9",
    "nonzero": b"ready",
}
kind = sys.argv[1]
if kind in payloads:
    payload = payloads[kind]
    if kind == "exact_cap":
        payload = b" " * 32765 + b"ready" + b" " * 32766
        assert len(payload) == 65536 and payload[32765:32770] == b"ready"
    elif kind == "cap_plus_one_before":
        payload = b" " * 32766 + b"ready" + b" " * 32766
        assert len(payload) == 65537 and payload[32766:32771] == b"ready"
    sys.stdout.buffer.write(payload)
    written = len(payload)
else:
    length, position, marker = cases[kind]
    assert 0 <= position <= length - len(marker)
    chunk_size = 4096
    pattern = b"OUT-RAW-SECRET-MARKER-"
    written = 0
    while written < length:
        size = min(chunk_size, length - written)
        chunk = (pattern * ((size + len(pattern) - 1) // len(pattern)))[:size]
        start = written
        end = start + size
        marker_start = max(start, position)
        marker_end = min(end, position + len(marker))
        if marker_start < marker_end:
            left = marker_start - start
            right = marker_end - start
            marker_left = marker_start - position
            marker_right = marker_end - position
            chunk = chunk[:left] + marker[marker_left:marker_right] + chunk[right:]
        sys.stdout.buffer.write(chunk)
        written += size
    assert written == length
    if kind == "ready_after_cap":
        assert length == 65541 and position == 65536
    elif kind == "large":
        assert length == 4194304 and position == 257
raise SystemExit(int(sys.argv[2]))
PY
    python_arg=$(shell_quote "$python_bin")
    generator_arg=$(shell_quote "$scratch/codex-output.py")
    kind_arg=$(shell_quote "$fixture_kind")
    exit_arg=$(shell_quote "$fixture_exit")
    ran_arg=$(shell_quote "$t/codex.ran")
    printf '#!/bin/sh\necho ran >>%s\nexec %s %s %s %s\n' \
        "$ran_arg" "$python_arg" "$generator_arg" "$kind_arg" "$exit_arg" >"$t/bin/codex"
    chmod +x "$t/bin/codex"
}

codex_stream_case() {
    selected_step=$1
    fixture_kind=$2
    expected_result=$3
    expected_exit=$4
    expected_bytes=$5
    if [ "$selected_step" = J07 ]; then
        step_name=j07
        check_name=agent_exec
    else
        step_name=j09
        check_name=agent_reaches_api
        with_curl
        answer "$OUTSIDE" 7 000
        answer "$METADATA" 7 000
        answer "$PROVIDER" 7 000
    fi
    case_name="${step_name}_codex_stdout_${fixture_kind}"
    begin "$case_name" "step_$selected_step" '' OPENAI_API_KEY="$API_PLACEHOLDER"
    expect "$check_name" "$expected_result" "$(if [ "$expected_result" = PASS ]; then printf 'codex exec answered'; else printf 'gave no answer'; fi)"
    if [ -n "$expected_exit" ]; then
        fact '.agent_exec | "\(.attempted) \(.credential) \(.exit_code) \(.answered) \(.output_bytes)"' "true api_key $expected_exit $([ "$expected_result" = PASS ] && printf true || printf false) $expected_bytes"
    else
        fact '.agent_exec | "\(.attempted) \(.credential) \(.answered) \(.output_bytes)"' "true api_key false $expected_bytes"
    fi
    expect_absent_from_report OUT-RAW-SECRET-MARKER
    finish_case
}

setup_codex_stream_case() {
    selected_step=$1
    fixture_kind=$2
    fixture_exit=${3-0}
    if [ "$selected_step" = J07 ]; then
        step_name=j07
    else
        step_name=j09
    fi
    mk "${step_name}_codex_stdout_${fixture_kind}"
    codex_streams "$fixture_kind" "$fixture_exit"
}

auth_json() {
    mkdir -p "$t/sandbox/.codex"
    printf '%s\n' "$1" >"$t/sandbox/.codex/auth.json"
}

with_curl() {
    cp "$scratch/stub-curl" "$t/bin/curl"
}

answer() {
    printf '%s %s %s %s\n' "$1" "$2" "$3" "${4-}" >>"$t/table"
}

provider_body() {
    printf '%s\n' "$1" >"$t/body"
    echo "$t/body"
}

openai_error() {
    provider_body "{\"error\": {\"message\": \"Incorrect API key provided: $1. You can find your API key at https://platform.openai.com/account/api-keys.\", \"type\": \"invalid_request_error\", \"param\": null, \"code\": \"$2\"}}"
}

openai_401() {
    openai_error "$1" invalid_api_key
}

expect_never_sent() {
    if grep -q -e "$1" "$t/curl.log"; then
        problems="$problems sent[$1]"
    fi
}

expect_sent() {
    grep -q -e "$1" "$t/curl.log" || problems="$problems not-sent[$1]"
}

expect_absent_from_report() {
    if grep -q -e "$1" "$t/out"; then
        problems="$problems reported[$1]"
    fi
}

expect_codex_not_run() {
    [ ! -e "$t/codex.ran" ] || problems="$problems codex-ran"
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

execute() {
    step=$1
    engine=${2-}
    shift 2
    fixture_setup_failed=0
    prepare_probe || {
        fixture_setup_failed=1
        return 70
    }
    set -- "$@" sh "$t/probe" --only "${step#step_}"
    [ -z "$engine" ] || set -- "$@" --engine "$engine"
    bounded 20 env -i HOME="$t/home" PATH="$pathvar" TMPDIR="$t/tmp" STUB_TABLE="$t/table" STUB_LOG="$t/curl.log" "$@"
    rc=$?
    cp "$scratch/bounded.out" "$t/out"
    cp "$scratch/bounded.err" "$t/err"
    return "$rc"
}

begin() {
    total=$((total + 1))
    name=$1
    shift
    problems=
    if ! execute "$@"; then
        if [ "$fixture_setup_failed" -eq 1 ]; then
            problems=" setup failure: sandbox path fixture substitution failed"
        else
            problems=" the probe did not finish in time or failed"
        fi
    elif ! jq -e --arg step "${1#step_}" '.schema == 3 and .mode == "sandbox" and (.steps | keys) == [$step]' "$t/out" >/dev/null 2>&1; then
        problems=" report-shape"
    fi
}

begin_without_probe_env() {
    rm "$scratch/tools/env"
    begin "$@"
    result=$?
    ln -s "$real_env" "$scratch/tools/env"
    return "$result"
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

OUTSIDE=https://example.com
METADATA=http://169.254.169.254/latest/meta-data/
PROVIDER=https://chatgpt.com/backend-api/models
ENGINE=host.openshell.internal:2376
PING=https://$ENGINE/_ping
PLACEHOLDER=openshell:resolve:env:CODEX_AUTH_ACCESS_TOKEN
PLACEHOLDER_SHOWN='openshel*********************************OKEN'
API_PLACEHOLDER=openshell:resolve:env:OPENAI_API_KEY
API_PLACEHOLDER_SHOWN='openshel************************_KEY'
python_bin=$(command -v python3) || exit 70
case "$python_bin" in
    /*) ;;
    *)
        python_dir=${python_bin%/*}
        python_name=${python_bin##*/}
        [ "$python_dir" != "$python_bin" ] || python_dir=.
        python_dir=$(cd "$python_dir" && pwd -P) || exit 70
        python_bin=$python_dir/$python_name
        ;;
esac
INJECTED="$PLACEHOLDER
X-Exfil: FAKE-REAL-SECRET-0123456789"
INJECTED_JSON='openshell:resolve:env:CODEX_AUTH_ACCESS_TOKEN\nX-Exfil: FAKE-REAL-SECRET-0123456789'

mk j09_policy_denial
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
begin j09_policy_denial step_J09 ''
expect outside_host_denied PASS 'refused the connection (curl exit 7'
expect metadata_denied PASS 'refused the connection (curl exit 7'
fact '.outside_host | "\(.curl_found) \(.curl_exit) \(.http_code)"' 'true 7 0'
fact '.metadata_host | "\(.curl_found) \(.curl_exit) \(.http_code)"' 'true 7 0'
finish_case

mk j09_a_curlrc_of_the_sandbox_user_cannot_turn_an_allowed_host_into_a_denial
with_curl
printf 'connect-to = "::127.0.0.1:9"\n' >"$t/sandbox/.curlrc"
answer "$OUTSIDE" 0 200
answer "$METADATA" 0 200
begin j09_a_curlrc_of_the_sandbox_user_cannot_turn_an_allowed_host_into_a_denial step_J09 '' CURL_HOME="$t/sandbox"
expect outside_host_denied FAIL 'answered HTTP 200'
expect metadata_denied FAIL 'answered HTTP 200'
fact '.outside_host | "\(.curl_exit) \(.http_code)"' '0 200'
finish_case

for proxy in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
    proxy_case=j09_${proxy}_presence_fails
    mk "$proxy_case"
    with_curl
    answer "$OUTSIDE" 7 000
    answer "$METADATA" 7 000
    begin "$proxy_case" step_J09 '' "$proxy="
    expect outside_host_denied FAIL 'proxy variables are set'
    expect metadata_denied FAIL 'proxy variables are set'
    finish_case
done

mk j09_dns_failure_is_not_a_denial
with_curl
answer "$OUTSIDE" 6 000
answer "$METADATA" 6 000
begin j09_dns_failure_is_not_a_denial step_J09 ''
expect outside_host_denied FAIL 'did not resolve (curl exit 6)'
expect metadata_denied FAIL 'did not resolve (curl exit 6)'
fact '.outside_host | "\(.curl_found) \(.curl_exit) \(.http_code)"' 'true 6 0'
finish_case

mk j09_curl_missing
begin j09_curl_missing step_J09 ''
expect outside_host_denied FAIL 'curl is not installed'
expect metadata_denied FAIL 'curl is not installed'
fact '.outside_host | "\(.curl_found) \(.curl_exit) \(.http_code)"' 'false null 0'
finish_case

mk j09_proxy_403_is_not_a_connection_denial
with_curl
answer "$OUTSIDE" 0 403
answer "$METADATA" 0 200
begin j09_proxy_403_is_not_a_connection_denial step_J09 ''
expect outside_host_denied FAIL 'answered HTTP 403'
expect metadata_denied FAIL 'answered HTTP 200'
finish_case

mk j09_timeout_is_not_a_denial
with_curl
answer "$OUTSIDE" 28 000
answer "$METADATA" 7 000
begin j09_timeout_is_not_a_denial step_J09 ''
expect outside_host_denied FAIL 'curl exit 28'
expect metadata_denied PASS 'refused the connection'
finish_case

mk j09_provider_refused
with_curl
codex_says 'ready' 0
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_provider_refused step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect agent_reaches_api PASS 'codex exec answered'
expect provider_no_credential PASS 'refused the connection'
expect_sent "Authorization: Bearer $PLACEHOLDER"
finish_case

mk j09_provider_timeout_is_not_proof
with_curl
codex_says 'ready' 0
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 28 000
begin j09_provider_timeout_is_not_proof step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect provider_no_credential FAIL 'gave no HTTP response'
finish_case

mk j09_provider_unresolved_is_not_proof
with_curl
codex_says 'ready' 0
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 6 000
begin j09_provider_unresolved_is_not_proof step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect provider_no_credential FAIL 'gave no HTTP response'
finish_case

mk j09_provider_401_that_shows_only_the_placeholder_passes
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 0 401 "$(openai_401 "$PLACEHOLDER_SHOWN")"
begin j09_provider_401_that_shows_only_the_placeholder_passes step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect provider_no_credential PASS 'no credential was applied'
expect_sent "Authorization: Bearer $PLACEHOLDER"
finish_case

mk j09_provider_401_that_echoes_the_literal_placeholder_passes
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 0 401 "$(openai_401 "$PLACEHOLDER")"
begin j09_provider_401_that_echoes_the_literal_placeholder_passes step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect provider_no_credential PASS 'no credential was applied'
finish_case

mk j09_provider_401_for_another_key_fails
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 0 401 "$(openai_401 'sk-proj-***********************wxyz')"
begin j09_provider_401_for_another_key_fails step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect provider_no_credential FAIL 'may have seen another credential'
expect_absent_from_report 'sk-proj'
finish_case

mk j09_provider_401_for_the_placeholder_of_another_variable_fails
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 0 401 "$(openai_401 "$API_PLACEHOLDER_SHOWN")"
begin j09_provider_401_for_the_placeholder_of_another_variable_fails step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect provider_no_credential FAIL 'may have seen another credential'
finish_case

mk j09_provider_401_without_the_invalid_key_code_fails
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 0 401 "$(provider_body '{"error": {"message": "Incorrect API key provided: '"$PLACEHOLDER_SHOWN"'. FAKE-BODY-MARKER", "code": "other"}}')"
begin j09_provider_401_without_the_invalid_key_code_fails step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect provider_no_credential FAIL 'may have seen another credential'
expect_absent_from_report FAKE-BODY-MARKER
finish_case

mk j09_provider_401_with_an_unparsable_body_fails
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 0 401 "$(provider_body 'Unauthorized FAKE-BODY-MARKER')"
begin j09_provider_401_with_an_unparsable_body_fails step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect provider_no_credential FAIL 'may have seen another credential'
expect_absent_from_report FAKE-BODY-MARKER
finish_case

mk j09_provider_401_with_an_empty_body_fails
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 0 401
begin j09_provider_401_with_an_empty_body_fails step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect provider_no_credential FAIL 'may have seen another credential'
finish_case

mk j09_provider_401_with_the_invalid_key_code_is_classified_invalid_api_key
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 0 401 "$(openai_401 "$PLACEHOLDER_SHOWN")"
begin j09_provider_401_with_the_invalid_key_code_is_classified_invalid_api_key step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect provider_no_credential PASS 'no credential was applied'
fact '.provider_host | "\(.http_code) \(.body)"' '401 invalid_api_key'
finish_case

for error_code in insufficient_quota invalid_api_key_expired INVALID_API_KEY; do
    mk "j09_provider_401_with_the_error_code_${error_code}_fails"
    with_curl
    answer "$OUTSIDE" 7 000
    answer "$METADATA" 7 000
    answer "$PROVIDER" 0 401 "$(openai_error "$PLACEHOLDER_SHOWN" "$error_code")"
    begin "j09_provider_401_with_the_error_code_${error_code}_fails" step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
    expect provider_no_credential FAIL 'may have seen another credential'
    fact '.provider_host | "\(.http_code) \(.body)"' '401 other'
    finish_case
done

for refusal in 403 429 500; do
    mk "j09_provider_${refusal}_is_not_proof"
    with_curl
    answer "$OUTSIDE" 7 000
    answer "$METADATA" 7 000
    answer "$PROVIDER" 0 "$refusal" "$(openai_401 "$PLACEHOLDER_SHOWN")"
    begin "j09_provider_${refusal}_is_not_proof" step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
    expect provider_no_credential FAIL "HTTP $refusal"
    finish_case
done

mk j09_provider_answers_2xx
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 0 200
begin j09_provider_answers_2xx step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect provider_no_credential FAIL 'HTTP 200'
finish_case

mk j09_provider_curl_missing
begin j09_provider_curl_missing step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect provider_no_credential FAIL 'curl is not installed'
finish_case

mk j09_codex_answers
with_curl
codex_says 'ready' 0
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_codex_answers step_J09 '' OPENAI_API_KEY="$PLACEHOLDER"
expect agent_reaches_api PASS 'codex exec answered'
fact '.agent_exec | "\(.attempted) \(.credential) \(.exit_code) \(.answered)"' 'true api_key 0 true'
finish_case

mk j09_codex_timeout_after_partial_output_is_not_an_answer
with_curl
codex_says 'ready' 124
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_codex_timeout_after_partial_output_is_not_an_answer step_J09 '' OPENAI_API_KEY="$PLACEHOLDER"
expect agent_reaches_api FAIL 'exit 124 gave no answer'
fact '.agent_exec | "\(.attempted) \(.exit_code) \(.answered)"' 'true 124 false'
finish_case

for selected_step in J07 J09; do
    setup_codex_stream_case "$selected_step" below_cap
    codex_stream_case "$selected_step" below_cap PASS 0 6
    setup_codex_stream_case "$selected_step" exact
    codex_stream_case "$selected_step" exact PASS 0 5
    for fixture_kind in space tab lf cr vt ff; do
        setup_codex_stream_case "$selected_step" "$fixture_kind"
        codex_stream_case "$selected_step" "$fixture_kind" PASS 0 7
    done
    for fixture_kind in prompt_echo already status second_before second_after uppercase mixed_case; do
        case "$fixture_kind" in
            prompt_echo) expected_bytes=25 ;;
            already) expected_bytes=7 ;;
            status) expected_bytes=13 ;;
            second_before | second_after) expected_bytes=9 ;;
            uppercase | mixed_case) expected_bytes=5 ;;
        esac
        setup_codex_stream_case "$selected_step" "$fixture_kind"
        codex_stream_case "$selected_step" "$fixture_kind" FAIL 0 "$expected_bytes"
    done
    setup_codex_stream_case "$selected_step" empty
    codex_stream_case "$selected_step" empty FAIL 0 0
    setup_codex_stream_case "$selected_step" whitespace_only
    codex_stream_case "$selected_step" whitespace_only FAIL 0 6
    for fixture_kind in nul_before nul_inside nul_after; do
        setup_codex_stream_case "$selected_step" "$fixture_kind"
        codex_stream_case "$selected_step" "$fixture_kind" FAIL 0 6
    done
    setup_codex_stream_case "$selected_step" nul_around
    codex_stream_case "$selected_step" nul_around FAIL 0 7
    setup_codex_stream_case "$selected_step" non_ascii
    codex_stream_case "$selected_step" non_ascii FAIL 0 7
    setup_codex_stream_case "$selected_step" exact_cap
    codex_stream_case "$selected_step" exact_cap PASS 0 65536
    setup_codex_stream_case "$selected_step" cap_plus_one_before
    codex_stream_case "$selected_step" cap_plus_one_before FAIL 0 65537
    setup_codex_stream_case "$selected_step" ready_after_cap
    codex_stream_case "$selected_step" ready_after_cap FAIL 0 65537
    setup_codex_stream_case "$selected_step" large
    codex_stream_case "$selected_step" large FAIL 0 65537
    setup_codex_stream_case "$selected_step" nonzero 23
    codex_stream_case "$selected_step" nonzero FAIL 23 5
done

mk j09_codex_uses_the_api_key_of_auth_json
with_curl
codex_says 'ready' 0
auth_json "{\"OPENAI_API_KEY\":\"$API_PLACEHOLDER\"}"
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_codex_uses_the_api_key_of_auth_json step_J09 ''
expect agent_reaches_api PASS 'codex exec answered'
fact '.agent_exec | "\(.attempted) \(.credential)"' 'true api_key'
finish_case

mk j09_codex_uses_the_access_token_variable
with_curl
codex_says 'ready' 0
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_codex_uses_the_access_token_variable step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect agent_reaches_api PASS 'codex exec answered'
fact '.agent_exec | "\(.attempted) \(.credential)"' 'true oauth_login'
finish_case

mk j09_an_empty_access_token_in_auth_json_does_not_hide_the_api_key
with_curl
codex_says 'ready' 0
auth_json "{\"tokens\":{\"access_token\":\"\"},\"OPENAI_API_KEY\":\"$API_PLACEHOLDER\"}"
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 0 401 "$(openai_401 "$API_PLACEHOLDER_SHOWN")"
begin j09_an_empty_access_token_in_auth_json_does_not_hide_the_api_key step_J09 ''
expect provider_no_credential PASS 'no credential was applied'
expect_sent "Authorization: Bearer $API_PLACEHOLDER"
fact '.agent_exec | "\(.attempted) \(.credential)"' 'true api_key'
finish_case

mk j09_provider_check_sends_the_placeholder_of_auth_json
with_curl
codex_says 'ready' 0
auth_json "{\"tokens\":{\"access_token\":\"$PLACEHOLDER\"}}"
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 0 200
begin j09_provider_check_sends_the_placeholder_of_auth_json step_J09 ''
expect provider_no_credential FAIL 'HTTP 200'
fact '.provider_host | "\(.curl_exit) \(.http_code)"' '0 200'
finish_case

mk j09_provider_check_passes_when_the_placeholder_of_auth_json_is_refused
with_curl
codex_says 'ready' 0
auth_json "{\"OPENAI_API_KEY\":\"$PLACEHOLDER\"}"
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 0 401 "$(openai_401 "$PLACEHOLDER_SHOWN")"
begin j09_provider_check_passes_when_the_placeholder_of_auth_json_is_refused step_J09 ''
expect provider_no_credential PASS 'no credential was applied'
finish_case

mk j09_a_real_token_in_auth_json_is_never_sent
with_curl
codex_says 'ready' 0
auth_json '{"tokens":{"access_token":"FAKE-real-token"}}'
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 0 200
begin j09_a_real_token_in_auth_json_is_never_sent step_J09 ''
expect provider_no_credential SKIP 'no placeholder to send'
expect agent_reaches_api SKIP 'not a full placeholder'
fact '.provider_host' null
fact '.agent_exec | "\(.attempted) \(.credential)"' 'false none'
expect_codex_not_run
expect_never_sent FAKE-real-token
finish_case

never_used() {
    expect provider_no_credential SKIP 'no placeholder to send'
    expect agent_reaches_api SKIP 'not a full placeholder'
    fact '.provider_host' null
    fact '.agent_exec | "\(.attempted) \(.credential)"' 'false none'
    expect_codex_not_run
    expect_never_sent X-Exfil
    expect_never_sent 'curl https://api.openai.com'
    finish_case
}

never_used_setup() {
    mk "$1"
    with_curl
    codex_says 'ready' 0
    answer "$OUTSIDE" 7 000
    answer "$METADATA" 7 000
    answer "$PROVIDER" 0 200
}

never_used_setup j09_a_newline_after_the_prefix_in_auth_json_is_never_used
auth_json "{\"tokens\":{\"access_token\":\"$INJECTED_JSON\"}}"
begin j09_a_newline_after_the_prefix_in_auth_json_is_never_used step_J09 ''
never_used

never_used_setup j09_a_newline_after_the_prefix_in_the_codex_variable_is_never_used
begin j09_a_newline_after_the_prefix_in_the_codex_variable_is_never_used step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$INJECTED"
never_used

never_used_setup j09_a_newline_after_the_prefix_in_the_api_key_variable_is_never_used
begin j09_a_newline_after_the_prefix_in_the_api_key_variable_is_never_used step_J09 '' OPENAI_API_KEY="$INJECTED"
never_used

never_used_setup j09_a_newline_after_the_prefix_in_the_api_key_of_auth_json_is_never_used
auth_json "{\"OPENAI_API_KEY\":\"$INJECTED_JSON\"}"
begin j09_a_newline_after_the_prefix_in_the_api_key_of_auth_json_is_never_used step_J09 ''
never_used

for partial in 'openshell:resolve:' 'openshell:resolve:env:' 'openshell:resolve:env:A B' 'openshell:resolve:env:1A' 'openshell:resolve:file:A' 'openshell:resolve:env:A-B'; do
    partial_index=$((${partial_index:-0} + 1))
    case_name=j09_the_partial_placeholder_${partial_index}_is_never_used
    never_used_setup "$case_name"
    begin "$case_name" step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$partial"
    never_used
done

mk j09_a_real_api_key_variable_blocks_codex_exec_next_to_a_placeholder_in_auth_json
with_curl
codex_says 'ready' 0
auth_json "{\"tokens\":{\"access_token\":\"$PLACEHOLDER\"}}"
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
begin j09_a_real_api_key_variable_blocks_codex_exec_next_to_a_placeholder_in_auth_json step_J09 '' OPENAI_API_KEY=FAKE-real-key
expect agent_reaches_api SKIP 'not a full placeholder'
expect_codex_not_run
finish_case

mk j09_a_real_refresh_token_blocks_codex_exec_next_to_a_placeholder_access_token
with_curl
codex_says 'ready' 0
auth_json "{\"tokens\":{\"access_token\":\"$PLACEHOLDER\",\"refresh_token\":\"FAKE-real-refresh\"}}"
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_a_real_refresh_token_blocks_codex_exec_next_to_a_placeholder_access_token step_J09 ''
expect agent_reaches_api SKIP 'not a full placeholder'
expect_codex_not_run
finish_case

mk j09_no_credential_skips_codex
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
begin j09_no_credential_skips_codex step_J09 ''
expect agent_reaches_api SKIP 'no credential'
fact '.agent_exec | "\(.attempted) \(.credential)"' 'false none'
finish_case

INHERITED_CREDENTIAL_VALUE=FAKE-inherited-credential-value-7d95c2

credential_case_setup() {
    mk "$1"
    codex_says 'ready' 0
    if [ "$2" = J09 ]; then
        with_curl
        answer "$OUTSIDE" 7 000
        answer "$METADATA" 7 000
        answer "$PROVIDER" 7 000
    fi
}

for selected_step in J07 J09; do
    if [ "$selected_step" = J07 ]; then
        step_name=j07
        check_name=agent_exec
    else
        step_name=j09
        check_name=agent_reaches_api
    fi
    for credential_name in KEY X_TOKEN A_SECRET_B PASSWORD DB_PASSWD CREDENTIAL CREDENTIALS AUTH github_token auth credential; do
        case_name="${step_name}_inherited_${credential_name}_nonplaceholder_skips_codex"
        credential_case_setup "$case_name" "$selected_step"
        begin "$case_name" "step_$selected_step" '' OPENAI_API_KEY="$API_PLACEHOLDER" "$credential_name=$INHERITED_CREDENTIAL_VALUE"
        expect "$check_name" SKIP 'not a full placeholder'
        fact '.agent_exec | "\(.attempted) \(.credential) \(.answered)"' 'false none false'
        expect_codex_not_run
        expect_absent_from_report "$INHERITED_CREDENTIAL_VALUE"
        finish_case
    done

    case_name="${step_name}_inherited_placeholders_empty_and_ordinary_values_allow_codex"
    credential_case_setup "$case_name" "$selected_step"
    begin "$case_name" "step_$selected_step" '' OPENAI_API_KEY="$API_PLACEHOLDER" GITHUB_TOKEN="$PLACEHOLDER" auth="$PLACEHOLDER" credential="$PLACEHOLDER" AWS_SECRET_ACCESS_KEY= KEYBOARD=ordinary-keyboard TOKENIZER=ordinary-tokenizer OAUTH_X=ordinary-oauth SSH_AUTH_SOCK=ordinary-socket
    expect "$check_name" PASS 'codex exec answered'
    fact '.agent_exec | "\(.attempted) \(.credential) \(.exit_code) \(.answered)"' 'true api_key 0 true'
    [ -e "$t/codex.ran" ] || problems="$problems codex-not-run"
    finish_case

    case_name="${step_name}_inherited_env_inspection_available_control"
    credential_case_setup "$case_name" "$selected_step"
    begin "$case_name" "step_$selected_step" '' OPENAI_API_KEY="$API_PLACEHOLDER"
    expect "$check_name" PASS 'codex exec answered'
    fact '.agent_exec | "\(.attempted) \(.credential) \(.exit_code) \(.answered)"' 'true api_key 0 true'
    [ -e "$t/codex.ran" ] || problems="$problems codex-not-run"
    finish_case

    case_name="${step_name}_inherited_env_inspection_unavailable_skips_codex"
    credential_case_setup "$case_name" "$selected_step"
    begin_without_probe_env "$case_name" "step_$selected_step" '' OPENAI_API_KEY="$API_PLACEHOLDER"
    expect "$check_name" SKIP 'could not inspect'
    fact '.agent_exec | "\(.attempted) \(.credential) \(.answered)"' 'false none false'
    expect_codex_not_run
    finish_case
done

mk j16_engine_refused
with_curl
answer "$PING" 7 000
answer "$OUTSIDE" 7 000
begin j16_engine_refused step_J16 "$ENGINE"
expect engine_denied PASS 'refused the connection (curl exit 7'
fact '.connection | "\(.attempted) \(.curl_found) \(.curl_exit) \(.http_code)"' 'true true 7 0'
finish_case

mk j16_engine_name_refused_while_resolver_works
with_curl
answer "$PING" 6 000
answer "$OUTSIDE" 7 000
begin j16_engine_name_refused_while_resolver_works step_J16 "$ENGINE"
expect engine_denied PASS 'refuses the name'
fact '.connection | "\(.curl_found) \(.curl_exit) \(.http_code)"' 'true 6 0'
fact '.resolver_control | "\(.curl_found) \(.curl_exit) \(.http_code)"' 'true 7 0'
finish_case

mk j16_resolver_fault
with_curl
answer "$PING" 6 000
answer "$OUTSIDE" 6 000
begin j16_resolver_fault step_J16 "$ENGINE"
expect engine_denied FAIL 'resolver fault'
fact '.resolver_control | "\(.curl_found) \(.curl_exit) \(.http_code)"' 'true 6 0'
finish_case

mk j16_a_curlrc_of_the_sandbox_user_cannot_turn_an_answering_engine_into_a_denial
with_curl
printf 'connect-to = "::127.0.0.1:9"\n' >"$t/sandbox/.curlrc"
answer "$PING" 0 200
answer "$OUTSIDE" 7 000
begin j16_a_curlrc_of_the_sandbox_user_cannot_turn_an_answering_engine_into_a_denial step_J16 "$ENGINE" CURL_HOME="$t/sandbox"
expect engine_denied FAIL 'answered HTTP 200'
finish_case

for proxy in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
    proxy_case=j16_${proxy}_presence_fails
    mk "$proxy_case"
    with_curl
    answer "$PING" 7 000
    answer "$OUTSIDE" 7 000
    begin "$proxy_case" step_J16 "$ENGINE" "$proxy="
    expect engine_denied FAIL 'proxy variables are set'
    finish_case
done

mk j16_curl_missing
begin j16_curl_missing step_J16 "$ENGINE"
expect engine_denied FAIL 'curl is not installed'
fact '.connection | "\(.attempted) \(.curl_found) \(.curl_exit) \(.http_code)"' 'true false null 0'
finish_case

mk j16_inherited_curl_cannot_fill_missing_trusted_curl
printf '#!/bin/sh\necho selected >>"%s/curl.selected"\nprintf 200\nexit 0\n' "$t" >"$t/bad-bin/curl"
chmod +x "$t/bad-bin/curl"
begin j16_inherited_curl_cannot_fill_missing_trusted_curl step_J16 "$ENGINE"
expect engine_denied FAIL 'curl is not installed'
fact '.connection | "\(.attempted) \(.curl_found) \(.curl_exit) \(.http_code)"' 'true false null 0'
[ ! -e "$t/curl.selected" ] || problems="$problems inherited-curl-selected"
finish_case

mk j16_curl_shadow_uses_curated_boundary_fixture
with_curl
answer "$PING" 7 000
answer "$OUTSIDE" 7 000
printf '#!/bin/sh\necho selected >>"%s/curl.selected"\nexit 91\n' "$t" >"$t/bad-bin/curl"
chmod +x "$t/bad-bin/curl"
begin j16_curl_shadow_uses_curated_boundary_fixture step_J16 "$ENGINE"
expect engine_denied PASS 'refused the connection (curl exit 7'
fact '.connection | "\(.attempted) \(.curl_found) \(.curl_exit) \(.http_code)"' 'true true 7 0'
[ ! -e "$t/curl.selected" ] || problems="$problems inherited-curl-selected"
finish_case

mk j16_engine_answers
with_curl
answer "$PING" 0 200
answer "$OUTSIDE" 7 000
begin j16_engine_answers step_J16 "$ENGINE"
expect engine_denied FAIL 'answered HTTP 200'
finish_case

mk j16_engine_timeout
with_curl
answer "$PING" 28 000
answer "$OUTSIDE" 7 000
begin j16_engine_timeout step_J16 "$ENGINE"
expect engine_denied FAIL 'curl exit 28'
finish_case

mk j16_no_engine_endpoint
with_curl
begin j16_no_engine_endpoint step_J16 ''
expect engine_denied SKIP 'no --engine endpoint'
fact '.resolver_control' 'null'
finish_case

echo "$total cases, $failures failed"
[ "$failures" -eq 0 ]
