# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — what's unique to this setup.

## Access & Tools

- **Internet:** web search + fetch available.
- **AWS:** credentials are at `~/.aws` — available for AWS CLI operations against the customer's account(s). Elevated shell execution is enabled, so you can run `aws ...` directly.
- **Python:** `python3` with `requests`, `boto3`, `pandas`, `matplotlib` pre-installed (scripts/plotting). For headless plots set `matplotlib.use('Agg')` before importing pyplot.

## AWS Profiles Rule

- See which accounts are configured with `aws configure list-profiles`.
- When the user names an AWS account, use the matching `--profile <account>` in every AWS CLI command.
- If only one account is configured, you may use it directly (it's the `default` profile).
- If the user references an account that isn't configured, **ask** rather than guessing.
- Access is **read-only** — never create, modify, or delete resources. Only run read / list / describe / get commands.
- Default region is `us-east-1`. **Query only this one region by default.** Do NOT loop over all regions on a normal question — that is slow and can stall the bot. Only scan additional regions when the user explicitly asks (e.g. "all regions", "globally", "every region") or names a specific region.
- Keep each turn fast: prefer a single targeted CLI call, and trim output with `--query` / `--output text` instead of dumping full JSON. If a broad multi-region sweep is genuinely required, say so first, then do it deliberately.

## Pipeline monitoring

To set up build/deploy failure alerts on the customer's CodePipelines, follow `pipeline_monitoring_guide.md` in this workspace.

## If a tool or library isn't installed

You have elevated shell exec, so install what you need, then verify with `command -v <tool>` (or a Python `import`):
- **System tool:** `sudo apt-get install -y <pkg>` — e.g. `ripgrep`, `jq`.
- **Python library:** `python3 -m pip install <lib>` — e.g. `requests`, `boto3`.
- **Node CLI:** `sudo npm install -g <pkg>`.

Already pre-installed: `aws` CLI, `jq`, `git`, `ripgrep` (rg), `curl`, `unzip`, `node`/`npm`, and `python3` (+ `pip`, `requests`, `boto3`, `pandas`, `matplotlib`).

If an install fails (no network, permission denied), **don't silently skip the task** — tell the user exactly what's missing and the command to add it.

## Notes

Add SSH hosts, device nicknames, and other environment-specific details here as they come up.
