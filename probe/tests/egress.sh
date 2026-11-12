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
for tool in sh base64 jq sed tr cat env awk grep mktemp rm wc head od mkdir cp chmod sha256sum cut sort python3; do
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
    mkdir -p "$t/bin" "$t/bad-bin" "$t/home" "$t/sandbox/project" "$t/tmp"
    : >"$t/table"
    : >"$t/curl.log"
    PROVIDER=https://chatgpt.com/backend-api/models
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
    # shellcheck disable=SC2016
    "$scratch/tools/jq" \
        --arg binary "$t/bin/codex" --arg workdir "$t/sandbox/project" \
        '.behavior.credential.classification = "oauth_login" |
         .behavior.credential.environment = [{"name":"CODEX_AUTH_ACCESS_TOKEN","kind":"placeholder"}] |
         .behavior.credential.auth_file.required_state = "present" |
         .behavior.credential.auth_file.fields = [
             {"name":"/tokens/access_token","kind":"placeholder"},
             {"name":"/tokens/refresh_token","kind":"empty"},
             {"name":"/tokens/id_token","kind":"empty"}
         ] |
         .behavior.prompt.tool = {
             argv: [$binary, "exec", "--skip-git-repo-check", "Use one shell tool to run ls -A, then reply with exactly ready"],
             answer: {"word_case_insensitive":{"word":"ready"}},
             kind: "shell", workdir: $workdir,
             observation: {directory_contains: {entries: ["AGENTS.md","Dockerfile","instructions","jackin.role.toml","probe","tests"]}}
         }' "$t/spec" >"$t/spec.next" || return 1
    mv "$t/spec.next" "$t/spec" || return 1
    cat >"$t/probe" <<EOF
#!/bin/sh
exec "$t/probe.impl" --spec "$t/spec" "\$@"
EOF
    chmod +x "$t/probe" "$t/probe.impl"
}

zai_spec() {
    adapter=$1
    agent=$2
    comm=$3
    version=$4
    kind=$5
    env_name=$6
    provider_url=$7
    auth_state=$8
    fingerprint=$9
    PROVIDER=$provider_url
    printf '%s' "${zai_model:-glm-5.3}" >"$t/zai.model"
    # shellcheck disable=SC2016
    "$scratch/tools/jq" \
        --arg adapter "$adapter" --arg agent "$agent" --arg comm "$comm" --arg version "$version" \
        --arg kind "$kind" --arg env_name "$env_name" --arg provider_url "$provider_url" \
        --arg auth_state "$auth_state" --arg fingerprint "$fingerprint" --arg workdir "$t/sandbox/project" \
        --arg binary "$t/bin/$agent" --arg sandbox "$t/sandbox" --rawfile model "$t/zai.model" \
        '.target.tuple = ($adapter[0:3] | ascii_upcase) |
         .target.adapter = $adapter |
         .target.agent = $agent |
         .target.provider = "zai" |
         .target.model = $model |
         .credential_sha256 = $fingerprint |
         .behavior.version.binary = $binary |
         .behavior.version.exact_output = $version |
         .behavior.process.comm = $comm |
         .behavior.prompt.argv[0] = $binary |
         .behavior.prompt.tool.argv[0] = $binary |
         .behavior.prompt.tool.kind = $kind |
         .behavior.prompt.tool.workdir = $workdir |
         .behavior.credential.classification = "static_key" |
         .behavior.credential.environment = [{"name":$env_name,"kind":"brokered"}] |
         .behavior.credential.auth_file.required_state = $auth_state |
         .behavior.provider.probe_url = $provider_url |
         .behavior.provider.accepted_status = null |
         .behavior.provider.accepted_body = null |
         if $adapter == "t09-omp-zai-v1" then
             .behavior.credential.auth_file.path = ($sandbox + "/.omp/auth.json") |
             .behavior.credential.auth_file.fields = [{"name":"/zai/type","kind":{"literal":{"value":"api_key"}}},{"name":"/zai/key","kind":"placeholder"}] |
             .behavior.credential.config_files = [{"path":($sandbox + "/.omp/config.toml"),"required_state":"present","mode":"600","required_text":["baseUrl: https://api.z.ai/api/anthropic","credentialEnv: ZAI_API_KEY","default: zai/glm-5.3"],"forbidden_text":["https://api.z.ai/api/coding/paas/v4"]},{"path":($sandbox + "/.omp/agent/models.yml"),"required_state":"present","mode":"600","required_text":["baseUrl: https://api.z.ai/api/anthropic","api: anthropic-messages","apiKey: ZAI_API_KEY"],"forbidden_text":["https://api.z.ai/api/coding/paas/v4"]}]
         elif $adapter == "t14-claude-zai-v1" then
             .behavior.credential.auth_file.path = ($sandbox + "/.claude/.credentials.json") |
             .behavior.credential.auth_file.fields = [{"name":"/ANTHROPIC_API_KEY","kind":"placeholder"}] |
             .behavior.credential.config_files = [{"path":($sandbox + "/.claude/settings.json"),"required_state":"present","mode":"600","required_text":["{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://api.z.ai/api/anthropic\"}}"],"forbidden_text":["ANTHROPIC_AUTH_TOKEN","ZAI_API_KEY"]}]
         else
             .behavior.credential.auth_file.path = ($sandbox + "/.codex/auth.json") |
             .behavior.credential.auth_file.fields = []
         end' \
        "$t/spec" >"$t/spec.next" || return 1
    mv "$t/spec.next" "$t/spec" || return 1
}

zai_says() {
    adapter=$1
    agent=$2
    provider_url=$3
    cat >"$t/bin/$agent" <<EOF
#!/bin/sh
echo ran >>"$t/codex.ran"
env >"$t/codex.env" 2>/dev/null || true
token=
if [ -n "\${CODEX_HOME-}" ] && [ -f "\${CODEX_HOME}/auth.json" ]; then
    token=\$(jq -r '.tokens.access_token // .OPENAI_API_KEY // empty' "\${CODEX_HOME}/auth.json" 2>/dev/null) || token=
fi
if [ -n "\$token" ]; then
    printf '%s\n' "\$token" >>"$t/agent.credential"
    printf 'Authorization: Bearer %s\n' "\$token" >"$t/agent.header"
    curl -q -s --noproxy '*' -o /dev/null -H "@$t/agent.header" "$provider_url" >/dev/null 2>&1 </dev/null
fi
case " \$* " in
    *"Use one shell tool"*)
        printf '%s\n' '{"type":"turn_context","provider":"zai","model":"glm-5.3"}'
        case $adapter in
            t09-omp-zai-v1)
                printf '%s\n' '{"type":"tool_call","name":"bash","workdir":"$t/sandbox/project"}'
                printf '%s\n' '{"type":"tool_result","isError":false,"content":"AGENTS.md Dockerfile instructions jackin.role.toml probe tests"}'
                ;;
            t14-claude-zai-v1)
                printf '%s\n' '{"type":"tool_use","name":"Bash","workdir":"$t/sandbox/project"}'
                printf '%s\n' '{"type":"tool_result","is_error":false,"content":"AGENTS.md Dockerfile instructions jackin.role.toml probe tests"}'
                ;;
            *)
                printf '%s\n' '{"type":"exec_command_begin","workdir":"$t/sandbox/project","command":["ls","-A"]}'
                printf '%s\n' '{"type":"exec_command_end","exit_code":0,"stdout":"AGENTS.md Dockerfile instructions jackin.role.toml probe tests"}'
                ;;
        esac
        printf '%s\n' '{"type":"assistant","text":"ready"}'
        exit 0
        ;;
esac
echo ready
exit 0
EOF
    chmod +x "$t/bin/$agent"
}

codex_says() {
    cat >"$t/bin/codex" <<EOF
#!/bin/sh
echo ran >>"$t/codex.ran"
env >"$t/codex.env" 2>/dev/null || true
token=
if [ -n "\${CODEX_HOME-}" ] && [ -f "\${CODEX_HOME}/auth.json" ]; then
    token=\$(jq -r '.tokens.access_token // .OPENAI_API_KEY // empty' "\${CODEX_HOME}/auth.json" 2>/dev/null) || token=
fi
if [ -n "\$token" ]; then
    printf '%s\n' "\$token" >>"$t/agent.credential"
    printf 'Authorization: Bearer %s\n' "\$token" >"$t/agent.header"
    curl -q -s --noproxy '*' -o /dev/null -H "@$t/agent.header" "$PROVIDER" >/dev/null 2>&1 </dev/null
fi
if [ -n "\${CODEX_HOME-}" ] && [ -f "\${CODEX_HOME}/config.toml" ]; then
    model=\$(jq -R -r 'first(capture("^[[:space:]]*model[[:space:]]*=[[:space:]]*\"(?<v>[^\"]*)\"")? | .v) // empty' "\${CODEX_HOME}/config.toml" 2>/dev/null) || model=
    if [ -n "\$model" ]; then
        printf 'config-model=%s\n' "\$model" >>"$t/agent.credential"
    fi
fi
case " \$* " in
    *"Use one shell tool"*)
        printf '%s\n' '{"type":"turn_context","provider":"codex","model":"gpt-6.1-sol"}'
        printf '%s\n' '{"type":"exec_command_begin","workdir":"$t/sandbox/project","command":["ls","-A"]}'
        printf '%s\n' '{"type":"exec_command_end","exit_code":0,"stdout":"AGENTS.md Dockerfile instructions jackin.role.toml probe tests"}'
        printf '%s\n' '{"type":"assistant","text":"ready"}'
        exit $2
        ;;
esac
echo "$1"
exit $2
EOF
    chmod +x "$t/bin/codex"
}

codex_says_partial_observation() {
    cat >"$t/bin/codex" <<EOF
#!/bin/sh
echo ran >>"$t/codex.ran"
case " \$* " in
    *"Use one shell tool"*)
        printf '%s\n' '{"type":"turn_context","provider":"codex","model":"gpt-6.1-sol"}'
        printf '%s\n' '{"type":"exec_command_begin","workdir":"$t/sandbox/project","command":["ls","-A"]}'
        printf '%s\n' '{"type":"exec_command_end","exit_code":0,"stdout":"AGENTS.md"}'
        printf '%s\n' '{"type":"assistant","text":"ready"}'
        exit 0
        ;;
esac
echo ready
exit 0
EOF
    chmod +x "$t/bin/codex"
}

codex_says_tmp_spec_mutator() {
    cat >"$t/bin/codex" <<EOF
#!/bin/sh
echo ran >>"$t/codex.ran"
case " \$* " in
    *"Use one shell tool"*)
        for d in /tmp/jackin-sentinel-probe-spec.*; do
            [ -d "\$d" ] || continue
            [ -f "\$d/spec.snapshot" ] || continue
            printf '%s' '{"target":{"tuple":"T99","adapter":"t99-tampered-v1","model":"tampered","provider":"tampered","agent":"codex","spec_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"spec_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' >"\$d/spec.snapshot" 2>/dev/null || :
            echo seen >>"$t/tmp_spec.seen"
        done
        printf '%s\n' '{"type":"turn_context","provider":"codex","model":"gpt-6.1-sol"}'
        printf '%s\n' '{"type":"exec_command_begin","workdir":"$t/sandbox/project","command":["ls","-A"]}'
        printf '%s\n' '{"type":"exec_command_end","exit_code":0,"stdout":"AGENTS.md Dockerfile instructions jackin.role.toml probe tests"}'
        printf '%s\n' '{"type":"assistant","text":"ready"}'
        exit 0
        ;;
esac
echo ready
exit 0
EOF
    chmod +x "$t/bin/codex"
}

codex_says_spec_mutator() {
    cat >"$t/bin/codex" <<EOF
#!/bin/sh
echo ran >>"$t/codex.ran"
case " \$* " in
    *"Use one shell tool"*)
        printf '%s\n' '{"type":"turn_context","provider":"codex","model":"gpt-6.1-sol"}'
        printf '%s\n' '{"type":"exec_command_begin","workdir":"$t/sandbox/project","command":["ls","-A"]}'
        printf '%s\n' '{"type":"exec_command_end","exit_code":0,"stdout":"AGENTS.md Dockerfile instructions jackin.role.toml probe tests"}'
        printf '%s\n' '{"type":"assistant","text":"ready"}'
        exit 0
        ;;
esac
printf 'corrupted' >>"$t/spec"
echo ready
exit 0
EOF
    chmod +x "$t/bin/codex"
}

codex_says_home_mutator() {
    cat >"$t/bin/codex" <<EOF
#!/bin/sh
echo ran >>"$t/codex.ran"
case " \$* " in
    *"Use one shell tool"*)
        cat "\$CODEX_HOME/../spec.snapshot" >>"$t/spec.seen" 2>/dev/null || :
        printf 'corrupted' >>"\$CODEX_HOME/../spec.snapshot" 2>/dev/null || :
        printf '%s\n' '{"type":"turn_context","provider":"codex","model":"gpt-6.1-sol"}'
        printf '%s\n' '{"type":"exec_command_begin","workdir":"$t/sandbox/project","command":["ls","-A"]}'
        printf '%s\n' '{"type":"exec_command_end","exit_code":0,"stdout":"AGENTS.md Dockerfile instructions jackin.role.toml probe tests"}'
        printf '%s\n' '{"type":"assistant","text":"ready"}'
        exit 0
        ;;
esac
echo ready
exit 0
EOF
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
    cat >"$t/bin/codex" <<EOF
#!/bin/sh
echo ran >>$ran_arg
case " \$* " in
    *"Use one shell tool"*)
        printf '%s\n' '{"type":"turn_context","provider":"codex","model":"gpt-6.1-sol"}'
        printf '%s\n' '{"type":"exec_command_begin","workdir":"$t/sandbox/project","command":["ls","-A"]}'
        printf '%s\n' '{"type":"exec_command_end","exit_code":0,"stdout":"AGENTS.md Dockerfile instructions jackin.role.toml probe tests"}'
        printf '%s\n' '{"type":"assistant","text":"ready"}'
        exit $fixture_exit
        ;;
esac
exec $python_arg $generator_arg $kind_arg $exit_arg
EOF
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
    sed -e "s#\$STUB_TABLE#$t/table#g" -e "s#\$STUB_LOG#$t/curl.log#g" "$scratch/stub-curl" >"$t/bin/curl"
    chmod +x "$t/bin/curl"
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

expect_child_variable() {
    variable=$1
    value=$2
    got=$(grep "^$variable=" "$t/codex.env" 2>/dev/null | head -n 1)
    [ "$got" = "$variable=$value" ] || problems="$problems child-variable=[$got](want [$variable=$value])"
}

expect_no_child_variable() {
    variable=$1
    if [ -f "$t/codex.env" ] && grep -q "^$variable=" "$t/codex.env" 2>/dev/null; then
        problems="$problems child-received-$variable"
    fi
}

hostile_codex_home() {
    mkdir -p "$t/hostile"
    printf '%s\n' "{\"tokens\":{\"access_token\":\"$HOSTILE_TOKEN\"}}" >"$t/hostile/auth.json"
}

expect_agent_credential() {
    want=$1
    got=$(sort -u "$t/agent.credential" 2>/dev/null | tr '\n' ' ')
    [ "$got" = "$want " ] || problems="$problems agent-credential=[$got](want [$want ])"
}

expect_no_agent_credential() {
    got=$(sort -u "$t/agent.credential" 2>/dev/null | tr '\n' ' ')
    [ -z "$got" ] || problems="$problems agent-credential=[$got](want none)"
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
    if [ -n "${zai_adapter-}" ]; then
        zai_spec "$zai_adapter" "$zai_agent" "$zai_comm" "$zai_version" "$zai_kind" "$zai_env_name" "$zai_provider_url" "$zai_auth_state" "$zai_fingerprint" || {
            fixture_setup_failed=1
            return 70
        }
        zai_adapter=
    fi
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
HOSTILE_TOKEN=synthetic-hostile-home-token-0123456789
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

mk j09_the_codex_child_runs_with_an_allowlisted_environment
with_curl
codex_says 'ready' 0
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_the_codex_child_runs_with_an_allowlisted_environment step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER" DATABASE_URL=mysql://operator:synthetic-secret@db.internal/one
expect agent_reaches_api PASS 'codex exec answered'
fact '.agent_exec | "\(.attempted) \(.credential)"' 'true oauth_login'
expect_child_variable CODEX_AUTH_ACCESS_TOKEN "$PLACEHOLDER"
expect_no_child_variable DATABASE_URL
expect_never_sent 'synthetic-secret'
expect_absent_from_report 'synthetic-secret'
finish_case

mk j09_a_conventional_credential_name_blocks_the_codex_launch
with_curl
codex_says 'ready' 0
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_a_conventional_credential_name_blocks_the_codex_launch step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER" PGPASSWORD=synthetic-postgres-secret
expect agent_reaches_api SKIP 'the sandbox holds a credential that is not a full placeholder'
fact '.agent_exec | "\(.attempted) \(.credential)"' 'false none'
expect_codex_not_run
expect_no_child_variable PGPASSWORD
expect_never_sent 'synthetic-postgres-secret'
expect_absent_from_report 'synthetic-postgres-secret'
finish_case

mk j09_the_staged_home_supplies_the_declared_credential
with_curl
codex_says 'ready' 0
auth_json "{\"tokens\":{\"access_token\":\"$PLACEHOLDER\"}}"
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_the_staged_home_supplies_the_declared_credential step_J09 ''
expect agent_reaches_api PASS 'codex exec answered'
fact '.agent_exec | "\(.attempted) \(.credential)"' 'true oauth_login'
expect_agent_credential "config-model=gpt-6.1-sol $PLACEHOLDER"
expect_never_sent "$HOSTILE_TOKEN"
expect_absent_from_report "$HOSTILE_TOKEN"
finish_case

mk j09_a_hostile_codex_home_is_not_the_credential_source
with_curl
codex_says 'ready' 0
auth_json "{\"tokens\":{\"access_token\":\"$PLACEHOLDER\"}}"
hostile_codex_home
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_a_hostile_codex_home_is_not_the_credential_source step_J09 '' "CODEX_HOME=$t/hostile"
expect agent_reaches_api PASS 'codex exec answered'
fact '.agent_exec | "\(.attempted) \(.credential)"' 'true oauth_login'
expect_agent_credential "config-model=gpt-6.1-sol $PLACEHOLDER"
expect_never_sent "$HOSTILE_TOKEN"
expect_sent "Authorization: Bearer $PLACEHOLDER"
expect_absent_from_report "$HOSTILE_TOKEN"
finish_case

mk j09_environment_only_credentials_ignore_the_hostile_codex_home
with_curl
codex_says 'ready' 0
hostile_codex_home
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_environment_only_credentials_ignore_the_hostile_codex_home step_J09 '' "OPENAI_API_KEY=$API_PLACEHOLDER" "CODEX_HOME=$t/hostile"
expect agent_reaches_api PASS 'codex exec answered'
fact '.agent_exec | "\(.attempted) \(.credential)"' 'true api_key'
expect_agent_credential 'config-model=gpt-6.1-sol'
expect_never_sent "$HOSTILE_TOKEN"
expect_absent_from_report "$HOSTILE_TOKEN"
finish_case

mk j09_environment_only_credentials_launch_with_the_contract_provider_config
with_curl
codex_says 'ready' 0
mkdir -p "$t/sandbox/.codex"
printf '%s\n' 'model = "synthetic-config-model"' >"$t/sandbox/.codex/config.toml"
hostile_codex_home
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_environment_only_credentials_launch_with_the_contract_provider_config step_J09 '' "OPENAI_API_KEY=$API_PLACEHOLDER" "CODEX_HOME=$t/hostile"
expect agent_reaches_api PASS 'codex exec answered'
fact '.agent_exec | "\(.attempted) \(.credential)"' 'true api_key'
[ -e "$t/codex.ran" ] || problems="$problems codex-not-run"
expect_agent_credential 'config-model=gpt-6.1-sol'
expect_never_sent "$HOSTILE_TOKEN"
expect_absent_from_report "$HOSTILE_TOKEN"
finish_case

mk j09_an_unstageable_auth_file_stops_codex
with_curl
codex_says 'ready' 0
mkdir -p "$t/sandbox/.codex/auth.json"
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
begin j09_an_unstageable_auth_file_stops_codex step_J09 '' "CODEX_AUTH_ACCESS_TOKEN=$PLACEHOLDER"
expect agent_reaches_api SKIP 'could not stage the validated credential home'
fact '.agent_exec | "\(.attempted) \(.credential)"' 'false none'
expect_codex_not_run
expect_never_sent "$HOSTILE_TOKEN"
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

zai_case() {
    zai_adapter=$1
    zai_agent=$2
    zai_comm=$3
    zai_version=$4
    zai_kind=$5
    zai_env_name=$6
    zai_provider_url=$7
    zai_auth_state=$8
    zai_fingerprint=$9
    zai_says "$zai_adapter" "$zai_agent" "$zai_provider_url"
    with_curl
    answer "$OUTSIDE" 7 000
    answer "$METADATA" 7 000
    answer "$zai_provider_url" 7 000
    case $zai_adapter in
        t09-omp-zai-v1)
            mkdir -p "$t/sandbox/.omp/agent"
            printf '%s\n' 'baseUrl: https://api.z.ai/api/anthropic' 'credentialEnv: ZAI_API_KEY' 'default: zai/glm-5.3' >"$t/sandbox/.omp/config.toml"
            printf '%s\n' 'baseUrl: https://api.z.ai/api/anthropic' 'api: anthropic-messages' 'apiKey: ZAI_API_KEY' >"$t/sandbox/.omp/agent/models.yml"
            ;;
        t14-claude-zai-v1)
            mkdir -p "$t/sandbox/.claude"
            printf '%s\n' '{"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic"}}' >"$t/sandbox/.claude/settings.json"
            ;;
    esac
}

for tuple in T09 T14 T18; do
    case $tuple in
        T09)
            adapter=t09-omp-zai-v1
            agent=omp
            comm=omp
            version=omp/18.18.3
            kind=bash
            env_name=ZAI_API_KEY
            provider_url=https://api.z.ai/api/anthropic
            auth_state=present
            ;;
        T14)
            adapter=t14-claude-zai-v1
            agent=claude
            comm=claude
            version='2.1.311 (Claude Code)'
            kind=Bash
            env_name=ANTHROPIC_AUTH_TOKEN
            provider_url=https://api.z.ai/api/anthropic
            auth_state=present
            ;;
        T18)
            adapter=t18-codex-zai-v1
            agent=codex
            comm=codex
            version='codex-cli 0.167.0'
            kind=shell
            env_name=ZAI_API_KEY
            provider_url=https://api.z.ai/api/v1
            auth_state=absent
            ;;
    esac
    host_key="synthetic-${tuple}-host-key-0123456789"
    fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
    mk "${tuple}_brokered_execution_and_policy_closure"
    zai_case "$adapter" "$agent" "$comm" "$version" "$kind" "$env_name" "$provider_url" "$auth_state" "$fingerprint"
    begin "${tuple}_brokered_execution_and_policy_closure" step_J09 '' "$env_name=openshell:resolve:env:$env_name"
    expect agent_reaches_api PASS 'completed the declared tool'
    expect provider_no_credential PASS 'refused the connection'
    fact '.agent_exec | "\(.credential) \(.actual_provider) \(.actual_model) \(.tool.attempted) \(.tool.succeeded) \(.tool.kind)"' "static_key zai glm-5.3 true true $kind"
    expect_sent 'openshell:resolve:env:'
    finish_case

    mk "${tuple}_raw_key_is_not_executed"
    zai_case "$adapter" "$agent" "$comm" "$version" "$kind" "$env_name" "$provider_url" "$auth_state" "$fingerprint"
    begin "${tuple}_raw_key_is_not_executed" step_J09 '' "$env_name=$host_key"
    expect agent_reaches_api SKIP 'not a full placeholder'
    expect provider_no_credential SKIP 'no placeholder to send'
    fact '.agent_exec | "\(.attempted) \(.credential)"' 'false none'
    expect_codex_not_run
    expect_never_sent "$host_key"
    finish_case

    mk "${tuple}_raw_key_is_not_brokered"
    zai_case "$adapter" "$agent" "$comm" "$version" "$kind" "$env_name" "$provider_url" "$auth_state" "$fingerprint"
    begin "${tuple}_raw_key_is_not_brokered" step_J08 '' "$env_name=$host_key"
    expect environment FAIL 'not a placeholder'
    fact '.environment[0].kind' other
    expect_never_sent "$host_key"
    finish_case
done

mk T18_a_hostile_codex_home_is_not_the_credential_source
host_key=synthetic-T18-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t18-codex-zai-v1 codex codex 'codex-cli 0.167.0' shell ZAI_API_KEY https://api.z.ai/api/v1 absent "$fingerprint"
hostile_codex_home
begin T18_a_hostile_codex_home_is_not_the_credential_source step_J09 '' "ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY" "CODEX_HOME=$t/hostile"
expect agent_reaches_api PASS 'completed the declared tool'
fact '.agent_exec | "\(.credential) \(.tool.attempted) \(.tool.succeeded)"' 'static_key true true'
expect_no_agent_credential
expect_never_sent "$HOSTILE_TOKEN"
expect_absent_from_report "$HOSTILE_TOKEN"
finish_case

mk T14_declared_auth_other_is_not_executed
host_key=synthetic-T14-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
env_name=ANTHROPIC_AUTH_TOKEN
zai_case t14-claude-zai-v1 claude claude '2.1.311 (Claude Code)' Bash "$env_name" https://api.z.ai/api/anthropic present "$fingerprint"
mkdir -p "$t/sandbox/.claude"
printf '%s\n' "{\"ANTHROPIC_API_KEY\":\"$host_key\"}" >"$t/sandbox/.claude/.credentials.json"
begin T14_declared_auth_other_is_not_executed step_J09 '' "$env_name=openshell:resolve:env:$env_name"
expect agent_reaches_api SKIP 'not a full placeholder'
expect provider_no_credential PASS 'refused the connection'
fact '.agent_exec | "\(.attempted) \(.credential)"' 'false none'
expect_codex_not_run
expect_never_sent "$host_key"
finish_case

mk t09_a_redirected_live_provider_config_is_not_bound
host_key=synthetic-T09-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t09-omp-zai-v1 omp omp 'omp/18.18.3' bash ZAI_API_KEY https://api.z.ai/api/anthropic present "$fingerprint"
printf '%s\n' 'baseUrl: http://127.0.0.1:9/v1' 'credentialEnv: ZAI_API_KEY' 'default: zai/glm-5.3' >"$t/sandbox/.omp/config.toml"
begin t09_a_redirected_live_provider_config_is_not_bound step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api FAIL 'the provider endpoint is not the contract endpoint https://api.z.ai/api/anthropic'
finish_case

mk t14_a_missing_declared_provider_config_is_not_bound
host_key=synthetic-T14-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t14-claude-zai-v1 claude claude '2.1.311 (Claude Code)' Bash ANTHROPIC_AUTH_TOKEN https://api.z.ai/api/anthropic present "$fingerprint"
rm -f "$t/sandbox/.claude/settings.json"
begin t14_a_missing_declared_provider_config_is_not_bound step_J09 '' ANTHROPIC_AUTH_TOKEN=openshell:resolve:env:ANTHROPIC_AUTH_TOKEN
expect agent_reaches_api FAIL 'the provider endpoint is not the contract endpoint https://api.z.ai/api/anthropic'
finish_case

mk t09_a_commented_contract_url_is_not_the_effective_endpoint
host_key=synthetic-T09-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t09-omp-zai-v1 omp omp 'omp/18.18.3' bash ZAI_API_KEY https://api.z.ai/api/anthropic present "$fingerprint"
printf '%s\n' 'baseUrl: http://127.0.0.1:9/v1' '# baseUrl: https://api.z.ai/api/anthropic' 'credentialEnv: ZAI_API_KEY' 'default: zai/glm-5.3' >"$t/sandbox/.omp/config.toml"
begin t09_a_commented_contract_url_is_not_the_effective_endpoint step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api FAIL 'the provider endpoint is not the contract endpoint https://api.z.ai/api/anthropic'
finish_case

mk t09_a_block_scalar_contract_url_is_not_the_effective_endpoint
host_key=synthetic-T09-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t09-omp-zai-v1 omp omp 'omp/18.18.3' bash ZAI_API_KEY https://api.z.ai/api/anthropic present "$fingerprint"
printf '%s\n' 'baseUrl: http://127.0.0.1:9/v1' 'note: |' '  baseUrl: https://api.z.ai/api/anthropic' 'credentialEnv: ZAI_API_KEY' 'default: zai/glm-5.3' >"$t/sandbox/.omp/config.toml"
begin t09_a_block_scalar_contract_url_is_not_the_effective_endpoint step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api FAIL 'the provider endpoint is not the contract endpoint https://api.z.ai/api/anthropic'
finish_case

mk t09_an_invalid_scalar_holding_the_contract_url_is_rejected
host_key=synthetic-T09-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t09-omp-zai-v1 omp omp 'omp/18.18.3' bash ZAI_API_KEY https://api.z.ai/api/anthropic present "$fingerprint"
printf '%s\n' 'baseUrl: https://api.z.ai/api/anthropic suffix' 'credentialEnv: ZAI_API_KEY' 'default: zai/glm-5.3' >"$t/sandbox/.omp/config.toml"
printf '%s\n' 'baseUrl: https://api.z.ai/api/anthropic suffix' 'api: anthropic-messages' 'apiKey: ZAI_API_KEY' >"$t/sandbox/.omp/agent/models.yml"
begin t09_an_invalid_scalar_holding_the_contract_url_is_rejected step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api FAIL 'the provider endpoint is not the contract endpoint https://api.z.ai/api/anthropic'
finish_case

mk t09_a_duplicate_baseurl_setter_is_rejected
host_key=synthetic-T09-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t09-omp-zai-v1 omp omp 'omp/18.18.3' bash ZAI_API_KEY https://api.z.ai/api/anthropic present "$fingerprint"
printf '%s\n' 'baseUrl: https://api.z.ai/api/anthropic' 'baseUrl: https://api.z.ai/api/anthropic' 'credentialEnv: ZAI_API_KEY' 'default: zai/glm-5.3' >"$t/sandbox/.omp/config.toml"
begin t09_a_duplicate_baseurl_setter_is_rejected step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api FAIL 'the provider endpoint is not the contract endpoint https://api.z.ai/api/anthropic'
finish_case

mk t09_a_note_scalar_is_not_the_effective_endpoint
host_key=synthetic-T09-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t09-omp-zai-v1 omp omp 'omp/18.18.3' bash ZAI_API_KEY https://api.z.ai/api/anthropic present "$fingerprint"
printf '%s\n' 'note: "baseUrl: https://api.z.ai/api/anthropic"' 'credentialEnv: ZAI_API_KEY' 'default: zai/glm-5.3' >"$t/sandbox/.omp/config.toml"
printf '%s\n' 'note: "baseUrl: https://api.z.ai/api/anthropic"' 'api: anthropic-messages' 'apiKey: ZAI_API_KEY' >"$t/sandbox/.omp/agent/models.yml"
begin t09_a_note_scalar_is_not_the_effective_endpoint step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api FAIL 'the provider endpoint is not the contract endpoint https://api.z.ai/api/anthropic'
finish_case

mk t09_conflicting_effective_endpoint_config_is_rejected
host_key=synthetic-T09-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t09-omp-zai-v1 omp omp 'omp/18.18.3' bash ZAI_API_KEY https://api.z.ai/api/anthropic present "$fingerprint"
printf '%s\n' 'baseUrl: https://api.z.ai/api/anthropic' 'credentialEnv: ZAI_API_KEY' 'default: zai/glm-5.3' >"$t/sandbox/.omp/config.toml"
printf '%s\n' 'baseUrl: http://127.0.0.1:9/v1' 'api: anthropic-messages' 'apiKey: ZAI_API_KEY' >"$t/sandbox/.omp/agent/models.yml"
begin t09_conflicting_effective_endpoint_config_is_rejected step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api FAIL 'the provider endpoint is not the contract endpoint https://api.z.ai/api/anthropic'
finish_case

mk t14_a_note_scalar_is_not_the_effective_endpoint
host_key=synthetic-T14-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t14-claude-zai-v1 claude claude '2.1.311 (Claude Code)' Bash ANTHROPIC_AUTH_TOKEN https://api.z.ai/api/anthropic present "$fingerprint"
printf '%s\n' '{"note":{"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic"}}}' >"$t/sandbox/.claude/settings.json"
begin t14_a_note_scalar_is_not_the_effective_endpoint step_J09 '' ANTHROPIC_AUTH_TOKEN=openshell:resolve:env:ANTHROPIC_AUTH_TOKEN
expect agent_reaches_api FAIL 'the provider endpoint is not the contract endpoint https://api.z.ai/api/anthropic'
finish_case

mk t18_a_second_provider_table_is_not_a_conflict
host_key=synthetic-T18-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t18-codex-zai-v1 codex codex 'codex-cli 0.167.0' shell ZAI_API_KEY https://api.z.ai/api/v1 absent "$fingerprint"
mkdir -p "$t/sandbox/.codex"
cat >"$t/sandbox/.codex/config.toml" <<'MOCKCONF'
model = "glm-5.3"
model_provider = "zai"

[model_providers.zai]
name = "Z.AI"
base_url = "https://api.z.ai/api/v1"
env_key = "ZAI_API_KEY"
wire_api = "responses"

[model_providers.other]
name = "Other"
base_url = "http://127.0.0.1:9/v1"
MOCKCONF
begin t18_a_second_provider_table_is_not_a_conflict step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api PASS 'completed the declared tool'
fact '.agent_exec | "\(.actual_endpoint) \(.sandbox_endpoint)"' 'https://api.z.ai/api/v1 https://api.z.ai/api/v1'
finish_case

mk t18_a_multiline_marker_is_not_a_table_header
host_key=synthetic-T18-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t18-codex-zai-v1 codex codex 'codex-cli 0.167.0' shell ZAI_API_KEY https://api.z.ai/api/v1 absent "$fingerprint"
mkdir -p "$t/sandbox/.codex"
cat >"$t/sandbox/.codex/config.toml" <<'MOCKCONF'
model = "glm-5.3"
model_provider = "zai"

[model_providers.zai]
name = """
Z.AI
[Z.AI]
"""
base_url = "https://api.z.ai/api/v1"
env_key = "ZAI_API_KEY"
wire_api = "responses"
MOCKCONF
begin t18_a_multiline_marker_is_not_a_table_header step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api PASS 'completed the declared tool'
fact '.agent_exec | "\(.actual_endpoint) \(.sandbox_endpoint)"' 'https://api.z.ai/api/v1 https://api.z.ai/api/v1'
finish_case

mk t18_a_provider_header_inside_a_multiline_string_is_not_a_table
host_key=synthetic-T18-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t18-codex-zai-v1 codex codex 'codex-cli 0.167.0' shell ZAI_API_KEY https://api.z.ai/api/v1 absent "$fingerprint"
mkdir -p "$t/sandbox/.codex"
cat >"$t/sandbox/.codex/config.toml" <<'MOCKCONF'
model = "glm-5.3"
model_provider = "zai"

[model_providers.zai]
name = """
[model_providers.zai]
"""
base_url = "https://api.z.ai/api/v1"
env_key = "ZAI_API_KEY"
wire_api = "responses"
MOCKCONF
begin t18_a_provider_header_inside_a_multiline_string_is_not_a_table step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api PASS 'completed the declared tool'
fact '.agent_exec | "\(.actual_endpoint) \(.sandbox_endpoint)"' 'https://api.z.ai/api/v1 https://api.z.ai/api/v1'
finish_case

mk t09_an_indented_nested_base_url_is_not_the_root_key
host_key=synthetic-T09-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t09-omp-zai-v1 omp omp 'omp/18.18.3' bash ZAI_API_KEY https://api.z.ai/api/anthropic present "$fingerprint"
printf '%s\n' 'note:' '  baseUrl: https://api.z.ai/api/anthropic' 'credentialEnv: ZAI_API_KEY' 'default: zai/glm-5.3' >"$t/sandbox/.omp/config.toml"
printf '%s\n' 'note:' '  baseUrl: https://api.z.ai/api/anthropic' 'api: anthropic-messages' 'apiKey: ZAI_API_KEY' >"$t/sandbox/.omp/agent/models.yml"
begin t09_an_indented_nested_base_url_is_not_the_root_key step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api FAIL 'the provider endpoint is not the contract endpoint https://api.z.ai/api/anthropic'
finish_case

mk t09_a_crlf_config_is_parsed_normalized
host_key=synthetic-T09-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t09-omp-zai-v1 omp omp 'omp/18.18.3' bash ZAI_API_KEY https://api.z.ai/api/anthropic present "$fingerprint"
printf 'baseUrl: https://api.z.ai/api/anthropic\r\ncredentialEnv: ZAI_API_KEY\r\ndefault: zai/glm-5.3\r\n' >"$t/sandbox/.omp/config.toml"
printf 'baseUrl: https://api.z.ai/api/anthropic\r\napi: anthropic-messages\r\napiKey: ZAI_API_KEY\r\n' >"$t/sandbox/.omp/agent/models.yml"
begin t09_a_crlf_config_is_parsed_normalized step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api PASS 'completed the declared tool'
finish_case

mk j04_an_oversized_target_model_still_emits_the_report
host_key=synthetic-T09-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_model=$(printf '%200000s' '' | tr ' ' m)
zai_case t09-omp-zai-v1 omp omp 'omp/18.18.3' bash ZAI_API_KEY https://api.z.ai/api/anthropic present "$fingerprint"
begin j04_an_oversized_target_model_still_emits_the_report step_J04 ''
jq -e '.target.model | length == 200000' "$t/out" >/dev/null 2>&1 || problems="$problems target-model-not-in-report"
zai_model=
finish_case

mk t09_a_mid_request_swap_and_restore_does_not_rebind_the_launch
host_key=synthetic-T09-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t09-omp-zai-v1 omp omp 'omp/18.18.3' bash ZAI_API_KEY https://api.z.ai/api/anthropic present "$fingerprint"
cat >"$t/bin/omp" <<EOF
#!/bin/sh
echo ran >>"$t/codex.ran"
env >"$t/codex.env" 2>/dev/null || true
case " \$* " in
    *"Use one shell tool"*)
        conf=$t/sandbox/.omp/config.toml
        cp "\$conf" "$t/omp.orig" 2>/dev/null || true
        printf '%s\n' 'baseUrl: http://127.0.0.1:9/v1' 'credentialEnv: ZAI_API_KEY' 'default: zai/glm-5.3' >"\$conf" 2>/dev/null || true
        effective=\$(sed -n 's/^baseUrl: //p' "\$conf" | head -n 1)
        printf '%s\n' "\$effective" >"$t/omp.used"
        curl -q -s --noproxy '*' -o /dev/null "\$effective" >/dev/null 2>&1 </dev/null
        cp "$t/omp.orig" "\$conf" 2>/dev/null || true
        printf '%s\n' '{"type":"turn_context","provider":"zai","model":"glm-5.3"}'
        printf '%s\n' '{"type":"tool_call","name":"bash","workdir":"$t/sandbox/project"}'
        printf '%s\n' '{"type":"tool_result","isError":false,"content":"AGENTS.md Dockerfile instructions jackin.role.toml probe tests"}'
        printf '%s\n' '{"type":"assistant","text":"ready"}'
        exit 0
        ;;
esac
echo ready
exit 0
EOF
chmod +x "$t/bin/omp"
begin t09_a_mid_request_swap_and_restore_does_not_rebind_the_launch step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api PASS 'completed the declared tool'
expect_never_sent 'http://127.0.0.1:9/v1'
used_endpoint=$(cat "$t/omp.used" 2>/dev/null)
[ "$used_endpoint" = https://api.z.ai/api/anthropic ] || problems="$problems used-endpoint=[$used_endpoint]"
finish_case

mk t09_a_quoted_key_root_base_url_is_the_effective_endpoint
host_key=synthetic-T09-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t09-omp-zai-v1 omp omp 'omp/18.18.3' bash ZAI_API_KEY https://api.z.ai/api/anthropic present "$fingerprint"
cat >"$t/sandbox/.omp/config.toml" <<'MOCKCONF'
note: 'declared
baseUrl: https://api.z.ai/api/anthropic
credentialEnv: ZAI_API_KEY
default: zai/glm-5.3'
"baseUrl": http://127.0.0.1:9/v1
credentialEnv: ZAI_API_KEY
default: zai/glm-5.3
MOCKCONF
cat >"$t/sandbox/.omp/agent/models.yml" <<'MOCKCONF'
note: 'declared
baseUrl: https://api.z.ai/api/anthropic
'
"baseUrl": http://127.0.0.1:9/v1
api: anthropic-messages
apiKey: ZAI_API_KEY
MOCKCONF
begin t09_a_quoted_key_root_base_url_is_the_effective_endpoint step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api FAIL 'the provider endpoint is not the contract endpoint https://api.z.ai/api/anthropic'
finish_case

mk t18_a_quote_run_terminator_is_not_an_early_close
host_key=synthetic-T18-host-key-0123456789
fingerprint=$(printf '%s' "$host_key" | sha256sum | cut -d' ' -f1)
zai_case t18-codex-zai-v1 codex codex 'codex-cli 0.167.0' shell ZAI_API_KEY https://api.z.ai/api/v1 absent "$fingerprint"
mkdir -p "$t/sandbox/.codex"
cat >"$t/sandbox/.codex/config.toml" <<'MOCKCONF'
model = "glm-5.3"
model_provider = "zai"

[model_providers.zai]
name = '''z''''
note = '''
base_url = "https://api.z.ai/api/v1"
'''
base_url = 'http://127.0.0.1:9/v1'
env_key = "ZAI_API_KEY"
wire_api = "responses"
MOCKCONF
begin t18_a_quote_run_terminator_is_not_an_early_close step_J09 '' ZAI_API_KEY=openshell:resolve:env:ZAI_API_KEY
expect agent_reaches_api FAIL 'the provider endpoint is not the contract endpoint https://api.z.ai/api/v1'
finish_case

for selected_step in J07 J09; do
    if [ "$selected_step" = J07 ]; then
        step_name=j07
        check_name=agent_exec
    else
        step_name=j09
        check_name=agent_reaches_api
    fi
    case_name="${step_name}_a_partial_tool_observation_is_not_complete"
    mk "$case_name"
    codex_says_partial_observation
    if [ "$selected_step" = J09 ]; then
        with_curl
        answer "$OUTSIDE" 7 000
        answer "$METADATA" 7 000
        answer "$PROVIDER" 7 000
    fi
    mkdir -p "$t/sandbox/.codex"
    printf '%s\n' "{\"tokens\":{\"access_token\":\"$PLACEHOLDER\",\"refresh_token\":\"\",\"id_token\":\"\"}}" >"$t/sandbox/.codex/auth.json"
    begin "$case_name" "step_$selected_step" '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
    expect "$check_name" FAIL 'agent exec or tool evidence is incomplete (exit 0)'
    fact '.agent_exec.tool.observation | length' '1'
    fact '.agent_exec.tool.observation[0]' 'AGENTS.md'
    finish_case
done

mk j09_a_spec_rewritten_midrun_cannot_change_the_report
codex_says_spec_mutator
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
mkdir -p "$t/sandbox/.codex"
printf '%s\n' "{\"tokens\":{\"access_token\":\"$PLACEHOLDER\",\"refresh_token\":\"\",\"id_token\":\"\"}}" >"$t/sandbox/.codex/auth.json"
begin j09_a_spec_rewritten_midrun_cannot_change_the_report step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect agent_reaches_api PASS 'completed the declared tool'
jq -e '.target.tuple == "T01" and .target.adapter == "t01-codex-v1" and .target.spec_sha256 == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$t/out" >/dev/null 2>&1 || problems="$problems target-not-snapshotted"
finish_case

mk j09_the_agent_cannot_reach_the_attested_spec_snapshot
codex_says_home_mutator
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
mkdir -p "$t/sandbox/.codex"
printf '%s\n' "{\"tokens\":{\"access_token\":\"$PLACEHOLDER\",\"refresh_token\":\"\",\"id_token\":\"\"}}" >"$t/sandbox/.codex/auth.json"
begin j09_the_agent_cannot_reach_the_attested_spec_snapshot step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect agent_reaches_api PASS 'completed the declared tool'
jq -e '.target.tuple == "T01"' "$t/out" >/dev/null 2>&1 || problems="$problems target-not-snapshotted"
[ ! -s "$t/spec.seen" ] || problems="$problems agent-read-the-attested-spec"
finish_case

mk j09_the_agent_cannot_rewrite_the_tmp_spec_snapshot
codex_says_tmp_spec_mutator
with_curl
answer "$OUTSIDE" 7 000
answer "$METADATA" 7 000
answer "$PROVIDER" 7 000
mkdir -p "$t/sandbox/.codex"
printf '%s\n' "{\"tokens\":{\"access_token\":\"$PLACEHOLDER\",\"refresh_token\":\"\",\"id_token\":\"\"}}" >"$t/sandbox/.codex/auth.json"
begin j09_the_agent_cannot_rewrite_the_tmp_spec_snapshot step_J09 '' CODEX_AUTH_ACCESS_TOKEN="$PLACEHOLDER"
expect agent_reaches_api PASS 'completed the declared tool'
jq -e '.target.tuple == "T01" and .target.adapter == "t01-codex-v1" and .target.spec_sha256 == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$t/out" >/dev/null 2>&1 || problems="$problems target-not-snapshotted"
[ ! -s "$t/tmp_spec.seen" ] || problems="$problems agent-reached-the-tmp-spec-snapshot"
finish_case

for tuple in T09 T14 T18; do
    case $tuple in
        T09)
            adapter=t09-omp-zai-v1
            agent=omp
            comm=omp
            version=omp/18.18.3
            kind=bash
            env_name=ZAI_API_KEY
            provider_url=https://api.z.ai/api/anthropic
            auth_state=present
            auth_dir=.omp
            auth_name=auth.json
            ;;
        T14)
            adapter=t14-claude-zai-v1
            agent=claude
            comm=claude
            version='2.1.311 (Claude Code)'
            kind=Bash
            env_name=ANTHROPIC_AUTH_TOKEN
            provider_url=https://api.z.ai/api/anthropic
            auth_state=present
            auth_dir=.claude
            auth_name=.credentials.json
            ;;
        T18)
            adapter=t18-codex-zai-v1
            agent=codex
            comm=codex
            version='codex-cli 0.167.0'
            kind=shell
            env_name=ZAI_API_KEY
            provider_url=https://api.z.ai/api/v1
            auth_state=absent
            auth_dir=.codex
            auth_name=auth.json
            ;;
    esac
    fingerprint=$(printf '%s' "synthetic-${tuple}-host-key-0123456789" | sha256sum | cut -d' ' -f1)
    mk "${tuple}_malformed_auth_json"
    zai_case "$adapter" "$agent" "$comm" "$version" "$kind" "$env_name" "$provider_url" "$auth_state" "$fingerprint"
    mkdir -p "$t/sandbox/$auth_dir"
    printf '%s\n' 'not-json' >"$t/sandbox/$auth_dir/$auth_name"
    begin "${tuple}_malformed_auth_json" step_J08 '' "$env_name=openshell:resolve:env:$env_name"
    if [ "$tuple" = T18 ]; then
        expect auth_file FAIL 'requires an absent auth file'
    else
        expect auth_file FAIL 'not a placeholder'
    fi
    fact '.auth_file.state' malformed
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
