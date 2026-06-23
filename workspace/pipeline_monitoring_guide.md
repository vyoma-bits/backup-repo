# Guide: build a pipeline build/deploy failure alert

This guide tells you (the OpenClaw agent) how to set up CodePipeline failure
alerts when a user asks for it (e.g. "watch my pipelines and ping this channel
when a build fails"). Build the script yourself following this pattern. Do not
invent a different shape — keep it consistent every time.

## 1. Ask the user for (or infer) these inputs
- **Which pipelines and stages** to watch. Use the EXACT names as they appear in
  AWS CodePipeline (case-sensitive). Example: `EffMonPipeline` → `Build`, `Assets`,
  `prod-DW4-Deployments-1`.
- **Which Slack channel** to post failures to (a channel id, e.g. `C0123...`).
- **Which AWS region** the pipelines run in.
- The AWS credentials are already on the box: a named profile in `~/.aws` whose
  name is in `AWS_PROFILE_NAME` (from `~/.openclaw/.env`), and the Slack token is in
  `SLACK_BOT_TOKEN` (also in `.env`) — you don't need to ask for the token's value.
  But DO **confirm with the user which AWS profile to monitor with** (show the options
  from `aws configure list-profiles`) and that it has the **read** permissions pipeline
  monitoring needs. Tell the user the exact permissions and ask them to add any that
  are missing:
    - `codepipeline:GetPipelineState`, `codepipeline:ListPipelineExecutions`
    - `codebuild:BatchGetBuilds`
    - `logs:GetLogEvents`, `logs:FilterLogEvents`
    - `cloudformation:DescribeStackEvents`
  If any call returns `AccessDenied`, surface exactly which permission is missing and
  ask the user to grant it — don't silently fail.

## 2. Where to put things
```
~/.openclaw/scripts/pipeline_build_alert.py        # the script you write
~/.openclaw/cron/pipeline_build_alert.crontab      # runs it every 3 minutes
~/.openclaw/logs/pipeline_build_alert.log          # cron output
~/.openclaw/workspace/state/pipeline_build_alert.json   # dedupe state
~/.openclaw/.env                                   # SLACK_BOT_TOKEN, AWS_PROFILE_NAME
```
Read settings from `.env`; do not hard-code pipeline names, channel, region, or
profile in the script — keep them in config (env or a small config block) so the
same script works if settings change.

## 3. What the script must do (every run)
1. Load `.env` (get `SLACK_BOT_TOKEN`, `AWS_PROFILE_NAME`).
2. For each watched pipeline, call `aws codepipeline get-pipeline-state`
   (using `--profile $AWS_PROFILE_NAME --region <region>`).
3. For each watched stage, check if its `latestExecution.status == "Failed"`.
4. For a newly failed stage, find the root cause:
   - **CodeBuild action** → `codebuild batch-get-builds`, read the failed phase
     reason and the last ~200 CloudWatch log lines.
   - **CloudFormation deploy** → `cloudformation describe-stack-events`, pull the
     `*_FAILED` resource status reasons.
   - **Any other action type** → fall back to the generic signal already in the
     `get-pipeline-state` output: read the failed action's
     `latestExecution.errorDetails.message` and, when present,
     `latestExecution.externalExecutionUrl`. Report that message plus the external
     execution URL so the user always gets something actionable, regardless of action
     type (e.g. ECS deploy, Lambda, manual approval, third-party). The CodeBuild and
     CloudFormation cases above are just richer special-cases of this same fallback —
     always have this generic path so nothing fails silently.
5. Find the real error line: scan the log for the FIRST strong error signal
   (e.g. `Traceback`, `npm ERR!`, `error TS####`, `AccessDenied`,
   `no such file or directory`, `Command failed`), skipping noise lines like
   `[Container]` and the trailing `phase FAILED` summary.
6. Post to Slack (`chat.postMessage`) with: a `<!channel>` tag, the
   pipeline/stage/action, links (pipeline timeline, action console, logs), a
   one-line **Root cause**, and the log snippet as a **thread reply**.
7. **Dedupe**: keep a state file mapping `(pipeline, stage) -> pipelineExecutionId`
   already alerted, so each failed run is announced at most once per stage.

## 4. Install the schedule
Write the crontab to run every 3 minutes and install it for the run user:
```
*/3 * * * * /usr/bin/python3 ~/.openclaw/scripts/pipeline_build_alert.py >> ~/.openclaw/logs/pipeline_build_alert.log 2>&1
```
Then `crontab ~/.openclaw/cron/pipeline_build_alert.crontab`.

## 5. Verify
Run the script once by hand and confirm it exits cleanly (no alert if nothing is
failing). If you can, point it at a known-failed stage and confirm the Slack
message lands in the right channel with a correct root cause.

## Rules
- Stage/pipeline names must match AWS exactly, or nothing is watched (and no error
  is raised) — double check the names.
- Never post the same failure twice — the state file is required.
- Read-only only: the AWS profile has read permissions; do not attempt writes.
- Keep secrets out of the script; read them from `.env`.
