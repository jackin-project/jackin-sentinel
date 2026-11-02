# jackin-sentinel

jackin-sentinel is the verification role of jackin. It proves that jackin works from the host to the Codex process in the sandbox. Codex is the only agent.

`xtask e2e` in the jackin repository runs the sentinel journey (J00 to J17). The steps are in the Sentinel journey table of `rewrite/PLAN.md` in jackin. The journey compares what the host sees with what the probe in the sandbox reports.

## Files

| File | Purpose |
|---|---|
| `jackin.role.toml` | The role manifest (schema 1). It names the `Dockerfile`, the policy, the two hooks, and the one `[env]` entry. |
| `Dockerfile` | The final stage starts `FROM construct`. A `RUN` layer installs `jackin-sentinel-probe` at `/usr/local/bin/jackin-sentinel-probe`, so the build output shows the sentinel layer. |
| `policy.yaml` | A native OpenShell policy. Landlock is a hard requirement. Writes are allowed only under `/sandbox`, `/tmp`, and `/dev/null`. The role has no network rule. The only egress is the generated rule for the Codex provider hosts. |
| `hooks/setup.sh` | Appends one line to `/sandbox/.sentinel/setup.log`. |
| `hooks/preflight.sh` | Appends one line to `/sandbox/.sentinel/preflight.log`. It exits 17 when `SENTINEL_FAIL_PREFLIGHT` is `1`. |
| `probe/jackin-sentinel-probe` | The probe. A POSIX `sh` script that needs `jq`. |
| `probe/tests/j08.sh` | The offline cases of the J08 environment check: a copy of the probe runs against a scratch `/sandbox` and `/proc`. |

The role holds no secret. Jackin builds the image. This repository does not publish it.

## Check and load the role

The repository gate is `mise run test`. It runs `prek run --all-files`: gitleaks, shellcheck, shfmt, hadolint, and the J08 cases of `probe/tests/j08.sh`.

Build jackin in the jackin repository. The gate runs the binary `jackin/target/debug/jackin` from this directory:

```sh
jackin role check .
```

Register the role, then load it with a project directory as the second argument:

```sh
jackin role add sentinel .
jackin load sentinel <project>
jackin load sentinel <project> --env SENTINEL_FAIL_PREFLIGHT=1
```

With `SENTINEL_FAIL_PREFLIGHT=1` the preflight hook fails. The launch stops with the hook error and the sandbox stays `Ready`. Load again with the same launch ID and without the variable to start Codex (journey step J06).

## Hooks

Jackin runs the hooks through exec as the user `sandbox`, in `/sandbox/project`. Each hook writes to `/sandbox/.sentinel`:

| Log | Line | Written by |
|---|---|---|
| `setup.log` | `setup flag=<value>` | `hooks/setup.sh`, once for each launch |
| `preflight.log` | `preflight ok flag=<value>` | `hooks/preflight.sh`, before each Codex start |
| `preflight.log` | `preflight fail flag=1` | `hooks/preflight.sh`, when `SENTINEL_FAIL_PREFLIGHT` is `1` |

Each log line is one execution. The probe counts them, so a hook that runs twice is a visible failure. The hook files in the image are owned by root. The agent cannot change them.

## The probe

`jackin-sentinel-probe` prints one JSON object on stdout. `rewrite/probe-schema.json` in jackin defines it. Change the probe, the schema, and `crates/xtask/src/e2e/` in one orchestrator task.

```text
jackin-sentinel-probe [--host] [--docker on|off] [--engine HOST:PORT] [--only J04,J05,...]
jackin-sentinel-probe --version
```

| Flag | Meaning |
|---|---|
| `--host` | Dry mode. Nothing runs. Every selected step is `SKIP` and has `facts: null`. Use it to check the output shape outside a sandbox. |
| `--docker on\|off` | The Docker capability that the caller expects. `off` is the default. `on` runs J15 and skips J16. `off` skips J15 and runs J16. |
| `--engine HOST:PORT` | The engine endpoint that J16 tries to reach. Without it the connection check of J16 is `SKIP`. |
| `--only` | A comma-separated list of steps. An unselected step is absent from the report. |

Without `--host`, the probe refuses to run unless it is on Linux as the user `sandbox` with `/sandbox` present. It exits 66 otherwise. This guard keeps the J10 write checks off a host.

The probe reads other processes only through `/proc/PID/stat` and `/proc/PID/cmdline`. The sandbox denies `exe`, `fd`, and `environ` of a process outside the caller's own tree, even for the same uid.

The probe exits 0 whenever it printed a report, even when a step is `FAIL`. It exits 64 for a usage error, 66 outside a sandbox, and 69 when `jq` is missing.

### Steps

Each step has a `result` (`PASS`, `FAIL`, or `SKIP`), a `reason`, its `checks`, and typed `facts`. A step is `FAIL` when any check fails, otherwise `SKIP` when any check is skipped, otherwise `PASS`. A step that needs a credential or a capability that the sandbox lacks is `SKIP`. It is never `PASS`.

| Step | What the probe reports |
|---|---|
| J00 | The Codex binary at `/usr/local/bin/codex` and the output of `codex --version`. |
| J04 | The user, uid, gid, whether `sudo` works, and whether a `docker` binary exists. |
| J05 | The sha256 digest of every regular file below `/sandbox/project`, outside `.git`. |
| J06 | The execution counts of the hooks and the owner and mode of the installed hook files. |
| J07 | The main process (`jackin-start`), its Codex child, and the answer of `codex exec --skip-git-repo-check "Reply with the word ready"`. |
| J08 | Whether every credential variable and every token in `auth.json` is a placeholder, and the paths of files that hold a token-shaped string. The probe reads its own environment, the `/sandbox/.jackin/env-*` launch files, `auth.json`, and the files under `/sandbox`. The sandbox denies `/proc/PID/environ` of the main process and of Codex, so the probe reads the start record `/sandbox/.jackin/run/env-kinds`, which `jackin-start` writes with the names and kinds (placeholder, empty, other) of the credential variables of both environments and never a value. The environment check is PASS only with a fresh, valid record that covers both environments, FAIL for a variable of kind other or a malformed record, and SKIP when the record is absent, unreadable or stale, or Codex has not started. The agent runs as the same user and can rewrite the record, so a PASS shows the launch path of jackin, not a hostile agent. The probe never prints a value. |
| J09 | The result of `curl` to a host outside the policy, to the metadata address, and to a Codex provider host with the placeholder as the bearer value. |
| J10 | Which file creations succeed under `/sandbox` and `/tmp` and which fail elsewhere. |
| J11 | The Codex process with its pid and start time, for a comparison before and after a detach. |
| J12 | The probe process, its controlling terminal, and whether it descends from the main process. |
| J13 | The git state of `/sandbox/project`: branches, tips, HEAD, cleanliness, and stash count. |
| J14 | A marker file that the first run creates, the boot id, and the hook counts, for a comparison after stop and start. |
| J15 | With `--docker on`: the Docker variables, the client certificates, the output of `docker run --rm hello-world`, and the engine id. |
| J16 | With `--docker off`: no `docker` binary, no `DOCKER_` variable, and no connection to the engine endpoint. |

J01, J02, J03, and J17 have no in-sandbox part. `xtask e2e` runs them on the host.

### Run the probe

Dry run on any host, with `jq` installed:

```sh
probe/jackin-sentinel-probe --host | jq .
```

In a sandbox of this role, run `jackin shell <sandbox>` and then:

```sh
jackin-sentinel-probe | jq .
jackin-sentinel-probe --docker on --only J15 | jq .
jackin-sentinel-probe --engine host.openshell.internal:<port> --only J16 | jq .
```

J07 and J09 run `codex exec`, which needs a credential in the sandbox and takes up to four minutes. J15 pulls `hello-world` through the engine and takes up to five minutes.

## Docker capability

The capability is off in the manifest. Enable it for a launch with `docker = true` on the workspace (journey step J15). The engine is a dedicated external engine that the operator runs (decision D24). The agent can read the engine client key, and containers bypass the sandbox network policy.

## Rules

- Codex is the only agent.
- The role holds no secret.
- Code has no comments, except SPDX headers, shebang lines, and parser directives.
- CI workflows are generated by velnor from `.velnor/config.toml`. Do not edit them.
