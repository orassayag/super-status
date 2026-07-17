# Security

## Posture

super-status is a read-only statusline script. Its entire input surface is:

- the JSON payload Claude Code writes to its stdin,
- the session transcript JSONL file referenced by that payload,
- local git metadata (`git status`, `rev-parse`, `rev-list`, `diff --numstat`),
- `CLAUDE.md` (a single `subscription_start_date` key),
- its own config file at `~/.claude/super-status/config.json`.

It makes **one** outbound network call, and only in OpenRouter mode
(`ANTHROPIC_BASE_URL` contains `openrouter.ai` **and** `OPENROUTER_API_KEY` is
set): a `GET https://openrouter.ai/api/v1/credits` with that key as a bearer
token, cached for 60 seconds. No other mode touches the network. The API key
is never logged or written to disk.

## Caches

All caches live under `${XDG_CACHE_HOME:-$HOME/.cache}/super-status/`, created
with `0700` permissions — private to the user, unlike the world-readable
`/tmp` location used before v2.0.0 (`doctor.sh` deletes the legacy `/tmp`
cache if it finds one). Cached data includes token totals, tool-call counts,
repo paths, and the OpenRouter credits response — never credentials.

## Reporting

Open a GitHub issue at https://github.com/orassayag/super-status/issues for
anything security-relevant. There is no embargo process — this is a
single-maintainer local-tooling project.
