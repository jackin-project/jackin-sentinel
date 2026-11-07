#!/bin/sh
set -eu

test_object_format=${SENTINEL_GITLEAKS_OBJECT_FORMAT:-sha1}
case $test_object_format in
    sha1) test_object_id_length=40 ;;
    sha256) test_object_id_length=64 ;;
    *)
        echo "FAIL unsupported_fixture_object_format"
        exit 1
        ;;
esac

root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
prek_version=$(sed -n 's/^prek = "\([^"]*\)"/\1/p' "$root/mise.toml")
gitleaks_version=$(sed -n 's/^gitleaks = "\([^"]*\)"/\1/p' "$root/mise.toml")
prek_bin=$(mise -C / which prek --tool "prek@$prek_version")
gitleaks_bin=$(mise -C / which gitleaks --tool "gitleaks@$gitleaks_version")
jq_version=$(sed -n 's/^jq = "\([^" ]*\)"/\1/p' "$root/mise.toml")
jq_bin=$(mise -C / which jq --tool "jq@$jq_version")
PATH=$(dirname "$gitleaks_bin"):$PATH
export PATH
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

repo=
new_repo() {
    repo=$scratch/$1
    mkdir -p "$repo"
    if ! git -C "$repo" init -q --object-format="$test_object_format"; then
        echo "FAIL fixture_git_init"
        return 1
    fi
    if [ "$(git -C "$repo" rev-parse --show-object-format=storage)" != "$test_object_format" ]; then
        echo "FAIL fixture_git_object_format"
        return 1
    fi
    git -C "$repo" config user.name test
    git -C "$repo" config user.email test@example.invalid
    cp "$root/.pre-commit-config.yaml" "$repo/.pre-commit-config.yaml"
    mkdir -p "$repo/hooks"
    cp "$root/hooks/gitleaks.sh" "$root/hooks/gitleaks-trace2.jq" "$root/hooks/gitleaks-stderr.jq" "$repo/hooks/"
    chmod 755 "$repo/hooks/gitleaks.sh"
    chmod 644 "$repo/hooks/gitleaks-trace2.jq" "$repo/hooks/gitleaks-stderr.jq"
    git -C "$repo" add .pre-commit-config.yaml hooks/gitleaks.sh hooks/gitleaks-trace2.jq hooks/gitleaks-stderr.jq
    git -C "$repo" commit -qm baseline
}

run_pass() {
    if (cd "$repo" && "$prek_bin" run gitleaks >"$scratch/run.out" 2>&1); then
        if grep -Eq 'Skipped|no files to check' "$scratch/run.out" || ! grep -Eq 'gitleaks.*Passed' "$scratch/run.out"; then
            echo "FAIL $1_hook_not_run"
            return 1
        fi
        return 0
    fi
    echo "FAIL $1"
    return 1
}

verify_selected_object_id() {
    selected_object_id=$(git -C "$repo" --literal-pathspecs ls-files --format="%(objectname)" -- "$1")
    if [ "${#selected_object_id}" -ne "$test_object_id_length" ]; then
        echo "FAIL selected_object_id_length"
        return 1
    fi
    case $selected_object_id in
        *[!0-9a-f]*)
            echo "FAIL selected_object_id_encoding"
            return 1
            ;;
    esac
}

new_repo clean
printf 'clean\n' >"$repo/clean.txt"
git -C "$repo" add clean.txt
run_pass staged_clean_file
aws_access_key_id=$(printf '%s%s' 'AKIA' 'Z7VRSQ3ABCDEFGHI')
aws_secret_access_key=$(printf '%s%s' 'wJalrXUtnFEMI/K7MDENG/' 'bPxRfiCYzZ7K3ABcdE')
printf '.env\n' >"$repo/.gitignore"
printf 'aws_access_key_id = "%s"\naws_secret_access_key = "%s"\n' "$aws_access_key_id" "$aws_secret_access_key" >"$repo/.env"
git -C "$repo" add .gitignore
run_pass ignored_untracked_env
git -C "$repo" add -f -- .env
if (cd "$repo" && "$prek_bin" run gitleaks >"$scratch/run.out" 2>&1); then
    echo "FAIL force_added_env_secret_passed"
    exit 1
fi
if grep -Fq "$aws_access_key_id" "$scratch/run.out" || grep -Fq "$aws_secret_access_key" "$scratch/run.out"; then
    echo "FAIL gitleaks_output_disclosed_value"
    exit 1
fi
echo "ok   staged_clean_file_ignored_env_and_force_added_env_secret_rejected"

new_repo option
printf 'clean\n' >"$repo/clean.txt"
git -C "$repo" add clean.txt
run_pass option_baseline
aws_access_key_id=$(printf '%s%s' 'AKIA' 'Z7VRSQ3ABCDEFGHI')
aws_secret=$(printf '%s%s' 'wJalrXUtnFEMI/K7MDENG/' 'bPxRfiCYzZ7K3ABcdE')
printf 'aws_access_key_id = "%s"\naws_secret = "%s"\n' "$aws_access_key_id" "$aws_secret" >"$repo/--exit-code=0"
git -C "$repo" add -f -- --exit-code=0
if (cd "$repo" && "$prek_bin" run gitleaks >"$scratch/run.out" 2>&1); then
    echo "FAIL leading_dash_secret_passed"
    exit 1
fi
if grep -Fq "$aws_access_key_id" "$scratch/run.out" || grep -Fq "$aws_secret" "$scratch/run.out"; then
    echo "FAIL gitleaks_output_disclosed_value"
    exit 1
fi
echo "ok   leading_dash_secret_rejected"

verify_staged_symlink() {
    if [ "$(git -C "$repo" ls-files --stage -- tracked-link | awk '{ print $1 }')" != 120000 ]; then
        echo "FAIL $1_symlink_index_mode"
        return 1
    fi
    if [ "$(git -C "$repo" diff --cached --name-only)" != tracked-link ]; then
        echo "FAIL $1_symlink_not_sole_staged_candidate"
        return 1
    fi
    printf '%s' "$2" >"$scratch/expected-link-blob"
    if ! git -C "$repo" show :tracked-link >"$scratch/index-link-blob" 2>/dev/null ||
        ! cmp -s "$scratch/expected-link-blob" "$scratch/index-link-blob"; then
        echo "FAIL $1_symlink_index_blob"
        return 1
    fi
    verify_selected_object_id tracked-link
}

new_repo clean_symlink
printf 'clean\n' >"$repo/clean-target"
ln -s clean-target "$repo/tracked-link"
git -C "$repo" add -- tracked-link
verify_staged_symlink clean clean-target
run_pass clean_tracked_symlink
echo "ok   clean_tracked_symlink_accepted"

new_repo secret_symlink
aws_access_key_id=$(printf '%s%s' 'AKIA' 'Z7VRSQ3ABCDEFGHI')
aws_secret_access_key=$(printf '%s%s' 'wJalrXUtnFEMI/K7MDENG/' 'bPxRfiCYzZ7K3ABcdE')
secret_link_text=$(printf 'aws_access_key_id = "%s"\naws_secret_access_key = "%s"' "$aws_access_key_id" "$aws_secret_access_key")
if ! mkdir -p "$(dirname "$repo/$secret_link_text")" 2>/dev/null ||
    ! printf 'clean\n' >"$repo/$secret_link_text" 2>/dev/null ||
    ! ln -s "$secret_link_text" "$repo/tracked-link" 2>/dev/null; then
    echo "FAIL secret_symlink_fixture_setup"
    exit 1
fi
printf 'clean\n' >"$scratch/expected-clean-target"
if ! cmp -s "$scratch/expected-clean-target" "$repo/tracked-link" 2>/dev/null; then
    echo "FAIL secret_symlink_target_not_clean"
    exit 1
fi
git -C "$repo" add -- tracked-link
verify_staged_symlink secret "$secret_link_text"
hook_rc=0
(cd "$repo" && "$prek_bin" run gitleaks >"$scratch/run.out" 2>&1) || hook_rc=$?
if [ "$hook_rc" -eq 0 ]; then
    echo "FAIL tracked_symlink_secret_blob_passed"
    exit 1
fi
if [ "$hook_rc" -ne 1 ] || ! grep -Eq 'leaks found: [1-9][0-9]*' "$scratch/run.out"; then
    echo "FAIL tracked_symlink_missing_detector_finding"
    exit 1
fi
if grep -Fq "$aws_access_key_id" "$scratch/run.out" || grep -Fq "$aws_secret_access_key" "$scratch/run.out"; then
    echo "FAIL tracked_symlink_output_disclosed_value"
    exit 1
fi
echo "ok   tracked_symlink_secret_blob_rejected_with_clean_target"

path_rule_config() {
    cat >"$scratch/path-rule.toml" <<'EOF'
title = "Sentinel selected symlink fixture"
[[rules]]
id = "sentinel-symlink-path"
description = "Synthetic selected symlink marker"
regex = '''SENTINEL_SYMLINK_MARKER_[A-Z0-9]+'''
path = '''(^|/)matching-link$'''
EOF
}

path_rule_fixture() {
    new_repo "$1"
    path_rule_config
    link_path=$2
    link_text=$3
    printf 'clean\n' >"$repo/$link_text"
    ln -s "$link_text" "$repo/$link_path"
    git -C "$repo" add -- "$link_path"
    if [ "$(git -C "$repo" ls-files --stage -- "$link_path" | awk '{ print $1 }')" != 120000 ] ||
        [ "$(git -C "$repo" diff --cached --name-only)" != "$link_path" ]; then
        echo "FAIL path_rule_symlink_index_setup"
        return 1
    fi
    printf '%s' "$link_text" >"$scratch/expected-path-rule-blob"
    if ! git -C "$repo" show ":$link_path" >"$scratch/index-path-rule-blob" 2>/dev/null ||
        ! cmp -s "$scratch/expected-path-rule-blob" "$scratch/index-path-rule-blob"; then
        echo "FAIL path_rule_symlink_blob_setup"
        return 1
    fi
    printf 'clean\n' >"$scratch/expected-path-rule-target"
    if ! cmp -s "$scratch/expected-path-rule-target" "$repo/$link_path" 2>/dev/null; then
        echo "FAIL path_rule_symlink_target_setup"
        return 1
    fi
    verify_selected_object_id "$link_path"
}

capture_runner_git_state() {
    snapshot_prefix=$1
    git -C "$repo" ls-files --stage -z >"$scratch/$snapshot_prefix.entries"
    cp "$repo/.git/HEAD" "$scratch/$snapshot_prefix.head"
    git -C "$repo" rev-parse --verify HEAD >"$scratch/$snapshot_prefix.head_oid"
    git -C "$repo" for-each-ref --format='%(refname) %(objectname) %(symref)' >"$scratch/$snapshot_prefix.refs"
    cp "$repo/$link_path" "$scratch/$snapshot_prefix.worktree"
    LC_ALL=C find "$repo/$link_path" -prune -exec ls -ld {} \; | cut -c1-10 >"$scratch/$snapshot_prefix.mode"
    if [ -L "$repo/$link_path" ]; then
        readlink "$repo/$link_path" >"$scratch/$snapshot_prefix.kind"
    elif [ -x "$repo/$link_path" ]; then
        printf 'executable\n' >"$scratch/$snapshot_prefix.kind"
    else
        printf 'nonexecutable\n' >"$scratch/$snapshot_prefix.kind"
    fi
    git -C "$repo" check-attr -z --all -- "$link_path" >"$scratch/$snapshot_prefix.attributes"
    if [ -e "$repo/.gitattributes" ]; then
        printf 'present\n' >"$scratch/$snapshot_prefix.attribute_state"
        cp "$repo/.gitattributes" "$scratch/$snapshot_prefix.attribute_file"
    else
        printf 'absent\n' >"$scratch/$snapshot_prefix.attribute_state"
        : >"$scratch/$snapshot_prefix.attribute_file"
    fi
    git -C "$repo" cat-file --batch-all-objects --batch-check='%(objectname) %(objecttype) %(objectsize)' >"$scratch/$snapshot_prefix.objects.unsorted"
    LC_ALL=C sort "$scratch/$snapshot_prefix.objects.unsorted" >"$scratch/$snapshot_prefix.objects"
}

assert_runner_git_state_preserved() {
    for component in entries head head_oid refs worktree mode kind attributes attribute_state attribute_file objects; do
        if ! cmp -s "$scratch/runner_before.$component" "$scratch/runner_after.$component"; then
            echo "FAIL runner_changed_$component"
            return 1
        fi
    done
}

path_rule_hook() {
    case_name=$1
    expected=$2
    inventory=$3
    capture_runner_git_state runner_before
    hook_rc=0
    if [ "$inventory" = all ]; then
        (cd "$repo" && GITLEAKS_CONFIG="$scratch/path-rule.toml" "$prek_bin" run gitleaks --all-files >"$scratch/run.out" 2>&1) || hook_rc=$?
    else
        (cd "$repo" && GITLEAKS_CONFIG="$scratch/path-rule.toml" "$prek_bin" run gitleaks >"$scratch/run.out" 2>&1) || hook_rc=$?
    fi
    capture_runner_git_state runner_after
    assert_runner_git_state_preserved
    if grep -Fq "$path_rule_marker" "$scratch/run.out"; then
        echo "FAIL ${case_name}_marker_disclosed"
        return 1
    fi
    if [ "$expected" = pass ]; then
        if [ "$hook_rc" -ne 0 ]; then
            echo "FAIL ${case_name}_rejected"
            return 1
        fi
        if grep -Eq 'Skipped|no files to check' "$scratch/run.out" || ! grep -Eq 'gitleaks.*Passed' "$scratch/run.out"; then
            echo "FAIL ${case_name}_hook_not_run"
            return 1
        fi
    elif [ "$hook_rc" -ne 1 ] || ! grep -Eq 'leaks found: [1-9][0-9]*' "$scratch/run.out"; then
        echo "FAIL ${case_name}_missing_detector_finding"
        return 1
    fi
}

capture_clean_git_state() {
    snapshot_prefix=$1
    git -C "$repo" ls-files --stage -z >"$scratch/$snapshot_prefix.entries"
    cp "$repo/.git/HEAD" "$scratch/$snapshot_prefix.head"
    git -C "$repo" rev-parse --verify HEAD >"$scratch/$snapshot_prefix.head_oid"
    git -C "$repo" for-each-ref --format='%(refname) %(objectname) %(symref)' >"$scratch/$snapshot_prefix.refs"
    readlink "$repo/$link_path" >"$scratch/$snapshot_prefix.link"
    git -C "$repo" cat-file --batch-all-objects --batch-check='%(objectname) %(objecttype) %(objectsize)' >"$scratch/$snapshot_prefix.objects.unsorted"
    LC_ALL=C sort "$scratch/$snapshot_prefix.objects.unsorted" >"$scratch/$snapshot_prefix.objects"
}

assert_clean_git_state_preserved() {
    for component in entries head head_oid refs link objects; do
        if ! cmp -s "$scratch/before.$component" "$scratch/after.$component"; then
            echo "FAIL clean_all_files_changed_$component"
            return 1
        fi
    done
}

path_rule_nonmatching_staged_case() {
    path_rule_marker=$(printf '%s%s' 'SENTINEL_SYMLINK_' 'MARKER_A1B2C3D4E5F6G7H8I9J0')
    path_rule_fixture path_nonmatching_staged other-link "$path_rule_marker"
    path_rule_hook path_nonmatching_staged pass staged
    echo "ok   path_nonmatching_staged_symlink_accepted"
}

path_rule_matching_staged_case() {
    path_rule_marker=$(printf '%s%s' 'SENTINEL_SYMLINK_' 'MARKER_A1B2C3D4E5F6G7H8I9J0')
    path_rule_fixture path_matching_staged matching-link "$path_rule_marker"
    path_rule_hook path_matching_staged fail staged
    echo "ok   path_matching_staged_symlink_blob_rejected"
}

path_rule_clean_all_files_case() {
    path_rule_marker=$(printf '%s%s' 'SENTINEL_SYMLINK_' 'MARKER_A1B2C3D4E5F6G7H8I9J0')
    path_rule_fixture path_clean_all_files matching-link clean-target
    git -C "$repo" commit -qm selected_clean_link
    if ! git -C "$repo" diff --cached --quiet; then
        echo "FAIL clean_all_files_has_staged_diff"
        return 1
    fi
    capture_clean_git_state before
    path_rule_hook path_clean_all_files pass all
    capture_clean_git_state after
    assert_clean_git_state_preserved
    echo "ok   committed_clean_symlink_all_files_accepted_and_git_state_preserved"
}

path_rule_matching_all_files_case() {
    path_rule_marker=$(printf '%s%s' 'SENTINEL_SYMLINK_' 'MARKER_A1B2C3D4E5F6G7H8I9J0')
    path_rule_fixture path_matching_all_files matching-link "$path_rule_marker"
    git -C "$repo" commit -qm selected_matching_link
    if ! git -C "$repo" diff --cached --quiet; then
        echo "FAIL matching_all_files_has_staged_diff"
        return 1
    fi
    path_rule_hook path_matching_all_files fail all
    echo "ok   committed_matching_symlink_all_files_blob_rejected"
}

path_rule_regular_fixture() {
    new_repo "$1"
    path_rule_config
    link_path=$2
    printf '%s' "$path_rule_marker" >"$repo/$link_path"
    git -C "$repo" add -- "$link_path"
    if [ "$(git -C "$repo" ls-files --stage -- "$link_path" | awk '{ print $1 }')" != 100644 ] ||
        [ "$(git -C "$repo" diff --cached --name-only)" != "$link_path" ]; then
        echo "FAIL path_rule_regular_index_setup"
        return 1
    fi
    printf '%s' "$path_rule_marker" >"$scratch/expected-path-rule-blob"
    if ! git -C "$repo" show ":$link_path" >"$scratch/index-path-rule-blob" 2>/dev/null ||
        ! cmp -s "$scratch/expected-path-rule-blob" "$scratch/index-path-rule-blob"; then
        echo "FAIL path_rule_regular_blob_setup"
        return 1
    fi
    verify_selected_object_id "$link_path"
}

path_rule_regular_matching_case() {
    path_rule_marker=$(printf '%s%s' 'SENTINEL_SYMLINK_' 'MARKER_A1B2C3D4E5F6G7H8I9J0')
    path_rule_regular_fixture path_regular_matching matching-link
    path_rule_hook path_regular_matching fail staged
    echo "ok   path_matching_regular_file_control_rejected"
}

path_rule_regular_nonmatching_case() {
    path_rule_marker=$(printf '%s%s' 'SENTINEL_SYMLINK_' 'MARKER_A1B2C3D4E5F6G7H8I9J0')
    path_rule_regular_fixture path_regular_nonmatching other-link
    path_rule_hook path_regular_nonmatching pass staged
    echo "ok   path_nonmatching_regular_file_control_accepted"
}

regular_versions_fixture() {
    new_repo "$1"
    path_rule_config
    path_rule_marker=$(printf '%s%s' 'SENTINEL_SYMLINK_' 'MARKER_A1B2C3D4E5F6G7H8I9J0')
    link_path=matching-link
    if [ "$4" = binary ]; then
        printf 'matching-link -diff\n' >"$repo/.gitattributes"
        git -C "$repo" add .gitattributes
        git -C "$repo" commit -qm fixture_binary_attribute
        if [ "$(git -C "$repo" check-attr diff -- matching-link)" != 'matching-link: diff: unset' ]; then
            echo "FAIL regular_binary_attribute_setup"
            return 1
        fi
    fi
    if [ "$2" = marker ]; then
        printf '%s' "$path_rule_marker" >"$scratch/expected-regular-index"
    else
        printf 'clean\n' >"$scratch/expected-regular-index"
    fi
    cp "$scratch/expected-regular-index" "$repo/matching-link"
    regular_mode=${5:-100644}
    case $regular_mode in
        100644) chmod 644 "$repo/matching-link" ;;
        100755) chmod 755 "$repo/matching-link" ;;
        *)
            echo "FAIL unsupported_regular_fixture_mode"
            return 1
            ;;
    esac
    git -C "$repo" add -- matching-link
    if [ "$(git -C "$repo" ls-files --stage -- matching-link | awk '{ print $1 }')" != "$regular_mode" ] ||
        [ "$(git -C "$repo" diff --cached --name-only)" != matching-link ]; then
        echo "FAIL regular_versions_index_setup"
        return 1
    fi
    verify_selected_object_id matching-link
    if ! git -C "$repo" show :matching-link >"$scratch/actual-regular-index" 2>/dev/null ||
        ! cmp -s "$scratch/expected-regular-index" "$scratch/actual-regular-index"; then
        echo "FAIL regular_versions_index_blob_setup"
        return 1
    fi
    if [ "$3" = marker ]; then
        printf '%s' "$path_rule_marker" >"$scratch/expected-regular-worktree"
    else
        printf 'clean\n' >"$scratch/expected-regular-worktree"
    fi
    cp "$scratch/expected-regular-worktree" "$repo/matching-link"
    if ! cmp -s "$scratch/expected-regular-worktree" "$repo/matching-link"; then
        echo "FAIL regular_versions_worktree_setup"
        return 1
    fi
}

capture_regular_git_state() {
    snapshot_prefix=$1
    git -C "$repo" ls-files --stage -z >"$scratch/$snapshot_prefix.entries"
    cp "$repo/.git/HEAD" "$scratch/$snapshot_prefix.head"
    git -C "$repo" rev-parse --verify HEAD >"$scratch/$snapshot_prefix.head_oid"
    git -C "$repo" for-each-ref --format='%(refname) %(objectname) %(symref)' >"$scratch/$snapshot_prefix.refs"
    cp "$repo/matching-link" "$scratch/$snapshot_prefix.worktree"
    if [ -x "$repo/matching-link" ]; then
        printf 'executable\n' >"$scratch/$snapshot_prefix.executable"
    else
        printf 'nonexecutable\n' >"$scratch/$snapshot_prefix.executable"
    fi
    git -C "$repo" check-attr diff -- matching-link >"$scratch/$snapshot_prefix.effective_attributes"
    if [ -e "$repo/.gitattributes" ]; then
        printf 'present\n' >"$scratch/$snapshot_prefix.attribute_state"
        cp "$repo/.gitattributes" "$scratch/$snapshot_prefix.attributes"
    else
        printf 'absent\n' >"$scratch/$snapshot_prefix.attribute_state"
        : >"$scratch/$snapshot_prefix.attributes"
    fi
    git -C "$repo" cat-file --batch-all-objects --batch-check='%(objectname) %(objecttype) %(objectsize)' >"$scratch/$snapshot_prefix.objects.unsorted"
    LC_ALL=C sort "$scratch/$snapshot_prefix.objects.unsorted" >"$scratch/$snapshot_prefix.objects"
}

assert_regular_git_state_preserved() {
    for component in entries head head_oid refs worktree executable effective_attributes attribute_state attributes objects; do
        if ! cmp -s "$scratch/before.$component" "$scratch/after.$component"; then
            echo "FAIL regular_all_files_changed_$component"
            return 1
        fi
    done
}

regular_versions_all_files() {
    regular_versions_fixture "$1" "$2" "$3" "$4" "${6:-100644}"
    capture_regular_git_state before
    path_rule_hook "$1" "$5" all
    capture_regular_git_state after
    assert_regular_git_state_preserved
}

regular_index_secret_all_files_case() {
    regular_versions_all_files regular_index_secret_all_files marker clean text fail
    echo "ok   regular_index_secret_with_clean_worktree_all_files_rejected"
}

regular_worktree_secret_all_files_case() {
    regular_versions_all_files regular_worktree_secret_all_files clean marker text fail
    echo "ok   regular_worktree_secret_with_clean_index_all_files_rejected"
}

regular_both_clean_all_files_case() {
    regular_versions_all_files regular_both_clean_all_files clean clean text pass
    echo "ok   regular_clean_index_and_worktree_all_files_accepted"
}

regular_binary_index_secret_all_files_case() {
    regular_versions_all_files regular_binary_index_secret_all_files marker clean binary fail
    echo "ok   regular_binary_attribute_index_secret_all_files_rejected"
}

regular_binary_clean_all_files_case() {
    regular_versions_all_files regular_binary_clean_all_files clean clean binary pass
    echo "ok   regular_binary_attribute_clean_all_files_accepted"
}

regular_executable_binary_index_secret_all_files_case() {
    regular_versions_all_files regular_executable_binary_index_secret_all_files marker clean binary fail 100755
    echo "ok   executable_binary_attribute_index_secret_all_files_rejected"
}

regular_executable_binary_clean_all_files_case() {
    regular_versions_all_files regular_executable_binary_clean_all_files clean clean binary pass 100755
    echo "ok   executable_binary_attribute_clean_all_files_accepted"
}

direct_helper_index_case() {
    direct_case=$1
    direct_expected=$5
    regular_versions_fixture "$1" "$2" clean "$3" "$4"
    cp "$repo/.git/index" "$scratch/direct-before.index"
    mkdir "$scratch/direct-tmp"
    direct_rc=0
    (cd "$repo" && TMPDIR="$scratch/direct-tmp" GITLEAKS_CONFIG="$scratch/path-rule.toml" sh hooks/gitleaks.sh matching-link >"$scratch/direct.out" 2>&1) || direct_rc=$?
    if ! cmp -s "$scratch/direct-before.index" "$repo/.git/index"; then
        echo "FAIL ${direct_case}_changed_index_bytes"
        return 1
    fi
    if [ -n "$(find "$scratch/direct-tmp" -mindepth 1 -print)" ]; then
        echo "FAIL ${direct_case}_private_artifacts_remain"
        return 1
    fi
    rmdir "$scratch/direct-tmp"
    if grep -Fq "$path_rule_marker" "$scratch/direct.out"; then
        echo "FAIL ${direct_case}_marker_disclosed"
        return 1
    fi
    if [ "$direct_expected" = pass ]; then
        if [ "$direct_rc" -ne 0 ]; then
            echo "FAIL ${direct_case}_rejected"
            return 1
        fi
    elif [ "$direct_rc" -ne 1 ] || ! grep -Eq 'leaks found: [1-9][0-9]*' "$scratch/direct.out"; then
        echo "FAIL ${direct_case}_missing_detector_finding"
        return 1
    fi
    echo "ok   ${direct_case}_index_bytes_preserved"
}

direct_regular_clean_case() {
    direct_helper_index_case direct_regular_clean clean text 100644 pass
}

direct_executable_binary_clean_case() {
    direct_helper_index_case direct_executable_binary_clean clean binary 100755 pass
}

direct_regular_finding_case() {
    direct_helper_index_case direct_regular_finding marker text 100644 fail
}

protocol_private_marker=SYNTHETIC_PRIVATE_PROTOCOL_DETAIL

protocol_not_disclosed() {
    private_probe=$protocol_private_marker
    while [ "${#private_probe}" -ge 8 ]; do
        private_fragment=$(printf '%.8s' "$private_probe")
        if grep -Fq "$private_fragment" "$scratch/protocol.out" || grep -Fq "$private_fragment" "$scratch/protocol.err"; then
            echo "FAIL protocol_detail_disclosed"
            return 1
        fi
        private_probe=${private_probe#?}
    done
}

trace_protocol_case() {
    protocol_name=$1
    protocol_want=$2
    protocol_events=$4
    protocol_rc=0
    printf '%s\n' "$3" | "$jq_bin" -nRc --argjson expected "$trace_expected" \
        -f "$root/hooks/gitleaks-trace2.jq" >"$scratch/protocol.out" 2>"$scratch/protocol.err" || protocol_rc=$?
    protocol_not_disclosed
    if [ "$protocol_rc" -ne 0 ] || ! "$jq_bin" -e --argjson want "$protocol_want" --argjson events "$protocol_events" \
        ".valid == \$want and .events == \$events and
         (keys | sort) == [\"atexit_code\", \"atexits\", \"events\", \"exit_code\", \"exits\", \"matching_starts\", \"sid_count\", \"starts\", \"valid\"]" \
        "$scratch/protocol.out" >/dev/null 2>&1; then
        echo "FAIL $protocol_name"
        return 1
    fi
    echo "ok   $protocol_name"
}

trace_protocol_cases() {
    trace_expected='["git","-C","/synthetic/root","diff","-U0","--no-ext-diff","--staged","."]'
    trace_start='{"event":"start","sid":"synthetic-session","argv":["git","-C","/synthetic/root","diff","-U0","--no-ext-diff","--staged","."]}'
    trace_exit='{"event":"exit","sid":"synthetic-session","code":0}'
    trace_atexit='{"event":"atexit","sid":"synthetic-session","code":0}'
    trace_shutdown_data='{"event":"data_json","sid":"synthetic-session","value":{"private":"SYNTHETIC_PRIVATE_PROTOCOL_DETAIL"}}'
    trace_protocol_case trace_exact_success true "$(printf '%s\n' "$trace_start" "$trace_exit" "$trace_atexit")" 3
    trace_protocol_case trace_nonzero_exit false "$(printf '%s\n' "$trace_start" '{"event":"exit","sid":"synthetic-session","code":128}' '{"event":"atexit","sid":"synthetic-session","code":128}')" 3
    trace_protocol_case trace_missing_completion false "$(printf '%s\n' "$trace_start" "$trace_exit")" 2
    trace_protocol_case trace_malformed_early_line_drains false "$(printf '%s\n' '{"event":' "$trace_start" "$trace_exit" "$trace_atexit")" 4
    trace_protocol_case trace_wrong_executable false "$(printf '%s\n' '{"event":"start","sid":"synthetic-session","argv":["/other/git","-C","/synthetic/root","diff","-U0","--no-ext-diff","--staged","."]}' "$trace_exit" "$trace_atexit")" 3
    trace_protocol_case trace_wrong_diff_arguments false "$(printf '%s\n' '{"event":"start","sid":"synthetic-session","argv":["git","-C","/synthetic/root","diff","-U1","--no-ext-diff","--staged","."]}' "$trace_exit" "$trace_atexit")" 3
    trace_protocol_case trace_wrong_root false "$(printf '%s\n' '{"event":"start","sid":"synthetic-session","argv":["git","-C","/other/root","diff","-U0","--no-ext-diff","--staged","."]}' "$trace_exit" "$trace_atexit")" 3
    trace_protocol_case trace_duplicate_start false "$(printf '%s\n' "$trace_start" "$trace_start" "$trace_exit" "$trace_atexit")" 4
    trace_protocol_case trace_extra_session false "$(printf '%s\n' "$trace_start" '{"event":"cmd_name","sid":"other-session","name":"diff"}' "$trace_exit" "$trace_atexit")" 4
    trace_protocol_case trace_signal false "$(printf '%s\n' "$trace_start" '{"event":"signal","sid":"synthetic-session","signo":15}' "$trace_exit" "$trace_atexit")" 4
    trace_protocol_case trace_error false "$(printf '%s\n' "$trace_start" '{"event":"error","sid":"synthetic-session","msg":"SYNTHETIC_PRIVATE_PROTOCOL_DETAIL"}' "$trace_exit" "$trace_atexit")" 4
    trace_protocol_case trace_unmatched_completion false "$(printf '%s\n' "$trace_exit" "$trace_atexit")" 2
    trace_protocol_case trace_duplicate_exit false "$(printf '%s\n' "$trace_start" "$trace_exit" "$trace_exit" "$trace_atexit")" 4
    trace_protocol_case trace_wrong_code_type false "$(printf '%s\n' "$trace_start" '{"event":"exit","sid":"synthetic-session","code":"0"}' "$trace_atexit")" 3
    trace_protocol_case trace_unknown_event false "$(printf '%s\n' "$trace_start" '{"event":"unexpected","sid":"synthetic-session"}' "$trace_exit" "$trace_atexit")" 4
    trace_protocol_case trace_metadata_before_start false "$(printf '%s\n' "$trace_shutdown_data" "$trace_start" "$trace_exit" "$trace_atexit")" 4
    trace_protocol_case trace_metadata_after_atexit false "$(printf '%s\n' "$trace_start" "$trace_exit" "$trace_atexit" "$trace_shutdown_data")" 4
    trace_protocol_case trace_other_event_after_exit false "$(printf '%s\n' "$trace_start" "$trace_exit" '{"event":"cmd_name","sid":"synthetic-session","name":"diff"}' "$trace_atexit")" 4
    trace_protocol_case trace_shutdown_metadata true "$(printf '%s\n' "$trace_start" "$trace_exit" "$trace_shutdown_data" "$trace_atexit")" 4
}

stderr_protocol_case() {
    protocol_name=$1
    protocol_want=$2
    protocol_mode=$3
    protocol_lines=$5
    protocol_rc=0
    printf '%s\n' "$4" | "$jq_bin" -nRc --arg mode "$protocol_mode" \
        -f "$root/hooks/gitleaks-stderr.jq" >"$scratch/protocol.out" 2>"$scratch/protocol.err" || protocol_rc=$?
    protocol_not_disclosed
    if [ "$protocol_rc" -ne 0 ] || ! "$jq_bin" -e --argjson want "$protocol_want" --argjson lines "$protocol_lines" \
        ".valid == \$want and .lines == \$lines and
         (keys | sort) == [\"clean\", \"commits\", \"complete\", \"errors\", \"finding_count\", \"lines\", \"partials\", \"progress\", \"unknown\", \"valid\"]" \
        "$scratch/protocol.out" >/dev/null 2>&1; then
        echo "FAIL $protocol_name"
        return 1
    fi
    echo "ok   $protocol_name"
}

stderr_protocol_cases() {
    console_commits='1:23PM INF 1 commits scanned.'
    console_progress='1:23PM INF scanned ~12 bytes (12 bytes) in 1ms'
    console_clean='1:23PM INF no leaks found'
    console_finding='1:23PM WRN leaks found: 1'
    stderr_protocol_case stderr_git_clean true git "$(printf '%s\n' "$console_commits" "$console_progress" "$console_clean")" 3
    stderr_protocol_case stderr_git_finding true git "$(printf '%s\n' "$console_commits" "$console_progress" "$console_finding")" 3
    stderr_protocol_case stderr_dir_clean true dir "$(printf '%s\n' "$console_progress" "$console_clean")" 2
    stderr_protocol_case stderr_dir_finding true dir "$(printf '%s\n' "$console_progress" "$console_finding")" 2
    stderr_protocol_case stderr_zero_bytes true dir "$(printf '%s\n' '1:23PM INF scanned ~0 bytes (0) in 0s' "$console_clean")" 2
    stderr_protocol_case stderr_decimal_kilobytes_slow_duration true git "$(printf '%s\n' "$console_commits" '1:23PM INF scanned ~1234 bytes (1.23 KB) in 1m2.3s' "$console_clean")" 3
    for duration in 1ns 1.2µs 1.234ms 1.2s 1h2m3.4s; do
        stderr_protocol_case "stderr_duration_$duration" true dir "$(printf '1:23PM INF scanned ~12 bytes (12 bytes) in %s\n%s\n' "$duration" "$console_clean")" 2
    done
    stderr_protocol_case stderr_error_then_clean false git "$(printf '%s\n' '1:23PM ERR SYNTHETIC_PRIVATE_PROTOCOL_DETAIL' "$console_commits" "$console_progress" "$console_clean")" 4
    stderr_protocol_case stderr_partial false git "$(printf '%s\n' "$console_commits" '1:23PM WRN partial scan completed in 1ms' '1:23PM WRN no leaks found in partial scan')" 3
    stderr_protocol_case stderr_missing_summary false git "$(printf '%s\n' "$console_commits" "$console_progress")" 2
    stderr_protocol_case stderr_duplicate_summary false dir "$(printf '%s\n' "$console_progress" "$console_clean" "$console_clean")" 3
    stderr_protocol_case stderr_contradictory_summary false dir "$(printf '%s\n' "$console_progress" "$console_clean" "$console_finding")" 3
    stderr_protocol_case stderr_unknown_early_line_drains false git "$(printf '%s\n' 'SYNTHETIC_PRIVATE_PROTOCOL_DETAIL' "$console_commits" "$console_progress" "$console_clean")" 4
    stderr_protocol_case stderr_git_missing_commit_count false git "$(printf '%s\n' "$console_progress" "$console_clean")" 2
    stderr_protocol_case stderr_dir_unexpected_commit_count false dir "$(printf '%s\n' "$console_commits" "$console_progress" "$console_clean")" 3
    stderr_protocol_case stderr_duplicate_progress false dir "$(printf '%s\n' "$console_progress" "$console_progress" "$console_clean")" 3
    stderr_protocol_case stderr_summary_before_progress false dir "$(printf '%s\n' "$console_clean" "$console_progress")" 2
}

assert_hook_private_output() {
    private_probe=$path_rule_marker
    while [ "${#private_probe}" -ge 8 ]; do
        private_fragment=$(printf '%.8s' "$private_probe")
        if grep -Fq "$private_fragment" "$scratch/run.out"; then
            echo "FAIL hook_private_detail_disclosed"
            return 1
        fi
        private_probe=${private_probe#?}
    done
}

assert_hook_temporary_cleanup() {
    if [ -n "$(find "$hook_temp" -mindepth 1 -print -quit)" ]; then
        echo "FAIL hook_temporary_metadata_remains"
        return 1
    fi
}

missing_selected_object_case() {
    regular_versions_fixture missing_selected_object marker clean text
    selected_oid=$(git -C "$repo" ls-files --format='%(objectname)' -- matching-link)
    object_prefix=$(printf '%.2s' "$selected_oid")
    object_suffix=${selected_oid#??}
    object_file=$repo/.git/objects/$object_prefix/$object_suffix
    if [ ! -f "$object_file" ]; then
        echo "FAIL missing_object_fixture_not_loose"
        return 1
    fi
    rm "$object_file"
    if git -C "$repo" cat-file -e "$selected_oid" 2>/dev/null; then
        echo "FAIL missing_object_fixture_still_readable"
        return 1
    fi
    hook_temp=$scratch/missing-object-hook-temp
    mkdir "$hook_temp"
    hook_rc=0
    (cd "$repo" && TMPDIR="$hook_temp" GITLEAKS_CONFIG="$scratch/path-rule.toml" \
        "$prek_bin" run gitleaks --all-files >"$scratch/run.out" 2>&1) || hook_rc=$?
    assert_hook_private_output
    assert_hook_temporary_cleanup
    if [ "$hook_rc" -ne 1 ] || ! grep -Fq 'selected Git producer failed (exit 128)' "$scratch/run.out"; then
        echo "FAIL missing_object_producer_failure_not_verified"
        return 1
    fi
    echo "ok   missing_selected_object_producer_failure_rejected_and_cleaned"
}

unreadable_filter_case() {
    regular_versions_fixture unreadable_filter clean clean text
    chmod 000 "$repo/hooks/gitleaks-trace2.jq"
    if [ -r "$repo/hooks/gitleaks-trace2.jq" ]; then
        chmod 644 "$repo/hooks/gitleaks-trace2.jq"
        echo "FAIL unreadable_filter_fault_unavailable"
        return 1
    fi
    hook_temp=$scratch/unreadable-filter-hook-temp
    mkdir "$hook_temp"
    hook_rc=0
    (cd "$repo" && TMPDIR="$hook_temp" GITLEAKS_CONFIG="$scratch/path-rule.toml" \
        "$prek_bin" run gitleaks --all-files >"$scratch/run.out" 2>&1) || hook_rc=$?
    chmod 644 "$repo/hooks/gitleaks-trace2.jq"
    assert_hook_private_output
    assert_hook_temporary_cleanup
    if [ "$hook_rc" -ne 1 ] || ! grep -Fq 'protocol filter is unavailable' "$scratch/run.out"; then
        echo "FAIL unreadable_filter_was_not_rejected"
        return 1
    fi
    echo "ok   unreadable_real_filter_dependency_rejected_and_cleaned"
}

unusable_temporary_directory_case() {
    regular_versions_fixture unusable_temporary_directory clean clean text
    hook_temp=$scratch/unusable-hook-temp
    printf 'not a directory\n' >"$hook_temp"
    hook_rc=0
    (cd "$repo" && TMPDIR="$hook_temp" GITLEAKS_CONFIG="$scratch/path-rule.toml" \
        "$prek_bin" run gitleaks --all-files >"$scratch/run.out" 2>&1) || hook_rc=$?
    assert_hook_private_output
    if [ "$hook_rc" -ne 1 ] || ! grep -Fq 'private metadata creation failed' "$scratch/run.out"; then
        echo "FAIL unusable_temporary_directory_was_not_rejected"
        return 1
    fi
    if [ "$(cat "$hook_temp")" != 'not a directory' ]; then
        echo "FAIL unusable_temporary_directory_fixture_changed"
        return 1
    fi
    echo "ok   unusable_temporary_directory_rejected_without_raw_artifacts"
}

path_rule_regular_matching_case
path_rule_regular_nonmatching_case
path_rule_nonmatching_staged_case
path_rule_matching_staged_case
path_rule_clean_all_files_case
path_rule_matching_all_files_case
regular_both_clean_all_files_case
regular_worktree_secret_all_files_case
regular_index_secret_all_files_case
regular_binary_clean_all_files_case
regular_binary_index_secret_all_files_case
regular_executable_binary_clean_all_files_case
regular_executable_binary_index_secret_all_files_case
trace_protocol_cases
stderr_protocol_cases
missing_selected_object_case
unreadable_filter_case
unusable_temporary_directory_case

direct_regular_clean_case
direct_executable_binary_clean_case
direct_regular_finding_case
