# Support

super-status is a personal project, maintained by one person alongside other
work. **Issues and pull requests are handled on a best-effort basis** — that is
the policy, not an apology. An issue that sits unanswered for a while has not
been ignored and the project has not been abandoned; it is waiting its turn.

## Where to go

| What you have | Where it goes |
|---|---|
| The statusline renders nothing, or a segment is empty | Run `./doctor.sh` first — it checks the install wiring. Then `SUPER_STATUS_DEBUG=1 bash statusline.sh < payload.json 2>debug.log`, which names the reason a segment came out empty |
| A bug, with a reproducer | [Open an issue](https://github.com/orassayag/super-status/issues/new/choose) using the bug template. Attach the stdin JSON payload with anything private removed |
| A feature idea | [Open an issue](https://github.com/orassayag/super-status/issues/new/choose) using the feature template |
| A question about configuration | The [README](README.md) documents every config key with its default. If the answer is not there, that is itself worth an issue |
| A security vulnerability | **Not** a public issue — see [SECURITY.md](SECURITY.md) |
| A change you have already written | See [CONTRIBUTING.md](CONTRIBUTING.md) |

## What is supported

- **macOS and Linux** are exercised on every push by CI.
- **Windows via Git Bash** is run by a non-blocking CI job, so breakage there is
  visible but not guaranteed caught before release. Reports are welcome.
- Bash 3.2 and newer (the system bash on macOS is 3.2, and the script stays
  inside it deliberately).
- `jq` and `python3` are required; `tokei` and `jj` are optional and only
  needed by the segments that use them.

## What is not supported

- Forks and vendored copies. Reproduce it against a clean checkout first.
- Anything that needs a credential this project cannot see — the prepaid credit
  bar's Admin API figure is unavailable on individual accounts by Anthropic's
  design, not by a bug here.
