# Local CI

Bealach CI runs **locally only**. There is no GitHub Actions setup, no hosted
runner, and nothing is uploaded to a CI service: this project does not pay for
GitHub, and its checks do not need to.

## Run it

```sh
make ci        # every check, natively (macOS or Linux)
make ci-linux  # the same checks in a Linux container (OrbStack on macOS)
```

Or directly:

```sh
ci/check.sh              # everything
ci/check.sh links        # one check by name
ci/linux.sh              # containerised; --rebuild forces a fresh image
```

## What runs

| Check | What it proves |
|---|---|
| `links` | Every relative Markdown link resolves to a real file ([links.py](links.py)) |
| `local-ci-policy` | No GitHub Actions workflows have crept in — CI stays local-only |
| `harvest-go` | The staged Cairn contract tools (Go) pass their unit tests |
| `harvest-rust` | The staged engine-profile generator (Rust) passes against the pinned contract vectors |
| `mermaid` | The README architecture diagram renders (skipped unless `mmdc` is installed) |

The harvest checks point at the staged contracts in `harvest/contracts/`
(`CAIRN_CONTRACTS`); they validate the material to be migrated, not a shipped
product — nothing in `harvest/` is product code yet.

## Linux when you want it, never because you need it

Every check runs on macOS as-is. When a reproducible Linux environment is
wanted anyway — different libc, CI-parity with a future hardware build host —
use [linux.sh](linux.sh), which builds [Dockerfile](Dockerfile) and runs
`ci/check.sh` inside it. On macOS the Docker engine is expected to be
[OrbStack](https://orbstack.dev); any working `docker` CLI works elsewhere.

```sh
ci/linux.sh --rebuild    # fresh image
DOCKER=podman ci/linux.sh
```

## Adding a check

Add a `check_<name>` function to [check.sh](check.sh) and hook it into the
bottom. Keep it hermetic: no network calls, no hosted services, no secrets.
