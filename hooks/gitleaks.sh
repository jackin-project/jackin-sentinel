#!/bin/sh
# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0
set -efu

private=
scanner_pid=
trace_pid=
stderr_pid=
stdout_pid=

fail() {
    printf '%s\n' "gitleaks hook: $1" >&2
    exit 1
}

cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    exec 7>&- 8>&- 9>&-
    for child in "$scanner_pid" "$trace_pid" "$stderr_pid" "$stdout_pid"; do
        if [ -n "$child" ]; then
            wait "$child" 2>/dev/null || :
        fi
    done
    if [ -n "$private" ] && ! rm -rf "$private"; then
        printf '%s\n' 'gitleaks hook: private metadata cleanup failed' >&2
        status=1
    fi
    exit "$status"
}

trap cleanup 0
trap 'exit 1' HUP INT TERM
umask 077

original_git() (
    unset GIT_EXEC_PATH GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG
    unset GIT_TRACE GIT_TRACE_PACKET GIT_TRACE_PACK_ACCESS GIT_TRACE_PERFORMANCE
    unset GIT_TRACE_SETUP GIT_TRACE_SHALLOW GIT_TRACE_CURL GIT_TRACE_CURL_NO_DATA
    unset GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF GIT_TRACE2_CONFIG_PARAMS GIT_TRACE2_ENV_VARS
    GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        "$timeout_bin" --kill-after=5 60 "$git_real" -c core.fsmonitor=false "$@"
)

clean_run() {
    env -i PATH="$git_exec_path:$PATH" HOME="$private/home" TMPDIR="$private" LANG=C LC_ALL=C \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1 \
        GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_CEILING_DIRECTORIES="$private" \
        GITLEAKS_CONFIG="${GITLEAKS_CONFIG-}" GITLEAKS_CONFIG_TOML="${GITLEAKS_CONFIG_TOML-}" "$@"
}

private_run() {
    clean_run env GIT_DIR="$private/git" GIT_INDEX_FILE="$private/index" GIT_WORK_TREE="$repo_root" \
        GIT_OBJECT_DIRECTORY="$private/git/objects" \
        GIT_ALTERNATE_OBJECT_DIRECTORIES="${GIT_ALTERNATE_OBJECT_DIRECTORIES-}" \
        "$timeout_bin" --kill-after=5 60 "$@"
}

scanner_exec() {
    exec env -i PATH="$git_exec_path:$PATH" HOME="$private/home" TMPDIR="$private" LANG=C LC_ALL=C \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1 \
        GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_CEILING_DIRECTORIES="$private" \
        GIT_DIR="$private/git" GIT_INDEX_FILE="$private/index" GIT_WORK_TREE="$repo_root" \
        GIT_OBJECT_DIRECTORY="$private/git/objects" \
        GIT_ALTERNATE_OBJECT_DIRECTORIES="${GIT_ALTERNATE_OBJECT_DIRECTORIES-}" \
        GIT_TRACE2_EVENT="$trace_target" \
        GITLEAKS_CONFIG="${GITLEAKS_CONFIG-}" GITLEAKS_CONFIG_TOML="${GITLEAKS_CONFIG_TOML-}" \
        "$timeout_bin" --kill-after=5 60 "$@"
}

tool_identity() {
    clean_run "$timeout_bin" --kill-after=5 60 "$git_real" hash-object --no-filters --stdin <"$1" 2>/dev/null
}

check_fifo() {
    fifo_path=$1
    fifo_match=$(find "$fifo_path" -prune -type p -perm 0600 -print 2>/dev/null) || return 1
    [ "$fifo_match" = "$fifo_path" ]
}

fifo_identity() {
    identity=$(find "$1" -prune -type p -perm 0600 -ls 2>/dev/null | awk '{ print $1 }') || return 1
    case $identity in '' | *[!0-9]*) return 1 ;; esac
    printf '%s\n' "$identity"
}

main() {
    [ "$#" -gt 0 ] || fail 'no selected files'
    hook_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd -P) || fail 'hook directory is unavailable'
    for filter in "$hook_dir/gitleaks-trace2.jq" "$hook_dir/gitleaks-stderr.jq"; do
        [ -f "$filter" ] && [ -r "$filter" ] || fail 'protocol filter is unavailable'
    done
    git_launcher=$(command -v git) || fail 'Git is unavailable'
    gitleaks_bin=$(command -v gitleaks) || fail 'Gitleaks is unavailable'
    jq_bin=$(command -v jq) || fail 'jq is unavailable'
    timeout_bin=$(command -v timeout) || fail 'timeout is unavailable'
    for tool in "$git_launcher" "$gitleaks_bin" "$jq_bin" "$timeout_bin"; do
        case $tool in /*) ;; *) fail 'tool path is not absolute' ;; esac
        [ -f "$tool" ] && [ -x "$tool" ] || fail 'tool is not executable'
    done
    git_exec_path=$(env -i PATH="$PATH" LANG=C LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        "$timeout_bin" --kill-after=5 60 "$git_launcher" --exec-path 2>/dev/null) || fail 'Git executable directory is unavailable'
    case $git_exec_path in /*) ;; *) fail 'Git executable directory is not absolute' ;; esac
    git_real=$git_exec_path/git
    [ -f "$git_real" ] && [ -x "$git_real" ] || fail 'direct Git executable is unavailable'
    repo_root=$(original_git rev-parse --show-toplevel 2>/dev/null) || fail 'repository root is unavailable'
    current_root=$(pwd -P) || fail 'working directory is unavailable'
    [ "$current_root" = "$repo_root" ] || fail 'hook must run from the repository root'
    object_format=$(original_git rev-parse --show-object-format=storage 2>/dev/null) || fail 'object format is unavailable'
    case $object_format in
        sha1) object_id_length=40 ;;
        sha256) object_id_length=64 ;;
        *) fail 'object format is unsupported' ;;
    esac
    original_objects=$(original_git rev-parse --path-format=absolute --git-path objects 2>/dev/null) || fail 'object directory is unavailable'
    newline=$(printf '\nx')
    newline=${newline%x}
    case $original_objects in /*) ;; *) fail 'object directory is not absolute' ;; esac
    case $original_objects in *"$newline"*) fail 'object directory contains a newline' ;; esac
    [ -d "$original_objects" ] || fail 'object directory is missing'
    private=$(mktemp -d "${TMPDIR:-/tmp}/sentinel-gitleaks.XXXXXXXX") || fail 'private metadata creation failed'
    mkdir "$private/home" || fail 'private home creation failed'
    git_version=$(clean_run "$timeout_bin" --kill-after=5 60 "$git_real" --version 2>/dev/null) || fail 'Git version is unavailable'
    gitleaks_version=$(clean_run "$timeout_bin" --kill-after=5 60 "$gitleaks_bin" version 2>/dev/null) || fail 'Gitleaks version is unavailable'
    [ "$gitleaks_version" = 8.30.1 ] || fail 'Gitleaks version is not qualified'
    jq_version=$(clean_run "$timeout_bin" --kill-after=5 60 "$jq_bin" --version 2>/dev/null) || fail 'jq version is unavailable'
    [ "$jq_version" = jq-1.8.2 ] || fail 'jq version is not qualified'
    git_identity=$(tool_identity "$git_real") || fail 'Git identity is unavailable'
    gitleaks_identity=$(tool_identity "$gitleaks_bin") || fail 'Gitleaks identity is unavailable'
    jq_identity=$(tool_identity "$jq_bin") || fail 'jq identity is unavailable'
    timeout_identity=$(tool_identity "$timeout_bin") || fail 'timeout identity is unavailable'
    bound_git=$(clean_run sh -c 'command -v git') || fail 'Git PATH binding is unavailable'
    [ "$bound_git" = "$git_real" ] || fail 'Git PATH binding does not match'
    clean_run "$timeout_bin" --kill-after=5 60 "$git_real" init -q --bare --template= \
        --initial-branch=sentinel-private --object-format="$object_format" "$private/git" >/dev/null 2>/dev/null || fail 'private repository creation failed'
    mkdir -p "$private/git/info" || fail 'private info directory creation failed'
    printf '%s\n' "$original_objects" >"$private/git/objects/info/alternates" || fail 'private alternate setup failed'
    printf '* diff\n' >"$private/git/info/attributes" || fail 'private text attributes setup failed'
    private_head=$(private_run "$git_real" symbolic-ref --quiet HEAD 2>/dev/null) || fail 'private HEAD is invalid'
    [ "$private_head" = refs/heads/sentinel-private ] || fail 'private HEAD is unexpected'
    if private_run "$git_real" show-ref --verify --quiet refs/heads/sentinel-private >/dev/null 2>/dev/null; then
        fail 'private HEAD is not unborn'
    else
        head_status=$?
        [ "$head_status" -eq 1 ] || fail 'private HEAD verification failed'
    fi
    for file; do
        metadata=$(original_git --literal-pathspecs ls-files --format='%(objectmode) %(objectname) %(stage)' -- "$file" 2>/dev/null) || fail 'selected entry lookup failed'
        mode=${metadata%% *}
        remainder=${metadata#* }
        object_id=${remainder%% *}
        stage=${remainder#* }
        [ "$metadata" = "$mode $object_id $stage" ] && [ "$stage" = 0 ] || fail 'selected entry is absent, ambiguous, or unmerged'
        [ "${#object_id}" -eq "$object_id_length" ] || fail 'selected object identifier is invalid'
        case $object_id in *[!0-9a-f]*) fail 'selected object identifier is invalid' ;; esac
        case $mode in 100644 | 100755 | 120000) ;; *) fail 'selected entry mode is unsupported' ;; esac
        private_run "$git_real" update-index --add --cacheinfo "$mode,$object_id,$file" >/dev/null 2>/dev/null || fail 'private index selection failed'
    done
    expected_argv=$(clean_run "$jq_bin" -cn --arg root "$repo_root" "[\"git\", \"-C\", \$root, \"diff\", \"-U0\", \"--no-ext-diff\", \"--staged\", \".\"]") || fail 'expected Git command is unavailable'
    run_scan git git --staged --redact=100 --no-banner --no-color --log-level info "$repo_root"
    for file; do
        mode=$(private_run "$git_real" --literal-pathspecs ls-files --format='%(objectmode)' -- "$file" 2>/dev/null) || fail 'private selected mode lookup failed'
        case $mode in
            100644 | 100755) run_scan dir dir --redact=100 --no-banner --no-color --log-level info -- "$file" ;;
            120000) ;;
            *) fail 'selected entry mode changed' ;;
        esac
    done
    [ "$(tool_identity "$git_real")" = "$git_identity" ] || fail 'Git identity changed'
    [ "$(tool_identity "$gitleaks_bin")" = "$gitleaks_identity" ] || fail 'Gitleaks identity changed'
    [ "$(tool_identity "$jq_bin")" = "$jq_identity" ] || fail 'jq identity changed'
    [ "$(tool_identity "$timeout_bin")" = "$timeout_identity" ] || fail 'timeout identity changed'
    [ "$(clean_run "$git_real" --version 2>/dev/null)" = "$git_version" ] || fail 'Git version changed'
}

reader_exec() {
    exec env -i PATH="$git_exec_path:$PATH" HOME="$private/home" LANG=C LC_ALL=C \
        "$timeout_bin" --kill-after=5 70 "$@"
}

run_scan() {
    scan_mode=$1
    shift
    case $scan_mode in git | dir) ;; *) fail 'scanner mode is invalid' ;; esac
    scan_dir=$(mktemp -d "$private/scan.XXXXXXXX") || fail 'private scan metadata creation failed'
    trace_fifo=$scan_dir/trace.fifo
    stderr_fifo=$scan_dir/stderr.fifo
    stdout_fifo=$scan_dir/stdout.fifo
    for fifo in "$trace_fifo" "$stderr_fifo" "$stdout_fifo"; do
        mkfifo -m 600 "$fifo" || fail 'private FIFO creation failed'
        check_fifo "$fifo" || fail 'private FIFO type or mode is invalid'
    done
    trace_inode=$(fifo_identity "$trace_fifo") || fail 'trace FIFO identity is unavailable'
    stderr_inode=$(fifo_identity "$stderr_fifo") || fail 'stderr FIFO identity is unavailable'
    stdout_inode=$(fifo_identity "$stdout_fifo") || fail 'stdout FIFO identity is unavailable'
    exec 7<>"$stdout_fifo" 8<>"$trace_fifo" 9<>"$stderr_fifo"
    exec 4<"$stdout_fifo" 5<"$trace_fifo" 6<"$stderr_fifo"
    (
        exec 0<&4
        exec 4<&- 5<&- 6<&- 7>&- 8>&- 9>&-
        reader_exec wc -c >"$scan_dir/stdout.count" 2>/dev/null
    ) &
    stdout_pid=$!
    if [ "$scan_mode" = git ]; then
        (
            exec 0<&5
            exec 4<&- 5<&- 6<&- 7>&- 8>&- 9>&-
            reader_exec "$jq_bin" -nRc --argjson expected "$expected_argv" \
                -f "$hook_dir/gitleaks-trace2.jq" >"$scan_dir/trace.json" 2>/dev/null
        ) &
        trace_pid=$!
        trace_target=$trace_fifo
    else
        trace_pid=
        trace_target=
    fi
    (
        exec 0<&6
        exec 4<&- 5<&- 6<&- 7>&- 8>&- 9>&-
        reader_exec "$jq_bin" -nRc --arg mode "$scan_mode" \
            -f "$hook_dir/gitleaks-stderr.jq" >"$scan_dir/stderr.json" 2>/dev/null
    ) &
    stderr_pid=$!
    exec 4<&- 5<&- 6<&-
    (
        exec 1>&7 2>&9
        exec 4<&- 5<&- 6<&- 7>&- 8>&- 9>&-
        cd "$repo_root" || exit 125
        scanner_exec "$gitleaks_bin" "$@"
    ) &
    scanner_pid=$!
    if wait "$scanner_pid"; then
        scanner_status=0
    else
        scanner_status=$?
    fi
    scanner_pid=
    exec 7>&- 8>&- 9>&-
    if [ -n "$trace_pid" ]; then
        if wait "$trace_pid"; then trace_status=0; else trace_status=$?; fi
        trace_pid=
        [ "$trace_status" -eq 0 ] || fail 'Git trace reducer failed'
    fi
    if wait "$stderr_pid"; then stderr_status=0; else stderr_status=$?; fi
    stderr_pid=
    [ "$stderr_status" -eq 0 ] || fail 'scanner stderr reducer failed'
    if wait "$stdout_pid"; then stdout_status=0; else stdout_status=$?; fi
    stdout_pid=
    [ "$stdout_status" -eq 0 ] || fail 'scanner stdout counter failed'
    for fifo in "$trace_fifo" "$stderr_fifo" "$stdout_fifo"; do
        check_fifo "$fifo" || fail 'private FIFO type or mode changed'
    done
    [ "$(fifo_identity "$trace_fifo")" = "$trace_inode" ] || fail 'trace FIFO identity changed'
    [ "$(fifo_identity "$stderr_fifo")" = "$stderr_inode" ] || fail 'stderr FIFO identity changed'
    [ "$(fifo_identity "$stdout_fifo")" = "$stdout_inode" ] || fail 'stdout FIFO identity changed'
    "$jq_bin" -Rrse 'test("\\A[ \\t]*0[ \\t]*\\n\\z")' "$scan_dir/stdout.count" >/dev/null 2>&1 || fail 'scanner stdout was not empty'
    if [ "$scan_mode" = git ]; then
        if ! "$jq_bin" -e '.valid == true and .sid_count == 1 and .starts == 1 and .matching_starts == 1
                            and .exits == 1 and .exit_code == 0 and .atexits == 1 and .atexit_code == 0' \
            "$scan_dir/trace.json" >/dev/null 2>&1; then
            producer_code=$("$jq_bin" -r 'if (.exit_code | type) == "number" then .exit_code else -1 end' \
                "$scan_dir/trace.json" 2>/dev/null) || producer_code=-1
            case $producer_code in
                0 | [1-9] | [1-9][0-9] | 1[0-9][0-9] | 2[0-4][0-9] | 25[0-5]) fail "selected Git producer failed (exit $producer_code)" ;;
                *) fail 'selected Git producer was not verified' ;;
            esac
        fi
    fi
    "$jq_bin" -e '.valid == true and .complete == 1 and .errors == 0 and .unknown == 0 and .partials == 0' \
        "$scan_dir/stderr.json" >/dev/null 2>&1 || fail 'scanner logging protocol was not verified'
    if [ "$scanner_status" -eq 0 ] && "$jq_bin" -e '.clean == true and .finding_count == 0' \
        "$scan_dir/stderr.json" >/dev/null 2>&1; then
        rm -rf "$scan_dir" || fail 'private scan cleanup failed'
        return 0
    fi
    if [ "$scanner_status" -eq 1 ] && "$jq_bin" -e '.clean == false and (.finding_count | type) == "number"
                            and .finding_count > 0 and (.finding_count | floor) == .finding_count' \
        "$scan_dir/stderr.json" >/dev/null 2>&1; then
        finding_count=$("$jq_bin" -r '.finding_count' "$scan_dir/stderr.json") || fail 'finding count is unavailable'
        printf 'gitleaks hook: leaks found: %s\n' "$finding_count" >&2
        return 1
    fi
    fail 'scanner status and logging protocol disagree'
}

main "$@"
