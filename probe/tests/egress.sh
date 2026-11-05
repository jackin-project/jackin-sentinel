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

mkdir "$scratch/tools"
for tool in sh jq sed tr cat env awk grep mktemp rm wc; do
    found=$(command -v "$tool") || {
        echo "FAIL setup: $tool is not installed"
        exit 70
    }
    ln -s "$found" "$scratch/tools/$tool"
done
real_id=$(command -v id) || exit 70
printf '#!/bin/sh\necho Linux\n' >"$scratch/tools/uname"
printf '#!/bin/sh\n[ "$*" = -un ] && echo sandbox && exit 0\nexec %s "$@"\n' "$real_id" >"$scratch/tools/id"
printf '#!/bin/sh\nshift\nexec "$@"\n' >"$scratch/tools/timeout"
chmod +x "$scratch/tools/uname" "$scratch/tools/id" "$scratch/tools/timeout"
if PATH="$scratch/tools" command -v curl >/dev/null 2>&1; then
    echo "FAIL setup: the tool directory reaches a real curl"
    exit 70
fi

cat >"$scratch/stub-curl" <<'EOF'
#!/bin/sh
for last; do :; done
while read -r url rc code; do
    if [ "$url" = "$last" ]; then
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
    mkdir -p "$t/bin" "$t/sandbox" "$t/tmp"
    : >"$t/table"
    pathvar=$t/bin:$scratch/tools
}

codex_says() {
    printf '#!/bin/sh\necho "%s"\nexit %s\n' "$1" "$2" >"$t/bin/codex"
    chmod +x "$t/bin/codex"
}

auth_json() {
    mkdir -p "$t/sandbox/.codex"
    printf '%s\n' "$1" >"$t/sandbox/.codex/auth.json"
}

with_curl() {
    cp "$scratch/stub-curl" "$t/bin/curl"
}

answer() {
    printf '%s %s %s\n' "$1" "$2" "$3" >>"$t/table"
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
    sed -e "s#/sandbox#$t/sandbox#g" -e "s#^CODEX_BIN=.*#CODEX_BIN=$t/bin/codex#" "$probe" >"$t/probe"
    set -- "$@" sh "$t/probe" --only "${step#step_}"
    [ -z "$engine" ] || set -- "$@" --engine "$engine"
    bounded 20 env -i PATH="$pathvar" TMPDIR="$t/tmp" STUB_TABLE="$t/table" "$@"
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
        problems=" the probe did not finish in time or failed"
    elif ! jq -e --arg step "${1#step_}" '.schema == 1 and .mode == "sandbox" and (.steps | keys) == [$step]' "$t/out" >/dev/null 2>&1; then
        problems=" report-shape"
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
PROVIDER=https://api.openai.com/v1/models
ENGINE=host.openshell.internal:2376
PING=https://$ENGINE/_ping
PLACEHOLDER=openshell:resolve:env:CODEX_AUTH_ACCESS_TOKEN

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
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_provider_refused step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect provider_no_credential PASS 'no credential was applied'
finish_case

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
expect codex_reaches_api PASS 'codex exec answered'
fact '.codex_exec | "\(.attempted) \(.credential) \(.exit_code) \(.answered)"' 'true api_key 0 true'
finish_case

mk j09_codex_timeout_after_partial_output_is_not_an_answer
with_curl
codex_says 'ready' 124
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_codex_timeout_after_partial_output_is_not_an_answer step_J09 '' OPENAI_API_KEY="$PLACEHOLDER"
expect codex_reaches_api FAIL 'exit 124 gave no answer'
fact '.codex_exec | "\(.attempted) \(.exit_code) \(.answered)"' 'true 124 false'
finish_case

mk j09_codex_uses_the_api_key_of_auth_json
with_curl
codex_says 'ready' 0
auth_json '{"OPENAI_API_KEY":"FAKE-api-key-value"}'
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
begin j09_codex_uses_the_api_key_of_auth_json step_J09 ''
expect codex_reaches_api PASS 'codex exec answered'
fact '.codex_exec | "\(.attempted) \(.credential)"' 'true api_key'
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
answer "$PROVIDER" 7 000
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
fact '.provider_host' null
finish_case

mk j09_no_credential_skips_codex
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
begin j09_no_credential_skips_codex step_J09 ''
expect codex_reaches_api SKIP 'no credential'
fact '.codex_exec | "\(.attempted) \(.credential)"' 'false none'
finish_case

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

mk j16_curl_missing
begin j16_curl_missing step_J16 "$ENGINE"
expect engine_denied FAIL 'curl is not installed'
fact '.connection | "\(.attempted) \(.curl_found) \(.curl_exit) \(.http_code)"' 'true false null 0'
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
