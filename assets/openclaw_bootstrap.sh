#!/usr/bin/env bash
###############################################################################
# OpenClaw first-boot bootstrap

#
# You only create the per-customer secret in Secrets Manager. This script:
#   1. installs Node + OpenClaw + AWS CLI (+ Claude CLI for Anthropic)
#   2. reads the secret (Claude OAuth token, Slack tokens, AWS keys) via instance role
#   3. configures the model via Claude CLI sign-in (OAuth) - Anthropic only for now
#   4. connects Slack + enables elevated exec (so the agent can run aws)
#   5. writes the customer's AWS profile so the agent can read their account
#   6. renders instructions/*.md (AGENTS.md + guides) into the agent workspace
#   7. runs the gateway as a systemd service
#
# Model comes from the map (MODEL_ID, e.g. "anthropic/claude-sonnet-4-5").
# Auth is Claude CLI sign-in (OAuth via `claude setup-token`), NOT an API key.
# Only Anthropic/Claude is implemented; other providers are recognized but not wired.
###############################################################################
set -uo pipefail
# Bootstrap logs to the ROOT disk here because this runs BEFORE the data EBS volume is even attached/
# mounted (sections 1a/1b), so the volume isn't available yet. It is NOT lost on instance replacement:
# the log-upload step (section 10) ships it - plus the refresh/onboot/backup logs - to
# s3://<bucket>/logs/<customer>/, which is where OpenClaw logs are meant to persist. (We deliberately do
# NOT keep logs under ~/.openclaw: that dir is git-backed up to the customer's repo, so logs would leak
# into the backup.)
LOG=/var/log/openclaw-bootstrap.log
exec > >(tee -a "$LOG") 2>&1
log() { echo "[openclaw $(date -u +%H:%M:%S)] $*"; }
log "bootstrap start $(date -u)"

fail() {
  local rc=$? line=$1
  trap - ERR                       # disarm so the handler can't re-enter
  log "bootstrap FAILED at line $line (exit $rc) - sentinel NOT written; box is not healthy"
  [ -x /usr/local/bin/openclaw-log-upload.sh ] && /usr/local/bin/openclaw-log-upload.sh || true
  exit "$rc"
}
trap 'fail $LINENO' ERR

# ---- config from the stack (env header) ----
: "${OPENCLAW_CUSTOMER:?set OPENCLAW_CUSTOMER}"
: "${OPENCLAW_REGION:?set OPENCLAW_REGION (account region of secret + bucket)}"
: "${OPENCLAW_BUCKET:?set OPENCLAW_BUCKET (single bucket holding config/ + logs/)}"
MODEL_ID="${MODEL_ID:-anthropic/claude-sonnet-4-5}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
OPENCLAW_SECRET_ID="${OPENCLAW_SECRET_ID:-openclaw/${OPENCLAW_CUSTOMER}/config}"
RUN_USER="${RUN_USER:-ubuntu}"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
if [ -z "${RUN_HOME:-}" ] || [ ! -d "$RUN_HOME" ]; then
  log "invalid RUN_USER '$RUN_USER' (home not found)"
 exit 1
fi
OC_HOME="$RUN_HOME/.openclaw"
RUN_UID="$(id -u "$RUN_USER")"
AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-$OPENCLAW_CUSTOMER}"
AWS_PROFILE_REGION="${AWS_PROFILE_REGION:-us-east-1}"

# The injected env IS the bootstrap's entire input. Log it once, up front, into bootstrap.log
# (which is uploaded to S3) so a mis-bootstrapped box shows exactly what was baked into UserData
# without needing to SSH. All non-secret - real secrets come from Secrets Manager, never UserData.
log "injected env: CUSTOMER=$OPENCLAW_CUSTOMER REGION=$OPENCLAW_REGION MODEL=$MODEL_ID ASSETS_VERSION=${OPENCLAW_ASSETS_VERSION:-} BUCKET=$OPENCLAW_BUCKET BACKUP_REPO=${OPENCLAW_BACKUP_REPO:-} GATEWAY_PORT=$GATEWAY_PORT RUN_USER=$RUN_USER OC_HOME=$OC_HOME AWS_PROFILE_NAME=$AWS_PROFILE_NAME SECRET_ID=$OPENCLAW_SECRET_ID"

case "$(uname -m)" in
  x86_64)  AWSCLI_ARCH=x86_64 ;;
  aarch64) AWSCLI_ARCH=aarch64 ;;
  *) log "unsupported arch $(uname -m)"; exit 1 ;;
esac

# Run an OpenClaw command as the run user with its HOME.
oc() { sudo -u "$RUN_USER" -H "$@"; }

# Idempotency guard: EC2 UserData runs once per instance. If it is re-run on the SAME box, don't
# re-install - just ensure the gateway is up and exit.
#
# This sentinel lives on the ROOT (ephemeral) volume ON PURPOSE. It must NOT move to the data volume:
# on an instance replacement (userDataCausesReplacement) the root is fresh, so the sentinel is absent
# and the full bootstrap re-runs - which is exactly what we want, because the NEW root has no Node /
# OpenClaw / AWS CLI / systemd unit yet and they have to be reinstalled.
#
# The remaining risk the reviewer flagged - re-running steps over a ~/.openclaw that the previous box
# already populated - is handled where it matters: the install steps are idempotent (guarded by
# `command -v` / unit overwrite), the secret-derived files (~/.aws, ~/.claude, .env) are meant to be
# rewritten each boot (picks up rotated creds), and the one least-tested-over-populated-state step,
# `openclaw onboard`, is now skipped via a marker on the PERSISTENT volume (see section 4).
SENTINEL=/var/lib/openclaw-bootstrapped
if [ -f "$SENTINEL" ]; then
  log "already bootstrapped; ensuring gateway is running, then exiting"
  systemctl start openclaw-gateway.service 2>/dev/null || true
  exit 0
fi

###############################################################################
# 1. Install ONLY what the EBS attach/mount + secret read below need: base packages and the
#    AWS CLI. Node / OpenClaw / the Python libs are heavier and are installed AFTER the data
#    volume is mounted (section 1c), so a box with an unavailable volume fails fast (in 1b)
#    instead of after several minutes of installs that would just be thrown away.
#
# Pinned tool versions: "latest" can ship a breaking change mid-fleet, so pin to a tested
# version and bump deliberately. Overridable via the env header if ever needed.
###############################################################################
NODE_MAJOR="${NODE_MAJOR:-22}"
OPENCLAW_VERSION="${OPENCLAW_VERSION:-2026.6.6}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.177}"
log "installing base packages"
export DEBIAN_FRONTEND=noninteractive
for _ in $(seq 1 30); do fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break; sleep 5; done
apt-get update -y
# ripgrep (rg) for fast searching; jq/git/python3/pip/cron are agent + monitoring-script staples.
apt-get install -y curl unzip jq git python3 python3-pip ca-certificates cron ripgrep

if ! command -v aws >/dev/null 2>&1; then
  log "installing AWS CLI v2 ($AWSCLI_ARCH)"   # needed NOW for the EBS attach in section 1a
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSCLI_ARCH}.zip" -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install --update
fi
# AWS CLI v2 lands in /usr/local/bin. Make it explicit on PATH for every aws call below (attach volume,
# read secret, sync config) - a minimal boot PATH should never make a clean install look like
# 'aws: command not found'.
export PATH="/usr/local/bin:$PATH"

###############################################################################
# 1a. Attach the persistent data EBS volume to THIS instance.
#     The volume is NOT attached by CloudFormation (a CFN attachment races on instance
#     replacement: it can try to attach to the new box before the old one releases the
#     volume -> stuck update). Instead we find it by tag and attach it here, force-detaching
#     it from a terminating old instance if needed. EBS attachments survive stop/start, so
#     this only does real work on first boot / after a replacement.
###############################################################################
DATA_TAG_KEY="${OPENCLAW_DATA_VOLUME_TAG_KEY:-}"
DATA_DEVICE="${OPENCLAW_DATA_DEVICE:-/dev/sdf}"
if [ -n "$DATA_TAG_KEY" ]; then
  TOKEN="$(curl -sf -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' || true)"
  imds() { curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
  INSTANCE_ID="$(imds instance-id || true)"
  AZ="$(imds placement/availability-zone || true)"
  [ -n "$INSTANCE_ID" ] && [ -n "$AZ" ] || { log "FATAL: could not read instance-id/AZ from IMDS"; exit 1; }

  log "locating data volume by tag $DATA_TAG_KEY=$OPENCLAW_CUSTOMER in $AZ"
  VOL_ID="$(aws ec2 describe-volumes --region "$OPENCLAW_REGION" \
      --filters "Name=tag:$DATA_TAG_KEY,Values=$OPENCLAW_CUSTOMER" "Name=availability-zone,Values=$AZ" \
      --query 'Volumes[0].VolumeId' --output text 2>/dev/null || true)"
  if [ -z "$VOL_ID" ] || [ "$VOL_ID" = "None" ]; then
    log "FATAL: no data volume found with tag $DATA_TAG_KEY=$OPENCLAW_CUSTOMER in $AZ"; exit 1
  fi

  ATTACHED_TO="$(aws ec2 describe-volumes --region "$OPENCLAW_REGION" --volume-ids "$VOL_ID" \
      --query 'Volumes[0].Attachments[0].InstanceId' --output text 2>/dev/null || true)"
  if [ "$ATTACHED_TO" = "$INSTANCE_ID" ]; then
    log "data volume $VOL_ID already attached to this instance"
  else
    if [ -n "$ATTACHED_TO" ] && [ "$ATTACHED_TO" != "None" ]; then
      log "data volume $VOL_ID still attached to old instance $ATTACHED_TO - force-detaching"
      aws ec2 detach-volume --region "$OPENCLAW_REGION" --volume-id "$VOL_ID" --force >/dev/null 2>&1 || true
    fi
    for _ in $(seq 1 60); do          # wait up to ~5min for the volume to become 'available'
      [ "$(aws ec2 describe-volumes --region "$OPENCLAW_REGION" --volume-ids "$VOL_ID" \
           --query 'Volumes[0].State' --output text 2>/dev/null || true)" = "available" ] && break
      sleep 5
    done
    log "attaching data volume $VOL_ID at $DATA_DEVICE"
    aws ec2 attach-volume --region "$OPENCLAW_REGION" --volume-id "$VOL_ID" \
        --instance-id "$INSTANCE_ID" --device "$DATA_DEVICE" >/dev/null 2>&1 \
        || { log "FATAL: attach-volume $VOL_ID -> $INSTANCE_ID failed"; exit 1; }
    for _ in $(seq 1 60); do          # wait for the attachment to report 'attached'
      [ "$(aws ec2 describe-volumes --region "$OPENCLAW_REGION" --volume-ids "$VOL_ID" \
           --query 'Volumes[0].Attachments[0].State' --output text 2>/dev/null || true)" = "attached" ] && break
      sleep 5
    done
    log "data volume $VOL_ID attached to $INSTANCE_ID"
  fi
fi

###############################################################################
# 1b. Mount the attached data EBS volume DIRECTLY at ~/.openclaw, so ALL of the
#     agent's config/memory lives on the persistent (snapshot-on-removal) volume,
#     not the root disk. The mount IS ~/.openclaw - no /data + symlink indirection.
#     /etc/fstab re-mounts it on every reboot; formats only if the volume is new.
###############################################################################
log "locating data EBS volume"
DATA_DEV=""
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
for _ in $(seq 1 60); do            # retry ~120s: the EBS volume attach can lag behind UserData
  for d in /dev/nvme1n1 /dev/xvdf /dev/sdf; do
    [ -b "$d" ] || continue
    case "$ROOT_SRC" in *"$(basename "$d")"*) continue ;; esac      # never the root disk
    [ -z "$(lsblk -no MOUNTPOINT "$d" 2>/dev/null)" ] && { DATA_DEV="$d"; break; }
  done
  [ -n "$DATA_DEV" ] && break
  sleep 2
done


[ -L "$OC_HOME" ] && rm -f "$OC_HOME"
mkdir -p "$OC_HOME"   # the mount point (or a plain dir if there's no volume)

if [ -n "$DATA_DEV" ]; then
  log "data volume = $DATA_DEV -> mounting directly at $OC_HOME"
  FORMATTED=0
  if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
    log "formatting $DATA_DEV (ext4)"; mkfs.ext4 -q "$DATA_DEV"; FORMATTED=1
  fi
  UUID="$(blkid -s UUID -o value "$DATA_DEV")"
  # persist the mount across reboots; nofail so a missing volume never blocks boot
  grep -q "$UUID" /etc/fstab 2>/dev/null || echo "UUID=$UUID $OC_HOME ext4 defaults,nofail 0 2" >> /etc/fstab
  mountpoint -q "$OC_HOME" || mount "$DATA_DEV" "$OC_HOME"
  if [ "$FORMATTED" = 1 ]; then
    # ONLY on a brand-new filesystem: a fresh ext4 root is owned root:root, so hand it to the run user.
    # Do NOT chown on every remount - on an instance replacement the volume already holds the prior box's
    # data, and a blanket top-level chown would clobber anything intentionally owned by root/another user.
    chown "$RUN_USER:$RUN_USER" "$OC_HOME"
  fi
else

  log "FATAL: data EBS volume did not attach within ~120s - refusing to run on the ephemeral root disk"
  log "FATAL: OpenClaw config/memory must live on the external volume; sentinel NOT written, box is not healthy"
  exit 1
fi

###############################################################################
# 1c. Data volume is mounted (the box is viable), so now install the heavy runtime: Node,
#     OpenClaw, and the common Python libs. These live on the root disk and are reinstalled on
#     each fresh instance - that's fine, they're software, not state.
###############################################################################
if ! command -v node >/dev/null 2>&1; then
  log "installing Node.js $NODE_MAJOR"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
fi

log "installing OpenClaw@$OPENCLAW_VERSION"
npm install -g "openclaw@${OPENCLAW_VERSION}"
command -v openclaw >/dev/null 2>&1 || { log "openclaw not found after install"; exit 1; }
log "node $(node -v), openclaw $(openclaw --version 2>&1 | head -1)"

# Common Python libraries the agent + monitoring scripts rely on: TOOLS.md mentions matplotlib/pandas;
# the pipeline alert posts to Slack (requests) and may use boto3. Non-fatal if a lib can't install.
log "installing common Python libraries (requests, boto3, pandas, matplotlib)"
python3 -m pip install --no-input --upgrade requests boto3 pandas matplotlib 2>&1 | tail -2 \
  || log "pip library install had issues (continuing - agent can pip install on demand)"

###############################################################################
# 2. Read the per-customer secret (instance role)
###############################################################################
log "reading secret $OPENCLAW_SECRET_ID"
SECRET="$(aws secretsmanager get-secret-value --secret-id "$OPENCLAW_SECRET_ID" \
          --region "$OPENCLAW_REGION" --query SecretString --output text)"
# Guard: a missing secret already fails above (fail-fast), but an EMPTY or non-JSON secret would
# pass and then make every jget return "" - a box that comes up silently misconfigured. Stop here.
if [ -z "${SECRET:-}" ] || [ "$SECRET" = "None" ] || [ "$SECRET" = "null" ]; then
  log "FATAL: secret $OPENCLAW_SECRET_ID is empty or unreadable - aborting"
  exit 1
fi
if ! printf '%s' "$SECRET" | jq -e 'type == "object"' >/dev/null 2>&1; then
  log "FATAL: secret $OPENCLAW_SECRET_ID is not a JSON object - aborting"
  exit 1
fi
jget() { printf '%s' "$SECRET" | jq -r --arg k "$1" '.[$k] // empty'; }
# NOTE: no MODEL_API_KEY here on purpose - auth is Claude CLI sign-in (OAuth), NOT an API key. A
# MODEL_API_KEY slot is reserved in the secret (see README) for a future non-OAuth provider path.
CLAUDE_CODE_OAUTH_TOKEN="$(jget CLAUDE_CODE_OAUTH_TOKEN)"
CLAUDE_JSON="$(jget CLAUDE_JSON)"
# BACKUP_REPO is non-secret: comes from the customer map via UserData (OPENCLAW_BACKUP_REPO).
BACKUP_REPO="${OPENCLAW_BACKUP_REPO:-}"
GITHUB_TOKEN="$(jget GITHUB_TOKEN)"
SLACK_BOT_TOKEN="$(jget SLACK_BOT_TOKEN)"
SLACK_APP_TOKEN="$(jget SLACK_APP_TOKEN)"
CUST_AK="$(jget AWS_ACCESS_KEY_ID)"
CUST_SK="$(jget AWS_SECRET_ACCESS_KEY)"
# Map of AWS accounts the agent can read: { "<name>": { "accessKey":..., "secretKey":... }, ... }
ACCOUNTS_JSON="$(printf '%s' "$SECRET" | jq -c '.AWS_ACCOUNTS // empty')"

###############################################################################
# 3. Keep the setup assets on the DATA EBS volume (mounted at ~/.openclaw in step 1b), NOT on the
#    ephemeral root disk. The launcher only fetched this single bootstrap script to /tmp to start;
#    now that the volume is mounted, sync the FULL asset set to the EBS-backed dir so it persists
#    across a root-disk replacement. Bucket layout: config/openclaw_bootstrap.sh, config/openclaw_onboot.sh,
#    config/instructions/...
###############################################################################
ASSETS="$OC_HOME/assets"
log "syncing assets from s3://$OPENCLAW_BUCKET/config/ to data volume ($ASSETS)"
mkdir -p "$ASSETS"
# --exact-timestamps: plain sync compares size + mtime, so a tampered file of identical size could be
# skipped; this re-downloads on any timestamp mismatch (closest CLI option to content integrity).
aws s3 sync "s3://$OPENCLAW_BUCKET/config/" "$ASSETS/" --region "$OPENCLAW_REGION" --exact-timestamps --only-show-errors || true
chown -R "$RUN_USER:$RUN_USER" "$ASSETS" 2>/dev/null || true

###############################################################################
# 4. Configure the model provider.
#    Auth is via Claude CLI sign-in (OAuth), NOT an API key.
#    Only Anthropic/Claude is implemented; other providers are recognized but
#    not wired yet (the box still comes up, just without a model configured).
###############################################################################
PROVIDER="${MODEL_ID%%/*}"
log "model=$MODEL_ID provider=$PROVIDER"

# Gateway env file (read by the systemd service via EnvironmentFile).
ENVFILE="$OC_HOME/.env"
: > "$ENVFILE"
chmod 600 "$ENVFILE"

# Keys the agent loads from ~/.openclaw/.env per instructions/pipeline_monitoring_guide.md
# (it runs `aws --profile $AWS_PROFILE_NAME ...` and posts to Slack with $SLACK_BOT_TOKEN).
# .env is also the gateway's systemd EnvironmentFile, so use plain KEY=value lines (no export/quotes).
printf 'AWS_PROFILE_NAME=%s\n' "$AWS_PROFILE_NAME" >> "$ENVFILE"
[ -n "$SLACK_BOT_TOKEN" ] && printf 'SLACK_BOT_TOKEN=%s\n' "$SLACK_BOT_TOKEN" >> "$ENVFILE" || true

case "$PROVIDER" in
  anthropic)
    log "Anthropic: Claude CLI sign-in (~/.claude/.credentials.json)"
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" 2>&1 | tail -2 || log "claude CLI install failed (continuing)"

    if printf '%s' "$CLAUDE_JSON" | jq -e '.claudeAiOauth.accessToken' >/dev/null 2>&1; then
      log "writing ~/.claude/.credentials.json from secret"
      install -d -o "$RUN_USER" -g "$RUN_USER" -m 700 "$RUN_HOME/.claude"
      printf '%s' "$CLAUDE_JSON" > "$RUN_HOME/.claude/.credentials.json"
      chown "$RUN_USER:$RUN_USER" "$RUN_HOME/.claude/.credentials.json"
      chmod 600 "$RUN_HOME/.claude/.credentials.json"
    elif [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && [ "$CLAUDE_CODE_OAUTH_TOKEN" != "placeholder" ]; then
      log "using CLAUDE_CODE_OAUTH_TOKEN (setup-token) from secret"
      printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$CLAUDE_CODE_OAUTH_TOKEN" >> "$ENVFILE"
    else
      log "WARN: no VALID Claude credentials in secret (CLAUDE_JSON lacks .claudeAiOauth, or placeholder) - the health gate will fail this box"
    fi
    # Scaffold base config + gateway ONCE. The marker lives on the PERSISTENT data volume (~/.openclaw),
    # NOT on the ephemeral root - so after an instance replacement (fresh root, but ~/.openclaw already
    # holds the prior box's populated config + memory) we do NOT re-run `onboard` over an existing config.
    # Re-running onboard over populated state is the least-tested path; the config patch/set calls below
    # ARE idempotent and still run every boot, so model/token rotations continue to apply.
    ONBOARDED_MARKER="$OC_HOME/.onboarded"
    if [ -f "$ONBOARDED_MARKER" ]; then
      log "openclaw already onboarded (marker on data volume) - skipping onboard over populated config"
    else
      log "onboarding openclaw (first time on this data volume)"
      oc openclaw onboard --non-interactive --accept-risk --mode local \
        --gateway-port "$GATEWAY_PORT" --gateway-bind loopback \
        --skip-bootstrap --skip-skills 2>&1 | tail -8 \
        && touch "$ONBOARDED_MARKER" \
        || log "onboard returned nonzero (continuing)"
    fi
    cat > /tmp/oc-claude.json5 <<JSON
{ "agents": { "defaults": { "model": { "primary": "$MODEL_ID" } } },
  "auth": { "profiles": { "anthropic:claude-cli": { "provider": "claude-cli", "mode": "oauth" } } } }
JSON
    oc openclaw config patch --file /tmp/oc-claude.json5 2>&1 | tail -3 || true
    ;;
  *)
    log "provider '$PROVIDER' is NOT implemented yet - only Anthropic (Claude CLI sign-in) is wired. Skipping model setup."
    ;;
esac

###############################################################################
# 5. Connect Slack (any provider)
###############################################################################
if [ -n "$SLACK_BOT_TOKEN" ]; then
  log "configuring Slack"
  oc openclaw plugins install @openclaw/slack 2>&1 | tail -3 || true
  oc openclaw config set plugins.entries.slack.enabled true 2>&1 | tail -1 || true
  oc openclaw config set channels.slack.enabled true 2>&1 | tail -1 || true
  oc openclaw config set channels.slack.botToken "$SLACK_BOT_TOKEN" 2>&1 | tail -1 || true
  if [ -n "$SLACK_APP_TOKEN" ]; then
    # if-block (not `[ -n ] && ... || true`) so the `|| true` covers ONLY the config command -
    # the token-presence test no longer shares the swallow. Matches the SLACK_BOT_TOKEN block above.
    oc openclaw config set channels.slack.appToken "$SLACK_APP_TOKEN" 2>&1 | tail -1 || true
  fi
  # Respond wherever it's mentioned (default is 'allowlist', which ignores channels), and reply interactively.
  oc openclaw config set channels.slack.groupPolicy open 2>&1 | tail -1 || true
  oc openclaw config set channels.slack.capabilities.interactiveReplies true 2>&1 | tail -1 || true
  # Reply inside the triggering message's thread, and keep each thread's conversation + memory
  # scoped to that thread (separate threads stay independent / parallel).
  oc openclaw config set channels.slack.replyToMode all 2>&1 | tail -1 || true
  oc openclaw config set channels.slack.thread.historyScope thread 2>&1 | tail -1 || true
  oc openclaw config set channels.slack.thread.requireExplicitMention true 2>&1 | tail -1 || true
fi

###############################################################################
# 6. Enable elevated exec so the agent can run host commands (e.g. aws) itself
#     Without this the agent is sandboxed and refuses to run shell commands.
###############################################################################
log "enabling elevated exec"
oc openclaw config set tools.elevated.enabled true 2>&1 | tail -1 || true
oc openclaw config set agents.defaults.elevatedDefault full 2>&1 | tail -1 || true

###############################################################################
# 7. Write one AWS profile per account so the agent can read the customer's
#    AWS account(s). Prefers the AWS_ACCOUNTS map; falls back to single keys.
#    The first account is also written as [default] so plain `aws` works; the
#    agent uses `--profile <name>` for the others (`aws configure list-profiles`).
###############################################################################
mkdir -p "$RUN_HOME/.aws"
: > "$RUN_HOME/.aws/credentials"
: > "$RUN_HOME/.aws/config"
WROTE_ANY=0

write_profile() {  # $1=name $2=accesskey $3=secretkey ; no-op if either is missing (never write a half profile)
  if [ -z "$2" ] || [ -z "$3" ]; then
    log "skipping profile $1 (missing access key or secret key)"
    return 0
  fi
  printf '[%s]\naws_access_key_id=%s\naws_secret_access_key=%s\n\n' "$1" "$2" "$3" >> "$RUN_HOME/.aws/credentials"
  if [ "$1" = "default" ]; then
    printf '[default]\nregion=%s\noutput=json\n\n' "$AWS_PROFILE_REGION" >> "$RUN_HOME/.aws/config"
  else
    printf '[profile %s]\nregion=%s\noutput=json\n\n' "$1" "$AWS_PROFILE_REGION" >> "$RUN_HOME/.aws/config"
  fi
}

if [ -n "${ACCOUNTS_JSON:-}" ] && [ "$ACCOUNTS_JSON" != "null" ] && [ "$ACCOUNTS_JSON" != "{}" ]; then
  log "writing AWS profiles from AWS_ACCOUNTS map"
  DEFAULT_DONE=0
  for name in $(printf '%s' "$ACCOUNTS_JSON" | jq -r 'keys[]'); do
    ak=$(printf '%s' "$ACCOUNTS_JSON" | jq -r --arg n "$name" '.[$n].accessKey // .[$n].AWS_ACCESS_KEY_ID // empty')
    sk=$(printf '%s' "$ACCOUNTS_JSON" | jq -r --arg n "$name" '.[$n].secretKey // .[$n].AWS_SECRET_ACCESS_KEY // empty')
    if [ -z "$ak" ] || [ -z "$sk" ]; then log "skipping account $name (missing access key or secret key)"; continue; fi
    write_profile "$name" "$ak" "$sk"
    [ "$DEFAULT_DONE" = 0 ] && { write_profile "default" "$ak" "$sk"; DEFAULT_DONE=1; }
    WROTE_ANY=1
  done
elif [ -n "$CUST_AK" ] && [ -n "$CUST_SK" ]; then
  log "writing single AWS profile (legacy keys)"
  write_profile "$AWS_PROFILE_NAME" "$CUST_AK" "$CUST_SK"
  write_profile "default" "$CUST_AK" "$CUST_SK"
  WROTE_ANY=1
elif [ -n "$CUST_AK" ] || [ -n "$CUST_SK" ]; then
  log "WARN: legacy AWS keys incomplete (need both access key and secret key) - no profile written"
fi

if [ "$WROTE_ANY" = 1 ]; then
  chmod 700 "$RUN_HOME/.aws"; chmod 600 "$RUN_HOME/.aws"/*
else
  log "WARN: no customer AWS keys in secret - agent cannot read any AWS account"
fi


WS="$OC_HOME/workspace"
mkdir -p "$WS"

# Config the seed + on-boot scripts read (written once; systemd has no bootstrap env, so persist it).
mkdir -p /etc/openclaw
cat > /etc/openclaw/refresh.env <<EOF
OPENCLAW_BUCKET="${OPENCLAW_BUCKET:-}"
OPENCLAW_CUSTOMER="${OPENCLAW_CUSTOMER}"
OPENCLAW_REGION="${OPENCLAW_REGION}"
OC_AWS_REGION="${AWS_PROFILE_REGION}"
OC_WS="${WS}"
OC_HOME="${OC_HOME}"
OC_RUN_USER="${RUN_USER}"
EOF

cat > /usr/local/bin/openclaw-seed-config.sh <<'EOS'
#!/bin/bash
# ONE-TIME seed of the agent workspace. Renders the instruction set into the workspace from the LOCAL
# assets copy that bootstrap already downloaded to ~/.openclaw/assets/instructions - NO S3 pull here.
# (Once the assets are on the volume we don't fetch them again.) openclaw_bootstrap.sh lives under
# assets/ too but is a setup asset, so we only seed instructions/.
set -uo pipefail
. /etc/openclaw/refresh.env
SRC="${OC_HOME:-/home/$OC_RUN_USER/.openclaw}/assets/instructions"
TS="$(date -u +%FT%TZ)"
[ -d "$SRC" ] || { echo "[$TS] no instructions at $SRC - nothing to seed"; exit 0; }
# render placeholders into the workspace (mirrors the repo's md files)
mkdir -p "$OC_WS"
find "$SRC" -type f | while read -r f; do
  rel="${f#$SRC/}"
  mkdir -p "$OC_WS/$(dirname "$rel")"
  sed -e "s/__CUSTOMER__/${OPENCLAW_CUSTOMER}/g" \
      -e "s/__CUSTOMER_ACCOUNT__/${OPENCLAW_CUSTOMER}/g" \
      -e "s#__AWS_REGION__#${OC_AWS_REGION}#g" \
      "$f" > "$OC_WS/$rel"
done
chown -R "$OC_RUN_USER:$OC_RUN_USER" "$OC_WS" 2>/dev/null || true
echo "[$TS] seed complete (from $SRC)"
EOS
chmod +x /usr/local/bin/openclaw-seed-config.sh

# Seed the workspace ONLY if this data volume has never been seeded (workspace has no .md yet). The
# workspace lives on the persistent volume, so on an instance replacement it already holds the config
# from the FIRST bootstrap - we deliberately do NOT re-seed/overwrite it. Config is frozen after the
# initial seed and is never re-pulled from S3.
if [ -z "$(find "$WS" -type f -name '*.md' -print -quit 2>/dev/null)" ]; then
  log "seeding workspace config from local assets ($ASSETS/instructions) - first time on this volume"
  if [ -z "$(find "$ASSETS/instructions" -type f -name '*.md' -print -quit 2>/dev/null)" ]; then
    log "FATAL: no instruction files in $ASSETS/instructions (assets download failed?) - aborting"
    exit 1
  fi
  /usr/local/bin/openclaw-seed-config.sh >> /var/log/openclaw-seed.log 2>&1 || true
  if [ -z "$(find "$WS" -type f -name '*.md' -print -quit 2>/dev/null)" ]; then
    log "FATAL: no instruction files in workspace $WS after initial config seed - config did not load, aborting"
    exit 1
  fi
  log "workspace seeded with $(find "$WS" -type f | wc -l) file(s)"
else
  log "workspace already seeded on this data volume ($(find "$WS" -type f | wc -l) file(s)) - leaving config as-is (no re-pull)"
fi

# No recurring sync, and no re-seed on replacement. The workspace is seeded ONCE on the first bootstrap
# of a data volume and then lives on that persistent volume untouched. Config is never updated from S3
# after that - changing a box's config means re-creating it on a fresh volume.

# Ownership fix-up. Same principle as the mount chown: only blanket-chown the data volume on a FRESH
# filesystem. On an existing volume (e.g. after an instance replacement) a recursive chown would rewrite
# ownership of the prior box's whole tree (clobbering anything intentionally non-run-user, and slow as the
# memory DB grows), so we only fix the few paths THIS run rewrote as root.
if [ "${FORMATTED:-0}" = 1 ]; then
  chown -R "$RUN_USER:$RUN_USER" "$OC_HOME" 2>/dev/null || true
else
  chown "$RUN_USER:$RUN_USER" "$ENVFILE" 2>/dev/null || true
  [ -n "${ONBOARDED_MARKER:-}" ] && chown "$RUN_USER:$RUN_USER" "$ONBOARDED_MARKER" 2>/dev/null || true
fi
# ~/.aws lives on the ephemeral root home and is rewritten every boot - always fix it (cheap, small).
chown -R "$RUN_USER:$RUN_USER" "$RUN_HOME/.aws" 2>/dev/null || true

###############################################################################
# 9. Run the gateway as our own systemd SYSTEM service (reliable headless)
###############################################################################
log "installing gateway systemd service"
OPENCLAW_BIN="$(command -v openclaw)"
# Keep ${RUN_USER}'s runtime session (/run/user/${RUN_UID}, XDG_RUNTIME_DIR, per-user dbus/keyring)
# alive from boot WITHOUT a human logging in. Without this, that session only exists while someone is
# logged in - which is the "I just SSH/SSM in and THEN the bot starts working" bug: the gateway (a
# system service running as ${RUN_USER}) was missing its runtime dir until a login created it.
loginctl enable-linger "$RUN_USER" 2>/dev/null || true
cat > /etc/systemd/system/openclaw-gateway.service <<UNIT
[Unit]
Description=OpenClaw gateway (customer: ${OPENCLAW_CUSTOMER})
After=network-online.target
Wants=network-online.target
# ~/.openclaw is a dedicated EBS mount holding ALL config/memory. Require + order after that mount so a
# reboot race can't start the gateway against an unmounted (empty) home and silently lose/shadow state.
RequiresMountsFor=${OC_HOME}

[Service]
Type=simple
User=${RUN_USER}
Environment=HOME=${RUN_HOME}
# Point the service at the (lingered) per-user runtime dir, so it has the same XDG_RUNTIME_DIR a login
# session would provide - otherwise a system service running as the user has no runtime dir at boot.
Environment=XDG_RUNTIME_DIR=/run/user/${RUN_UID}
EnvironmentFile=-${OC_HOME}/.env
ExecStart=${OPENCLAW_BIN} gateway --port ${GATEWAY_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now openclaw-gateway.service
sleep 5
systemctl --no-pager --full status openclaw-gateway.service 2>&1 | head -12 || true
oc openclaw config validate 2>&1 | tail -3 || true

###############################################################################
# 9b. On-boot recovery service. THIS script (openclaw_bootstrap.sh) is the heavy first-boot
#     install and runs ONCE via cloud-init UserData - it does NOT run again on a plain reboot,
#     stop/start, or instance-type resize (stop -> change size -> start). To survive those, install
#     the SEPARATE openclaw_onboot.sh as a systemd service that runs on EVERY boot. That script
#     installs NOTHING (everything survives a restart on the persistent disk); it only re-mounts the
#     data volume, refreshes config, and ensures the gateway is running. Both scripts ship together
#     in config/ and are synced into $ASSETS, so we just install the on-boot one from there.
###############################################################################
log "installing on-boot recovery service (runs on every reboot/stop-start/resize)"
# The on-boot script lives on the EBS-backed assets dir ($ASSETS, synced in step 3). If it isn't there
# for any reason, pull it straight from S3 - we never stage assets on the root disk.
ONBOOT_SRC="$ASSETS/openclaw_onboot.sh"
if [ ! -f "$ONBOOT_SRC" ]; then
  aws s3 cp "s3://$OPENCLAW_BUCKET/config/openclaw_onboot.sh" "$ONBOOT_SRC" --region "$OPENCLAW_REGION" --only-show-errors || true
fi
if [ ! -f "$ONBOOT_SRC" ]; then
  log "WARN: openclaw_onboot.sh not found in assets or S3 - on-boot recovery service will NOT be installed"
else
  install -m 755 "$ONBOOT_SRC" /usr/local/bin/openclaw-onboot.sh
  cat > /etc/systemd/system/openclaw-onboot.service <<UNIT
[Unit]
Description=OpenClaw on-boot recovery (mount data volume + refresh config + ensure gateway)
After=network-online.target
Wants=network-online.target
# Wait for the data volume before running so the refresh/gateway see the real ~/.openclaw, not an empty dir.
RequiresMountsFor=${OC_HOME}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/openclaw-onboot.sh

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable openclaw-onboot.service 2>/dev/null || true
fi

###############################################################################
# 10. Ship logs to S3 under the bucket's logs/<customer>/ prefix (keeps logs OFF CloudWatch).
#     Runs as ROOT via cron so it uses the EC2 instance role (which is granted
#     PutObject to s3://<bucket>/logs/<customer>/*), not the customer's AWS profile.
###############################################################################
if [ -n "${OPENCLAW_BUCKET:-}" ]; then
  log "configuring S3 log upload -> s3://$OPENCLAW_BUCKET/logs/$OPENCLAW_CUSTOMER/"
  cat > /usr/local/bin/openclaw-log-upload.sh <<UPLOAD
#!/usr/bin/env bash
set -uo pipefail
export PATH="/usr/local/bin:\$PATH"   # cron PATH is minimal; AWS CLI v2 lives in /usr/local/bin
DEST="s3://${OPENCLAW_BUCKET}/logs/${OPENCLAW_CUSTOMER}"
REGION="${OPENCLAW_REGION}"
unset AWS_PROFILE   # force the instance role, not the customer's profile
journalctl -u openclaw-gateway --since '25 hours ago' --no-pager > /tmp/openclaw-gateway.log 2>/dev/null || true
aws s3 cp /var/log/openclaw-bootstrap.log "\$DEST/bootstrap.log" --region "\$REGION" --only-show-errors 2>/dev/null || true
aws s3 cp /tmp/openclaw-gateway.log "\$DEST/gateway.log" --region "\$REGION" --only-show-errors 2>/dev/null || true
# The root-disk helper logs (seed/onboot/backup) only persist if we ship them too - they're lost on
# instance replacement otherwise. Upload whichever exist.
for l in seed onboot backup; do
  [ -e "/var/log/openclaw-\$l.log" ] && aws s3 cp "/var/log/openclaw-\$l.log" "\$DEST/\$l.log" --region "\$REGION" --only-show-errors 2>/dev/null || true
done
for f in /tmp/openclaw-*/openclaw-*.log; do
  [ -e "\$f" ] && aws s3 cp "\$f" "\$DEST/\$(basename "\$f")" --region "\$REGION" --only-show-errors 2>/dev/null || true
done
UPLOAD
  chmod +x /usr/local/bin/openclaw-log-upload.sh
  echo '*/5 * * * * root /usr/local/bin/openclaw-log-upload.sh' > /etc/cron.d/openclaw-log-upload
  chmod 644 /etc/cron.d/openclaw-log-upload
  systemctl enable --now cron 2>/dev/null || true
  /usr/local/bin/openclaw-log-upload.sh || true   # one immediate upload
fi

###############################################################################
# 11. GitHub backup of the agent workspace (memory/config), like prod.
#     Commits ~/.openclaw/workspace and pushes to the customer's repo. Runs every 12 hours.
###############################################################################
if [ -n "${BACKUP_REPO:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  log "configuring .openclaw backup (every 12h) -> $BACKUP_REPO"

 
  mkdir -p /etc/openclaw
  BACKUP_TOKEN_FILE=/etc/openclaw/openclaw-backup.token
  ( umask 077; printf '%s' "$GITHUB_TOKEN" > "$BACKUP_TOKEN_FILE" )   # 0600 from creation (no world-readable window)
  chown "$RUN_USER:$RUN_USER" "$BACKUP_TOKEN_FILE"; chmod 600 "$BACKUP_TOKEN_FILE"

  # GIT_ASKPASS helper: username on the first prompt, token (read from the 0600 file) on the second.
  # Only the file PATH is baked in here - never the token itself.
  cat > /usr/local/bin/openclaw-backup-askpass.sh <<ASKPASS
#!/usr/bin/env bash
case "\$1" in
  *[Uu]sername*) printf '%s' "x-access-token" ;;
  *)             cat "$BACKUP_TOKEN_FILE" ;;
esac
ASKPASS
  chmod 755 /usr/local/bin/openclaw-backup-askpass.sh

  # The cron job runs as $RUN_USER, so the log must be writable by it - otherwise the
  # ">> /var/log/openclaw-backup.log" redirection fails and the job never runs.
  touch /var/log/openclaw-backup.log
  chown "$RUN_USER:$RUN_USER" /var/log/openclaw-backup.log
  chmod 644 /var/log/openclaw-backup.log

  cat > /usr/local/bin/openclaw-backup.sh <<BACKUP
#!/usr/bin/env bash
set -uo pipefail
export GIT_TERMINAL_PROMPT=0          # never block on a credential prompt - fail fast if askpass can't auth
export GIT_ASKPASS=/usr/local/bin/openclaw-backup-askpass.sh
WS="${OC_HOME}"                       # back up the WHOLE .openclaw folder (config + memory DB + workspace), not just workspace/
[ -d "\$WS" ] || exit 0
cd "\$WS" || exit 0
git config --global --add safe.directory "\$WS" 2>/dev/null || true   # ok whether run as root (boot) or ubuntu (cron)
# never commit secrets or transient / regenerable data
cat > .gitignore <<'GI'
.env
npm/
node_modules/
state/*.sqlite-wal
state/*.sqlite-shm
state/openclaw.sqlite
openclaw.json
openclaw.json.*
GI
[ -d workspace/.git ] && rm -rf workspace/.git   # drop the old per-workspace repo so the whole tree backs up as one repo
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init -q -b main 2>/dev/null || git init -q
git remote remove origin 2>/dev/null || true
git remote add origin "${BACKUP_REPO}"   # tokenless URL; auth is supplied at push time via GIT_ASKPASS
# Snapshot the live SQLite memory DB CONSISTENTLY. The gateway holds it open in WAL mode, so committing
# the live file yields torn/unrestorable images. Commit an online .backup snapshot instead (the live DB
# is gitignored above). python3 is always present, so no need for the sqlite3 CLI package.
if [ -f state/openclaw.sqlite ]; then
  python3 - <<'PY' 2>/dev/null || echo "[backup] sqlite snapshot failed (continuing)"
import sqlite3
src = sqlite3.connect("state/openclaw.sqlite")
dst = sqlite3.connect("state/openclaw.sqlite.backup")
with dst:
    src.backup(dst)
src.close(); dst.close()
PY
fi
git add -A
git -c user.email=openclaw@local -c user.name=openclaw commit -q -m "backup \$(date -u +%FT%TZ)" || true
# -f: the remote may carry the old workspace-only history; this is a one-way mirror, so force it into sync.
# credential.helper= : never let a helper cache/persist the credential anywhere.
if timeout 60 git -c credential.helper= push -f -q origin HEAD:main 2>&1 | tail -3; then
  echo "[backup \$(date -u +%FT%TZ)] push ok"
else
  echo "[backup \$(date -u +%FT%TZ)] push FAILED - check the repo exists and the backup token has push access"
fi
BACKUP
  chmod +x /usr/local/bin/openclaw-backup.sh
  chown "$RUN_USER:$RUN_USER" /usr/local/bin/openclaw-backup.sh
  # Every 12 hours (00:00 and 12:00 UTC), run as the agent user.
  echo "0 */12 * * * $RUN_USER /usr/local/bin/openclaw-backup.sh >> /var/log/openclaw-backup.log 2>&1" > /etc/cron.d/openclaw-backup
  chmod 644 /etc/cron.d/openclaw-backup
  systemctl enable --now cron 2>/dev/null || true
  # Run the first backup as $RUN_USER (same as the cron) so .git/ is owned by $RUN_USER. If root ran it,
  # the root-owned .git/ would break every later ubuntu-user cron backup (permission denied) - silently.
  sudo -u "$RUN_USER" /usr/local/bin/openclaw-backup.sh >> /var/log/openclaw-backup.log 2>&1 || true   # one immediate backup
fi

healthy=0
for _ in $(seq 1 12); do            # up to ~60s
  if systemctl is-active --quiet openclaw-gateway.service \
     && { ss -ltn 2>/dev/null | grep -q ":${GATEWAY_PORT} " \
          || timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/${GATEWAY_PORT}" 2>/dev/null; }; then
    healthy=1; break
  fi
  sleep 5
done
if [ "$healthy" != "1" ]; then
  log "gateway did NOT become healthy (inactive or not listening on ${GATEWAY_PORT}) - sentinel NOT written"
  systemctl --no-pager --full status openclaw-gateway.service 2>&1 | tail -20 || true
  [ -x /usr/local/bin/openclaw-log-upload.sh ] && /usr/local/bin/openclaw-log-upload.sh || true
  exit 1
fi
log "gateway healthy (active + listening on ${GATEWAY_PORT})"


if [ "$PROVIDER" = "anthropic" ]; then
  if timeout 90 su - "$RUN_USER" -c 'claude -p "reply with: ok"' >/tmp/oc-claudeprobe 2>&1; then
    log "auth probe: Claude OK"
  else
    log "FATAL: Claude auth probe failed (placeholder/expired token?) - sentinel NOT written: $(tail -c 200 /tmp/oc-claudeprobe 2>/dev/null | tr -cd '\11\12\15\40-\176')"
    [ -x /usr/local/bin/openclaw-log-upload.sh ] && /usr/local/bin/openclaw-log-upload.sh || true
    exit 1
  fi
fi
if [ -n "$SLACK_BOT_TOKEN" ]; then
  if [ "$(curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" https://slack.com/api/auth.test 2>/dev/null | jq -r '.ok // false' 2>/dev/null)" = "true" ]; then
    log "auth probe: Slack OK"
  else
    log "FATAL: Slack auth.test failed (invalid/placeholder bot token?) - sentinel NOT written; box not healthy"
    [ -x /usr/local/bin/openclaw-log-upload.sh ] && /usr/local/bin/openclaw-log-upload.sh || true
    exit 1
  fi
fi
# AWS profile probe is warn-only: a bad customer profile shouldn't block the bot itself, but surface it.
if [ "${WROTE_ANY:-0}" = "1" ]; then
  su - "$RUN_USER" -c "aws sts get-caller-identity --profile '$AWS_PROFILE_NAME' >/dev/null 2>&1" \
    && log "auth probe: AWS profile $AWS_PROFILE_NAME OK" \
    || log "WARN: aws sts get-caller-identity failed for profile $AWS_PROFILE_NAME (agent AWS tasks may fail)"
fi

mkdir -p "$(dirname "$SENTINEL")"; touch "$SENTINEL"
log "bootstrap done $(date -u) - tag the bot in Slack to verify."