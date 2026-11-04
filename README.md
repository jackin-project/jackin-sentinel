# jackin-sentinel

jackin-sentinel is the verification role of jackin. It proves that jackin works from the host to the Codex process in the sandbox. Codex is the only agent.

`xtask e2e` in the jackin repository runs the sentinel journey (J00 to J17). The steps are in the Sentinel journey table of `rewrite/PLAN.md` in jackin. The journey compares what the host sees with what the probe in the sandbox reports.

Jackin builds the image and creates the sandbox. This repository does not publish an image. The role holds no secret.

## What the image contains

The `Dockerfile` ends in a stage that starts `FROM construct`. One `RUN` layer installs `jackin-sentinel-probe` at `/usr/local/bin/jackin-sentinel-probe`, owned by root. The layer prints its own lines, so the build output shows the sentinel layer.

Jackin adds Codex, `jackin-start`, and the two hooks when it derives the final image (decisions D05 and D11).

The probe is a POSIX `sh` script that needs `jq`. The construct image has `jq`.

## Egress policy

`policy.yaml` is a native OpenShell policy that jackin sends without change.

- The role has no network rule. The sandbox cannot reach any host that the role names, because the role names none.
- The only egress is the rule that OpenShell adds for the Codex provider hosts.
- `/bin`, `/sbin`, `/usr`, `/lib`, `/etc`, `/proc`, `/dev/urandom`, and `/var/log` are read-only. `/sandbox`, `/tmp`, and `/dev/null` are writable.
- `landlock.compatibility` is `hard_requirement`, so the sandbox fails to start where Landlock is unavailable.

The Docker capability is off (`[docker] enabled = false`).

## Environment and hooks

The manifest has one `[env]` entry:

| Name | Default | Prompt |
|---|---|---|
| `SENTINEL_FAIL_PREFLIGHT` | `0` | Fail the preflight hook (1) or pass it (0): |

Jackin runs each hook through exec as the user `sandbox`, in `/sandbox/project`, with the `[env]` values. Each hook appends one line to a log in `/sandbox/.sentinel`:

| Hook | Runs | Log line |
|---|---|---|
| `hooks/setup.sh` | Once for each launch | `setup flag=<value>` in `setup.log` |
| `hooks/preflight.sh` | Before each Codex start | `preflight ok flag=<value>` in `preflight.log` |
| `hooks/preflight.sh` | Before each Codex start, when `SENTINEL_FAIL_PREFLIGHT` is `1` | `preflight fail flag=1` in `preflight.log`, then exit code 17 |

A non-zero exit stops the launch. The sandbox stays `Ready`. Each log line is one execution. The probe counts them, so a hook that runs twice is a visible failure. The hook files in the image are owned by root. The agent cannot change them.

## Use the role

Build jackin in the jackin repository. Check the role from this directory with that binary:

```sh
jackin role check .
```

Register the role, then load it with a project directory:

```sh
jackin role add sentinel .
jackin load sentinel <project>
```

To make the preflight hook fail, pass the variable:

```sh
jackin load sentinel <project> --env SENTINEL_FAIL_PREFLIGHT=1
```

The launch stops with the hook error. Load again with the same launch ID and without the variable to start Codex (journey step J06).

## The probe

`jackin-sentinel-probe` prints one JSON object on stdout. `rewrite/probe-schema.json` in jackin defines it. `xtask e2e` reads it, so change the probe, the schema, and `crates/xtask/src/e2e/` in one task.

```text
jackin-sentinel-probe [--host] [--docker on|off] [--engine HOST:PORT] [--only J04,J05,...]
jackin-sentinel-probe --version
```

| Flag | Meaning |
|---|---|
| `--host` | Dry run. Every selected step is `SKIP` with `facts: null`. Use it to check the output shape outside a sandbox. |
| `--docker on\|off` | The Docker capability that the caller expects. The default is `off`. `on` runs J15 and skips J16. `off` skips J15 and runs J16. |
| `--engine HOST:PORT` | The engine endpoint that J16 tries to reach. Without it, the connection check of J16 is `SKIP`. |
| `--only` | A comma-separated list of steps. An unselected step is absent from the report. |

Without `--host`, the probe runs only on Linux as the user `sandbox` with `/sandbox` present. Otherwise it exits 66. The probe exits 0 whenever it printed a report, even when a step is `FAIL`. It exits 64 for a usage error and 69 when `jq` is missing.

Each step has a `result` (`PASS`, `FAIL`, or `SKIP`), a `reason`, its `checks`, and typed `facts`. A step that needs a credential or a capability that the sandbox lacks is `SKIP`. It is never `PASS`.

| Step | What the probe reports |
|---|---|
| J00 | The Codex binary and the output of `codex --version`. |
| J04 | The user, uid, gid, whether `sudo` works, and whether a `docker` binary exists. |
| J05 | The sha256 digest of every regular file below `/sandbox/project`, outside `.git`. |
| J06 | The execution counts of the hooks, and the owner and mode of the installed hook files. |
| J07 | The main process, its Codex child, and the answer of a `codex exec` call. |
| J08 | Whether every credential variable and every token in `auth.json` is a placeholder, and which files hold a token-shaped string. The probe never prints a value. |
| J09 | The result of `curl` to a host outside the policy, to the metadata address, and to a Codex provider host. |
| J10 | Which file creations succeed under `/sandbox` and `/tmp` and which fail elsewhere. |
| J11 | The Codex process with its pid and start time, for a comparison before and after a detach. |
| J12 | The probe process, its controlling terminal, and whether it descends from the main process. |
| J13 | The git state of `/sandbox/project`: branches, tips, HEAD, cleanliness, and stash count. |
| J14 | A marker file, the boot id, and the hook counts, for a comparison after stop and start. |
| J15 | With `--docker on`: the Docker variables, the client certificates, the output of a `hello-world` container that the agent starts through the engine, and the engine id. |
| J16 | With `--docker off`: no `docker` binary, no `DOCKER_` variable, and no connection to the engine endpoint. |

J01, J02, J03, and J17 have no in-sandbox part. `xtask e2e` runs them on the host.

Run a dry run on any host that has `jq`:

```sh
probe/jackin-sentinel-probe --host | jq .
```

In a sandbox of this role, run `jackin shell <sandbox>` and then:

```sh
jackin-sentinel-probe | jq .
jackin-sentinel-probe --docker on --only J15 | jq .
```

J07 and J09 run `codex exec`, which needs a credential in the sandbox and takes up to four minutes. J15 pulls `hello-world` through the engine and takes up to five minutes.

## Docker capability

The capability is off in the manifest. Enable it for a launch with `docker = true` on the workspace (journey step J15). The engine is a dedicated external engine that the operator runs (decision D24). The agent can read the engine client key, and containers bypass the sandbox network policy.

## Repository checks

`mise run test` runs `prek run --all-files`: gitleaks, shellcheck, shfmt, hadolint, and the J08 cases of `probe/tests/j08.sh`.

`velnor` generates the CI workflows from `.velnor/config.toml`. Do not edit them by hand.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
