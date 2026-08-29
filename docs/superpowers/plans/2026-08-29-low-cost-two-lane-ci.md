# Low-Cost Two-Lane CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace overlapping paid GitHub builds with short trusted dispatchers, add a server-side rootless pull-request review lane, and retain a protected-main release gate plus manual/release-only iOS validation.

**Architecture:** A `pull_request_target` workflow sends only a validated PR number and exact head SHA through a review-only forced SSH command. The server verifies the freshly fetched PR ref, runs the existing comprehensive CI in a strict rootless review mode, and reports results through a least-privilege GitHub App. A single `main` dispatcher invokes deployment, which already includes release CI; macOS runs only for manual or published-release iOS checks.

**Tech Stack:** Bash 5, Bats, Git, systemd transient units, rootless Docker/RootlessKit, GitHub Actions YAML, GitHub Checks REST API, `curl`, `jq`, `openssl`, ShellCheck.

---

## File map

- Create `.github/workflows/review-dispatch.yml`: trusted PR orchestration only; no checkout or build.
- Modify `.github/workflows/deploy-production.yml`: remain the sole automatic `main` dispatcher.
- Create `.github/workflows/ios-release.yml`: manual and published-release macOS validation.
- Delete `.github/workflows/server-ci.yml`: remove duplicate automatic `main` CI dispatch.
- Delete `.github/workflows/platform-ci.yml`: replace the combined manual platform workflow with iOS-only release/manual validation.
- Create `ops/production/bin/review-dispatch`: forced command for the review-only SSH account.
- Create `ops/production/bin/review-request.sh`: validate/fetch/supersede/queue PR review jobs.
- Create `ops/production/bin/review-status.sh`: GitHub App authentication and Check Run lifecycle.
- Create `ops/production/bin/review-ci.sh`: status-aware wrapper around server CI review mode.
- Modify `ops/production/bin/server-ci.sh`: add a rootless-only review engine without weakening release mode.
- Modify `ops/production/bin/deployment-request.sh`: synchronously preempt and clean review units before production deployment.
- Modify `ops/production/bin/provision-host.sh`: install the review account, directories, sudo boundary, and rootless/status prerequisites.
- Modify `ops/production/README.md`: document GitHub App, SSH key, activation, rollback, and operator commands.
- Create `ops/production/tests/review_request.bats`: request/ref/supersession/resource-limit contracts.
- Create `ops/production/tests/review_status.bats`: GitHub App payload and fail-closed reporting contracts.
- Create `ops/production/tests/review_ci.bats`: review mode authority, lifecycle, and cleanup contracts.
- Modify `ops/production/tests/deploy_dispatch.bats`, `github_workflow.bats`, `provisioning.bats`, and `server_ci.bats`: extend existing boundaries.

All test and build commands in this plan run on `152.53.55.38`. Local commands are limited to editing, Git inspection, commits, and secure file transfer.

---

### Task 1: Lock the paid-CI workflow contract

**Files:**
- Modify: `ops/production/tests/github_workflow.bats`
- Modify: `ops/production/tests/server_ci.bats`

- [ ] **Step 1: Add failing workflow-cost tests**

Append these contracts to `ops/production/tests/github_workflow.bats`:

```bash
@test "only PR dispatch main deploy and exceptional iOS workflows remain" {
  [ -f "$REPO_ROOT/.github/workflows/review-dispatch.yml" ]
  [ -f "$REPO_ROOT/.github/workflows/deploy-production.yml" ]
  [ -f "$REPO_ROOT/.github/workflows/ios-release.yml" ]
  [ ! -e "$REPO_ROOT/.github/workflows/server-ci.yml" ]
  [ ! -e "$REPO_ROOT/.github/workflows/platform-ci.yml" ]
  [ ! -e "$REPO_ROOT/.github/workflows/ci.yml" ]
  [ ! -e "$REPO_ROOT/.github/workflows/api-ci.yml" ]
  [ ! -e "$REPO_ROOT/.github/workflows/local-recovery-ci.yml" ]
}

@test "pull request workflow is trusted orchestration only" {
  workflow="$REPO_ROOT/.github/workflows/review-dispatch.yml"
  grep -Fq 'pull_request_target:' "$workflow"
  grep -Fq 'types: [opened, synchronize, reopened, ready_for_review]' "$workflow"
  grep -Fq 'github.event.pull_request.number' "$workflow"
  grep -Fq 'github.event.pull_request.head.sha' "$workflow"
  grep -Fq 'cancel-in-progress: true' "$workflow"
  grep -Fq 'timeout-minutes: 2' "$workflow"
  grep -Fq 'MIXLI_REVIEW_SSH_KEY' "$workflow"
  ! grep -Eq 'actions/checkout|flutter-action|setup-node|npm (ci|test)|dart (test|analyze)|flutter (test|build)|pull_request\.head\.repo' "$workflow"
  ! grep -Fq 'MIXLI_DEPLOY_SSH_KEY' "$workflow"
  ! grep -Fq 'environment: production' "$workflow"
}

@test "main has exactly one automatic dispatcher" {
  matches="$(grep -RFl 'branches: [main]' "$REPO_ROOT/.github/workflows" | sort)"
  [ "$matches" = "$REPO_ROOT/.github/workflows/deploy-production.yml" ]
  grep -Fq '"deploy ${GITHUB_SHA}"' "$matches"
}

@test "iOS runs only manually or for published releases" {
  workflow="$REPO_ROOT/.github/workflows/ios-release.yml"
  grep -Fq 'workflow_dispatch:' "$workflow"
  grep -Fq 'release:' "$workflow"
  grep -Fq 'types: [published]' "$workflow"
  grep -Fq 'runs-on: macos-latest' "$workflow"
  grep -Fq 'flutter build ios --simulator --no-codesign' "$workflow"
  ! grep -Eq '^[[:space:]]+(push|pull_request|pull_request_target):' "$workflow"
  ! grep -Fq 'environment: production' "$workflow"
}
```

Add this matrix-preservation test to `ops/production/tests/server_ci.bats`:

```bash
@test "review mode retains every release validation stage" {
  script="$REPO_ROOT/ops/production/bin/server-ci.sh"
  grep -Fq 'MIXLI_CI_ENGINE_MODE' "$script"
  grep -Fq 'review' "$script"
  for stage in source-integrity infrastructure-contracts \
    api-postgres-integration flutter-workspace platform-declarations \
    production-builds; do
    grep -Fq "run_stage $stage" "$script"
  done
}
```

- [ ] **Step 2: Commit the RED contracts**

```bash
git add ops/production/tests/github_workflow.bats ops/production/tests/server_ci.bats
git commit -m "test(ci): specify low-cost workflow boundary"
```

- [ ] **Step 3: Push the tests-only commit and run RED on the server**

Use the standard key from `C:\keys\mixli-prod`, fetch the exact commit as `mixli-build`, and run:

```bash
bats ops/production/tests/github_workflow.bats ops/production/tests/server_ci.bats
```

Expected: the new workflow-set tests fail because `review-dispatch.yml` and `ios-release.yml` do not exist and the redundant workflows still exist. Existing contracts remain green.

---

### Task 2: Add the review-only SSH and exact PR-ref request boundary

**Files:**
- Create: `ops/production/bin/review-dispatch`
- Create: `ops/production/bin/review-request.sh`
- Create: `ops/production/tests/review_request.bats`
- Modify: `ops/production/tests/deploy_dispatch.bats`

- [ ] **Step 1: Write failing dispatch and request tests**

Create `ops/production/tests/review_request.bats`:

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  PR=47
  SHA=b5098ec72c804b6df97a7017681ea17b9843d73c
  REQUEST="$REPO_ROOT/ops/production/bin/review-request.sh"
}

@test "review forced command accepts only decimal PR and exact lowercase SHA" {
  run env SSH_ORIGINAL_COMMAND="review $PR $SHA" MIXLI_REVIEW_DISPATCH_TEST_MODE=1 \
    "$REPO_ROOT/ops/production/bin/review-dispatch"
  [ "$status" -eq 0 ]
  [ "$output" = "review:$PR:$SHA" ]

  for command in "review x $SHA" "review -1 $SHA" "review $PR main" \
    "review $PR ${SHA};id" "deploy $SHA" ""; do
    run env SSH_ORIGINAL_COMMAND="$command" MIXLI_REVIEW_DISPATCH_TEST_MODE=1 \
      "$REPO_ROOT/ops/production/bin/review-dispatch"
    [ "$status" -eq 64 ]
  done
}

@test "request test mode validates inputs without fetching" {
  run env MIXLI_REVIEW_REQUEST_TEST_MODE=1 "$REQUEST" "$PR" "$SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "review:$PR:$SHA" ]

  run env MIXLI_REVIEW_REQUEST_TEST_MODE=1 "$REQUEST" 0 "$SHA"
  [ "$status" -eq 64 ]
  run env MIXLI_REVIEW_REQUEST_TEST_MODE=1 "$REQUEST" "$PR" MAIN
  [ "$status" -eq 64 ]
}

@test "request fetches only the numbered PR ref and verifies exact equality" {
  grep -Fq 'fetch --force --no-tags origin "+refs/pull/$PR/head:$REVIEW_REF"' "$REQUEST"
  grep -Fq 'actual="$(builder_git -C "$REPO" rev-parse "$REVIEW_REF^{commit}")"' "$REQUEST"
  grep -Fq '[[ "$actual" == "$SHA" ]]' "$REQUEST"
  ! grep -Fq '+refs/heads/*' "$REQUEST"
  ! grep -Fq '+refs/pull/*' "$REQUEST"
}

@test "request supersedes an older PR unit and queues bounded review work" {
  grep -Fq 'flock -w 30 9' "$REQUEST"
  grep -Fq 'systemctl is-active --quiet "$previous_unit"' "$REQUEST"
  grep -Fq 'systemctl stop "$previous_unit"' "$REQUEST"
  ! grep -Fq 'systemctl stop "$previous_unit" || true' "$REQUEST"
  grep -Fq 'mixli-review-${PR}-${SHA:0:12}' "$REQUEST"
  grep -Fq -- '--property=RuntimeMaxSec=45min' "$REQUEST"
  grep -Fq -- '--property=TimeoutStopSec=2min' "$REQUEST"
  grep -Fq -- '--property=CPUQuota=600%' "$REQUEST"
  grep -Fq -- '--property=MemoryMax=12G' "$REQUEST"
  grep -Fq -- '--property=IOWeight=100' "$REQUEST"
  grep -Fq -- '--property=Nice=10' "$REQUEST"
  grep -Fq '/opt/mixli/bin/review-ci.sh "$PR" "$SHA"' "$REQUEST"
}
```

Append to `ops/production/tests/deploy_dispatch.bats`:

```bash
@test "production dispatch cannot invoke the review endpoint" {
  run env SSH_ORIGINAL_COMMAND="review 47 $SHA" MIXLI_DEPLOY_TEST_MODE=1 \
    "$REPO_ROOT/ops/production/bin/deploy-dispatch"
  [ "$status" -eq 64 ]
  ! grep -Fq 'review-request.sh' "$REPO_ROOT/ops/production/bin/deploy-dispatch"
}
```

Define `SHA` in that test using the same exact literal already used by the file.

- [ ] **Step 2: Run focused RED on the server**

```bash
bats ops/production/tests/review_request.bats ops/production/tests/deploy_dispatch.bats
```

Expected: `review_request.bats` fails because both new scripts are absent. The production-dispatch isolation test passes.

- [ ] **Step 3: Implement the forced review command**

Create `ops/production/bin/review-dispatch`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

readonly command_to_run="${SSH_ORIGINAL_COMMAND-}"

if [[ ! "$command_to_run" =~ ^review\ ([1-9][0-9]*)\ ([0-9a-f]{40})$ ]]; then
  printf '%s\n' 'Only review followed by a positive PR number and exact lowercase SHA is allowed.' >&2
  exit 64
fi

readonly pr="${BASH_REMATCH[1]}"
readonly sha="${BASH_REMATCH[2]}"

if [[ "${MIXLI_REVIEW_DISPATCH_TEST_MODE:-0}" == '1' ]]; then
  printf 'review:%s:%s\n' "$pr" "$sha"
  exit 0
fi

exec sudo -n /opt/mixli/bin/review-request.sh "$pr" "$sha"
```

- [ ] **Step 4: Implement exact-ref verification and queueing**

Create `ops/production/bin/review-request.sh` with this structure and exact constants:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly PR="${1-}"
readonly SHA="${2-}"
readonly TEST_MODE="${MIXLI_REVIEW_REQUEST_TEST_MODE:-0}"
readonly ROOT="${MIXLI_ROOT:-/srv/mixli}"
readonly REPO="${MIXLI_REPO:-/srv/mixli/repository}"
readonly REVIEW_REF="refs/mixli/reviews/$PR"
readonly REVIEW_STATE="$ROOT/state/reviews/$PR"
readonly REQUEST_LOCK="${MIXLI_REVIEW_REQUEST_LOCK:-/run/lock/mixli-review-request.lock}"
readonly UNIT="mixli-review-${PR}-${SHA:0:12}"

builder_git() { runuser -u mixli-build -- git "$@"; }

validate_inputs() {
  [[ "$PR" =~ ^[1-9][0-9]*$ ]] || exit 64
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || exit 64
}

verify_pr_ref() {
  local actual
  builder_git -C "$REPO" fetch --force --no-tags origin \
    "+refs/pull/$PR/head:$REVIEW_REF"
  actual="$(builder_git -C "$REPO" rev-parse "$REVIEW_REF^{commit}")"
  [[ "$actual" == "$SHA" ]] || exit 65
}

queue_review() {
  local previous_unit=''
  install -d -o root -g root -m 0750 "$ROOT/state/reviews" "$REVIEW_STATE"
  if [[ -f "$REVIEW_STATE/unit" ]]; then
    previous_unit="$(<"$REVIEW_STATE/unit")"
  fi
  printf '%s\n' "$SHA" >"$REVIEW_STATE/latest-sha"
  printf '%s\n' "$UNIT" >"$REVIEW_STATE/unit"
  chmod 0640 "$REVIEW_STATE/latest-sha" "$REVIEW_STATE/unit"
  if [[ -n "$previous_unit" && "$previous_unit" != "$UNIT" ]] && \
    systemctl is-active --quiet "$previous_unit"; then
    systemctl stop "$previous_unit"
  fi
  /opt/mixli/bin/review-status.sh create "$PR" "$SHA" queued
  if ! systemd-run --quiet --no-block --collect --unit="$UNIT" \
    --property=Type=exec \
    --property=RuntimeMaxSec=45min \
    --property=TimeoutStopSec=2min \
    --property=CPUQuota=600% \
    --property=MemoryMax=12G \
    --property=IOWeight=100 \
    --property=Nice=10 \
    --property=KillMode=control-group \
    /opt/mixli/bin/review-ci.sh "$PR" "$SHA"; then
    /opt/mixli/bin/review-status.sh update "$PR" "$SHA" failure || true
    return 75
  fi
  printf 'queued:%s\n' "$UNIT"
}

main() {
  validate_inputs
  if [[ "$TEST_MODE" == '1' ]]; then
    printf 'review:%s:%s\n' "$PR" "$SHA"
    return 0
  fi
  install -d -m 0750 "$(dirname "$REQUEST_LOCK")"
  exec 9>"$REQUEST_LOCK"
  flock -w 30 9 || exit 75
  verify_pr_ref
  queue_review
}

main
```

- [ ] **Step 5: Run focused GREEN and ShellCheck on the server**

```bash
bats ops/production/tests/review_request.bats ops/production/tests/deploy_dispatch.bats
shellcheck ops/production/bin/review-dispatch ops/production/bin/review-request.sh
```

Expected: all focused tests pass and ShellCheck is silent.

- [ ] **Step 6: Commit**

```bash
git add ops/production/bin/review-dispatch ops/production/bin/review-request.sh \
  ops/production/tests/review_request.bats ops/production/tests/deploy_dispatch.bats
git commit -m "feat(ci): add exact pull request dispatch boundary"
```

---

### Task 3: Report review lifecycle through a least-privilege GitHub App

**Files:**
- Create: `ops/production/bin/review-status.sh`
- Create: `ops/production/tests/review_status.bats`

- [ ] **Step 1: Write failing status-payload tests**

Create `ops/production/tests/review_status.bats`:

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  STATUS="$REPO_ROOT/ops/production/bin/review-status.sh"
  PR=47
  SHA=b5098ec72c804b6df97a7017681ea17b9843d73c
}

@test "status helper accepts only known lifecycle transitions" {
  run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" create "$PR" "$SHA" queued
  [ "$status" -eq 0 ]
  jq -e '.state == "queued"' <<<"$output" >/dev/null

  for state in in_progress success failure cancelled timed_out; do
    run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" update "$PR" "$SHA" "$state"
    [ "$status" -eq 0 ]
    jq -e --arg state "$state" '.state == $state' <<<"$output" >/dev/null
  done
  run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" create "$PR" "$SHA" success
  [ "$status" -eq 64 ]
  run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" update "$PR" "$SHA" queued
  [ "$status" -eq 64 ]
  run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" update "$PR" "$SHA" neutral
  [ "$status" -eq 64 ]
}

@test "completed payload maps state to an explicit conclusion" {
  run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" update "$PR" "$SHA" timed_out
  [ "$status" -eq 0 ]
  jq -e '.status == "completed" and .conclusion == "timed_out"' <<<"$output" >/dev/null

  run env MIXLI_REVIEW_STATUS_TEST_MODE=1 "$STATUS" update "$PR" "$SHA" failure
  jq -e '.status == "completed" and .conclusion == "failure"' <<<"$output" >/dev/null
}

@test "GitHub App credentials remain root-only and outside checkout" {
  grep -Fq '/etc/mixli/github/app-id' "$STATUS"
  grep -Fq '/etc/mixli/github/installation-id' "$STATUS"
  grep -Fq '/etc/mixli/github/private-key.pem' "$STATUS"
  ! grep -Fq 'GITHUB_TOKEN' "$STATUS"
  ! grep -Fq 'MIXLI_DEPLOY' "$STATUS"
}

@test "API failures use bounded retries and fail nonzero" {
  grep -Fq 'for attempt in 1 2 3 4 5' "$STATUS"
  grep -Fq 'sleep "$attempt"' "$STATUS"
  grep -Fq 'return 75' "$STATUS"
}
```

- [ ] **Step 2: Run RED on the server**

```bash
bats ops/production/tests/review_status.bats
```

Expected: all tests fail because `review-status.sh` does not exist.

- [ ] **Step 3: Implement deterministic payload and GitHub App authentication**

Create `ops/production/bin/review-status.sh`. The implementation must:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly ACTION="${1-}"
readonly PR="${2-}"
readonly SHA="${3-}"
readonly STATE="${4-}"
readonly TEST_MODE="${MIXLI_REVIEW_STATUS_TEST_MODE:-0}"
readonly APP_ID_FILE="${MIXLI_GITHUB_APP_ID_FILE:-/etc/mixli/github/app-id}"
readonly INSTALLATION_ID_FILE="${MIXLI_GITHUB_INSTALLATION_ID_FILE:-/etc/mixli/github/installation-id}"
readonly PRIVATE_KEY_FILE="${MIXLI_GITHUB_PRIVATE_KEY_FILE:-/etc/mixli/github/private-key.pem}"
readonly STATE_ROOT="${MIXLI_ROOT:-/srv/mixli}/state/reviews/$PR"
readonly API='https://api.github.com/repos/pullsar/mosaic'

[[ "$ACTION" == create || "$ACTION" == update ]] || exit 64
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || exit 64
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || exit 64
case "$ACTION:$STATE" in
  create:queued|update:in_progress|update:success|update:failure|update:cancelled|update:timed_out) ;;
  *) exit 64 ;;
esac

payload() {
  case "$ACTION:$STATE" in
    create:queued)
      jq -nc --arg sha "$SHA" --arg state "$STATE" --arg external "review-$PR-$SHA" \
        '{name:"mixli-server-review",head_sha:$sha,external_id:$external,status:$state}'
      ;;
    update:in_progress)
      jq -nc '{status:"in_progress",started_at:(now|todateiso8601)}'
      ;;
    *)
      jq -nc --arg state "$STATE" \
        '{status:"completed",conclusion:$state,completed_at:(now|todateiso8601)}'
      ;;
  esac
}

if [[ "$TEST_MODE" == '1' ]]; then
  jq -c --arg state "$STATE" '. + {state:$state}' <<<"$(payload)"
  exit 0
fi
```

After the deterministic section, add these fixed helpers:

```bash
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

app_jwt() {
  local now unsigned signature
  now="$(date +%s)"
  unsigned="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url).$(
    jq -nc --argjson iat "$((now - 60))" --argjson exp "$((now + 540))" \
      --arg iss "$(<"$APP_ID_FILE")" '{iat:$iat,exp:$exp,iss:$iss}' | b64url
  )"
  signature="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" | b64url)"
  printf '%s.%s' "$unsigned" "$signature"
}

installation_token() {
  curl --fail --silent --show-error --request POST \
    --header "Authorization: Bearer $(app_jwt)" \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/app/installations/$(<"$INSTALLATION_ID_FILE")/access_tokens" |
    jq -er '.token'
}

api_call() {
  local method="$1" endpoint="$2" body="$3" attempt token response
  for attempt in 1 2 3 4 5; do
    token="$(installation_token)" || { sleep "$attempt"; continue; }
    if response="$(curl --fail --silent --show-error --request "$method" \
      --header "Authorization: Bearer $token" \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --data "$body" "$API/$endpoint")"; then
      printf '%s' "$response"
      return 0
    fi
    sleep "$attempt"
  done
  return 75
}
```

Finish the script with the exact serialized create/update flow:

```bash
install -d -o root -g root -m 0750 "$(dirname "$STATE_ROOT")" "$STATE_ROOT" /srv/mixli/log
exec 9>"$STATE_ROOT/status.lock"
flock -w 30 9 || exit 75

body="$(payload)"
if [[ "$ACTION" == create ]]; then
  response="$(api_call POST check-runs "$body")"
  check_id="$(jq -er '.id | numbers' <<<"$response")"
  printf '%s\n' "$check_id" >"$STATE_ROOT/check-id"
  chmod 0640 "$STATE_ROOT/check-id"
else
  [[ -f "$STATE_ROOT/check-id" ]] || exit 66
  check_id="$(<"$STATE_ROOT/check-id")"
  [[ "$check_id" =~ ^[1-9][0-9]*$ ]] || exit 66
  api_call PATCH "check-runs/$check_id" "$body" >/dev/null
fi

printf '%s:%s:%s:%s:%s\n' \
  "$ACTION" "$PR" "$SHA" "$STATE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >>/srv/mixli/log/review-events.log
```

- [ ] **Step 4: Run focused GREEN and ShellCheck on the server**

```bash
bats ops/production/tests/review_status.bats
shellcheck ops/production/bin/review-status.sh
```

Expected: all tests pass; ShellCheck is silent.

- [ ] **Step 5: Commit**

```bash
git add ops/production/bin/review-status.sh ops/production/tests/review_status.bats
git commit -m "feat(ci): report isolated review checks"
```

---

### Task 4: Add a rootless-only review engine without weakening release CI

**Files:**
- Create: `ops/production/bin/review-ci.sh`
- Create: `ops/production/tests/review_ci.bats`
- Modify: `ops/production/bin/server-ci.sh`
- Modify: `ops/production/bin/deployment-request.sh`
- Modify: `ops/production/tests/ci_request.bats`
- Modify: `ops/production/tests/server_ci.bats`

- [ ] **Step 1: Write failing review-engine contracts**

Create `ops/production/tests/review_ci.bats`:

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  REVIEW="$REPO_ROOT/ops/production/bin/review-ci.sh"
  SERVER="$REPO_ROOT/ops/production/bin/server-ci.sh"
  PR=47
  SHA=b5098ec72c804b6df97a7017681ea17b9843d73c
}

@test "review wrapper selects only review engine mode" {
  grep -Fq 'MIXLI_CI_ENGINE_MODE=review' "$REVIEW"
  grep -Fq '/opt/mixli/bin/server-ci.sh "$checkout" "$SHA"' "$REVIEW"
  ! grep -Eq 'deployment|promote|MIXLI_CI_RETAIN_RELEASE_IMAGES=1' "$REVIEW"
}

@test "review mode makes rootless Docker authoritative before candidate builds" {
  prepare="$(sed -n '/^prepare_ci_engine()/,/^}/p' "$SERVER")"
  [[ "$prepare" == *'start_rootless_docker'* ]]
  [[ "$prepare" == *'export DOCKER_HOST="unix://$rootless_runtime/docker.sock"'* ]]
  [[ "$prepare" == *'docker info'* ]]
  [[ "$prepare" == *'name=rootless'* ]]
  [[ "$prepare" != *'docker save'* ]]
  [[ "$prepare" != *'docker load'* ]]
}

@test "release mode retains exact rootful to rootless image identity verification" {
  grep -Fq 'load_rootless_candidate_images' "$SERVER"
  grep -Fq '[[ "$rootful_id" == "$rootless_id" ]]' "$SERVER"
  grep -Fq 'MIXLI_CI_ENGINE_MODE:-release' "$SERVER"
}

@test "review cleanup removes daemon checkout and fetched ref" {
  grep -Fq 'stop_rootless_docker' "$REVIEW"
  grep -Fq 'worktree remove --force "$checkout"' "$REVIEW"
  grep -Fq '"$(<"$state/latest-sha")" == "$SHA"' "$REVIEW"
  grep -Fq 'update-ref -d "refs/mixli/reviews/$PR"' "$REVIEW"
  grep -Fq 'cleanup failure' "$REVIEW"
}

@test "review lifecycle distinguishes success failure cancellation and timeout" {
  for state in in_progress success failure cancelled timed_out; do
    grep -Fq "review-status.sh update" "$REVIEW"
    grep -Fq "$state" "$REVIEW"
  done
  grep -Fq 'trap on_term TERM INT' "$REVIEW"
  grep -Fq 'timeout --signal=TERM --kill-after=30s 44m' "$REVIEW"
  grep -Fq 'latest-sha' "$REVIEW"
}
```

Extend `server_ci.bats` so the test-mode helper passes `MIXLI_CI_ENGINE_MODE`, rejects any value other than `release` or `review`, and asserts review mode never requests candidate retention.

Append to `ci_request.bats`:

```bash
@test "production deployment synchronously preempts review units" {
  request="$REPO_ROOT/ops/production/bin/deployment-request.sh"
  stop_line="$(grep -n "systemctl stop 'mixli-review-*'" "$request" | cut -d: -f1)"
  queue_line="$(grep -n 'systemd-run --quiet' "$request" | cut -d: -f1)"
  [ -n "$stop_line" ]
  [ -n "$queue_line" ]
  [ "$stop_line" -lt "$queue_line" ]
  ! grep -Fq "systemctl stop 'mixli-review-*' || true" "$request"
}
```

- [ ] **Step 2: Run focused RED on the server**

```bash
bats ops/production/tests/review_ci.bats ops/production/tests/server_ci.bats
```

Expected: review tests fail because the wrapper and mode do not exist; existing release contracts remain green.

- [ ] **Step 3: Refactor `server-ci.sh` around an explicit engine mode**

Add:

```bash
readonly ENGINE_MODE="${MIXLI_CI_ENGINE_MODE:-release}"
```

Extend `validate_inputs`:

```bash
[[ "$ENGINE_MODE" == release || "$ENGINE_MODE" == review ]] || die_usage
if [[ "$ENGINE_MODE" == review && "$RETAIN_RELEASE_IMAGES_REQUESTED" != '0' ]]; then
  die_usage
fi
```

Create `prepare_ci_engine`:

```bash
prepare_ci_engine() {
  if [[ "$ENGINE_MODE" == review ]]; then
    start_rootless_docker
    export DOCKER_HOST="unix://$rootless_runtime/docker.sock"
    docker info --format '{{json .SecurityOptions}}' | grep -Fq 'name=rootless'
    [[ "$(docker info --format '{{.DockerRootDir}}')" == "$rootless_data" ]]
  fi
}
```

Call it after `source_integrity` and before any `docker build`. In `infrastructure_contracts`, keep current rootful build, private-daemon startup, and `load_rootless_candidate_images` only for `release`. For `review`, build the same exact tags directly after `DOCKER_HOST` points at the private daemon, skip save/load, keep the daemon alive through every stage, and use that daemon for all later Docker commands. Release mode keeps its existing tag retention and promotion contract unchanged.

Change the current unconditional rootless stop at the end of `infrastructure_contracts` to:

```bash
if [[ "$ENGINE_MODE" == release ]]; then
  stop_rootless_docker
fi
```

The EXIT cleanup remains responsible for the review daemon and must preserve an earlier test failure while surfacing cleanup failure on otherwise successful CI.

For review mode, remove the review candidate tags while the private socket still exists, then call `stop_rootless_docker`; skip the later rootful exact-tag cleanup branch. For release mode, retain the current order and strict rootful CI-tag cleanup. This prevents cleanup from trying to reach a private socket after it has been deleted.

- [ ] **Step 4: Implement the lifecycle wrapper**

Create `ops/production/bin/review-ci.sh` with exact validation and lifecycle logic:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly PR="${1-}"
readonly SHA="${2-}"
readonly ROOT="${MIXLI_ROOT:-/srv/mixli}"
readonly REPO="${MIXLI_REPO:-/srv/mixli/repository}"
readonly checkout="$ROOT/builds/review-$PR-$SHA"
readonly state="$ROOT/state/reviews/$PR"
conclusion=failure
cleanup_status=0

builder_git() { runuser -u mixli-build -- git "$@"; }

on_term() {
  conclusion=cancelled
  exit 143
}

cleanup() {
  local original="$1"
  trap - EXIT TERM INT
  set +e
  if [[ -e "$checkout/.git" ]]; then
    builder_git -C "$REPO" worktree remove --force "$checkout" || cleanup_status=$?
  fi
  if [[ -f "$state/latest-sha" && "$(<"$state/latest-sha")" == "$SHA" ]]; then
    builder_git -C "$REPO" update-ref -d "refs/mixli/reviews/$PR" || cleanup_status=$?
  fi
  if [[ "$cleanup_status" -ne 0 ]]; then
    printf '%s\n' 'review cleanup failure' >&2
    conclusion=failure
  fi
  if [[ -f "$state/latest-sha" && "$(<"$state/latest-sha")" != "$SHA" ]]; then
    conclusion=cancelled
  elif [[ "$original" -eq 124 || "$original" -eq 143 ]]; then
    conclusion=$([[ "$original" -eq 124 ]] && printf timed_out || printf cancelled)
  elif [[ "$original" -eq 0 && "$cleanup_status" -eq 0 ]]; then
    conclusion=success
  fi
  /opt/mixli/bin/review-status.sh update "$PR" "$SHA" "$conclusion" || exit 75
  [[ "$original" -ne 0 ]] && exit "$original"
  exit "$cleanup_status"
}

main() {
  [[ "$PR" =~ ^[1-9][0-9]*$ ]] || exit 64
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || exit 64
  trap on_term TERM INT
  trap 'cleanup $?' EXIT
  /opt/mixli/bin/review-status.sh update "$PR" "$SHA" in_progress
  install -d -o mixli-build -g mixli-build -m 0750 "$ROOT/builds"
  builder_git -C "$REPO" worktree add --detach "$checkout" "$SHA"
  set +e
  timeout --signal=TERM --kill-after=30s 44m \
    env MIXLI_CI_ENGINE_MODE=review MIXLI_CI_RETAIN_RELEASE_IMAGES=0 \
      /opt/mixli/bin/server-ci.sh "$checkout" "$SHA"
  result=$?
  set -e
  exit "$result"
}

main
```

- [ ] **Step 5: Preempt review CI before queuing production deployment**

In `deployment-request.sh`, after input validation and before `systemd-run`, add:

```bash
if [[ "$TEST_MODE" != '1' ]]; then
  systemctl stop 'mixli-review-*'
fi
```

The command is intentionally synchronous and fail-closed. A review unit's TERM trap reports cancellation and completes cleanup before deployment is queued.

- [ ] **Step 6: Run GREEN contracts and a live rootless review on the server**

Run static/focused validation first:

```bash
bats ops/production/tests/review_ci.bats ops/production/tests/server_ci.bats \
  ops/production/tests/ci_request.bats
shellcheck ops/production/bin/review-ci.sh ops/production/bin/server-ci.sh \
  ops/production/bin/deployment-request.sh
```

Then install the exact branch versions to a temporary root-owned validation path and run `review-ci.sh` against a non-main exact SHA whose PR ref was fetched by `review-request.sh`. Expected:

- every existing CI stage passes;
- Docker reports `name=rootless` and the exact private data root;
- no rootful review images or containers appear;
- production stack and timers remain unchanged; and
- no rootless process, socket, data root, checkout, or review ref remains.

- [ ] **Step 7: Commit**

```bash
git add ops/production/bin/review-ci.sh ops/production/bin/server-ci.sh \
  ops/production/bin/deployment-request.sh ops/production/tests/review_ci.bats \
  ops/production/tests/server_ci.bats ops/production/tests/ci_request.bats
git commit -m "feat(ci): run pull requests in rootless review mode"
```

---

### Task 5: Provision the review identity and GitHub App boundary

**Files:**
- Modify: `ops/production/bin/provision-host.sh`
- Modify: `ops/production/tests/provisioning.bats`
- Modify: `ops/production/README.md`

- [ ] **Step 1: Write failing provisioning contracts**

Append to `provisioning.bats`:

```bash
@test "provisioning installs isolated review identity and state boundaries" {
  root="$TEST_ROOT/root"
  mkdir -p "$root"
  env MIXLI_PROVISION_TEST_MODE=1 MIXLI_PROVISION_ROOT="$root" \
    "$REPO_ROOT/ops/production/bin/provision-host.sh"

  [ -x "$root/opt/mixli/bin/review-dispatch" ]
  [ -x "$root/opt/mixli/bin/review-request.sh" ]
  [ -x "$root/opt/mixli/bin/review-status.sh" ]
  [ -x "$root/opt/mixli/bin/review-ci.sh" ]
  [ "$(stat -c '%u:%g:%a' "$root/etc/mixli/github")" = '0:0:750' ]
  [ "$(stat -c '%u:%g:%a' "$root/srv/mixli/state/reviews")" = '0:0:750' ]
}

@test "review sudo rule grants only the fixed request entrypoint" {
  script="$REPO_ROOT/ops/production/bin/provision-host.sh"
  grep -Fq 'mixli-review ALL=(root) NOPASSWD: /opt/mixli/bin/review-request.sh *' "$script"
  ! grep -Eq 'mixli-review.*(deployment|ci-request|/bin/bash|ALL$)' "$script"
}

@test "GitHub App private key is never sourced from repository examples" {
  script="$REPO_ROOT/ops/production/bin/provision-host.sh"
  ! grep -Eq 'private-key\.pem.*(cp|install).*SOURCE_ROOT' "$script"
  grep -Fq '/etc/mixli/github' "$script"
}
```

- [ ] **Step 2: Run provisioning RED on the server**

```bash
bats ops/production/tests/provisioning.bats
```

Expected: new identity/directory/sudo tests fail while existing provisioning tests remain green.

- [ ] **Step 3: Implement provisioning changes**

In `install_layout`, create these exact boundaries:

```bash
install -d -o root -g root -m 0750 "$(target /etc/mixli/github)"
install -d -o root -g root -m 0750 "$(target /srv/mixli/state/reviews)"
```

In `configure_host`, add:

```bash
ensure_account mixli-review /var/lib/mixli-review /bin/bash
printf '%s\n' \
  'mixli-review ALL=(root) NOPASSWD: /opt/mixli/bin/review-request.sh *' \
  >/etc/sudoers.d/92-mixli-review
chmod 0440 /etc/sudoers.d/92-mixli-review
visudo -cf /etc/sudoers.d/92-mixli-review
```

Do not add `mixli-review` to `docker`, sudo-capable groups, or `mixli-build`. Do not create a private-key placeholder that might overwrite the live GitHub App key on reprovisioning.

- [ ] **Step 4: Document exact activation and rollback**

Add a README section containing:

- GitHub App permissions: Metadata read and Checks write only; installation limited to `pullsar/mosaic`.
- root-only files and modes:

```bash
install -d -o root -g root -m 0750 /etc/mixli/github
install -o root -g root -m 0644 app-id /etc/mixli/github/app-id
install -o root -g root -m 0644 installation-id /etc/mixli/github/installation-id
install -o root -g root -m 0600 private-key.pem /etc/mixli/github/private-key.pem
```

- review SSH key installation with forced command:

```text
command="/opt/mixli/bin/review-dispatch",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding ssh-ed25519 <review-public-key>
```

- repository secrets `MIXLI_REVIEW_SSH_KEY` and `MIXLI_REVIEW_KNOWN_HOST` are separate from production secrets.
- branch protection requires the `mixli-server-review` Check Run before merge and retains protected `main` restrictions.
- operator commands to view `mixli-review-*` units and `/srv/mixli/log/review-events.log`.
- rollback: disable `review-dispatch.yml`, remove the review authorized key, stop `mixli-review-*` units, verify cleanup, and retain the protected-main deploy path.

- [ ] **Step 5: Run GREEN and ShellCheck on the server**

```bash
bats ops/production/tests/provisioning.bats
shellcheck ops/production/bin/provision-host.sh
```

Expected: all tests pass and no live GitHub App key is created or overwritten.

- [ ] **Step 6: Commit**

```bash
git add ops/production/bin/provision-host.sh ops/production/tests/provisioning.bats \
  ops/production/README.md
git commit -m "ops(ci): provision isolated review authority"
```

---

### Task 6: Replace overlapping GitHub workflows

**Files:**
- Create: `.github/workflows/review-dispatch.yml`
- Create: `.github/workflows/ios-release.yml`
- Delete: `.github/workflows/server-ci.yml`
- Delete: `.github/workflows/platform-ci.yml`
- Verify absent: `.github/workflows/ci.yml`
- Verify absent: `.github/workflows/api-ci.yml`
- Verify absent: `.github/workflows/local-recovery-ci.yml`
- Modify: `ops/production/tests/github_workflow.bats`

- [ ] **Step 1: Create the trusted review dispatcher**

Create `.github/workflows/review-dispatch.yml`:

```yaml
name: review-dispatch

on:
  pull_request_target:
    types: [opened, synchronize, reopened, ready_for_review]

concurrency:
  group: mixli-review-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  dispatch:
    if: github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    timeout-minutes: 2
    env:
      PR_NUMBER: ${{ github.event.pull_request.number }}
      HEAD_SHA: ${{ github.event.pull_request.head.sha }}
    steps:
      - name: Validate immutable request identity
        shell: bash
        run: |
          [[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]
          [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]
      - name: Install review-only identity
        env:
          REVIEW_KEY: ${{ secrets.MIXLI_REVIEW_SSH_KEY }}
          REVIEW_KNOWN_HOST: ${{ secrets.MIXLI_REVIEW_KNOWN_HOST }}
        run: |
          install -d -m 0700 "$HOME/.ssh"
          install -m 0600 /dev/null "$HOME/.ssh/mixli-review"
          install -m 0600 /dev/null "$HOME/.ssh/known_hosts"
          printf '%s\n' "$REVIEW_KEY" >"$HOME/.ssh/mixli-review"
          printf '%s\n' "$REVIEW_KNOWN_HOST" >"$HOME/.ssh/known_hosts"
      - name: Queue isolated server review
        run: >-
          ssh -i "$HOME/.ssh/mixli-review"
          -o BatchMode=yes
          -o IdentitiesOnly=yes
          -o StrictHostKeyChecking=yes
          -o UserKnownHostsFile="$HOME/.ssh/known_hosts"
          mixli-review@152.53.55.38 "review ${PR_NUMBER} ${HEAD_SHA}"
```

- [ ] **Step 2: Create exceptional iOS validation**

Create `.github/workflows/ios-release.yml`:

```yaml
name: ios-release

on:
  workflow_dispatch:
  release:
    types: [published]

concurrency:
  group: ios-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  simulator:
    runs-on: macos-latest
    timeout-minutes: 30
    steps:
      - name: Checkout release or selected manual ref
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ github.event_name == 'release' && github.event.release.tag_name || github.ref }}
      - name: Flutter
        uses: subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2 # v2
        with:
          flutter-version: '3.44.7'
          cache: true
      - name: Resolve locked workspace
        run: flutter pub get --enforce-lockfile
      - name: Build iOS simulator host
        working-directory: apps/mosaic_app
        run: flutter build ios --simulator --no-codesign
```

- [ ] **Step 3: Remove redundant workflows**

Delete `server-ci.yml` and `platform-ci.yml`. Confirm the three branch-heavy workflow files remain absent. Do not modify `deploy-production.yml` beyond formatting unless the contract test identifies a real deviation.

- [ ] **Step 4: Run GREEN workflow contracts on the server**

```bash
bats ops/production/tests/github_workflow.bats
python3 - <<'PY'
from pathlib import Path
import yaml
for path in Path('.github/workflows').glob('*.yml'):
    yaml.safe_load(path.read_text())
    print(path)
PY
```

Expected: all workflow tests pass and every YAML file parses.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows ops/production/tests/github_workflow.bats
git commit -m "ci: dispatch reviews to isolated server runner"
```

---

### Task 7: Full server verification, external activation, and final review

**Files:**
- Verify all files changed in Tasks 1–6
- Update only if a verification failure has a corresponding new RED regression test

- [ ] **Step 1: Run the complete exact-SHA server contract suite**

From a clean exact checkout owned by `mixli-build`, run:

```bash
bats ops/production/tests/*.bats
shellcheck ops/production/bin/*.sh ops/production/bin/deploy-dispatch \
  ops/production/bin/review-dispatch
docker compose --env-file ops/production/env/production.env.example \
  -f ops/production/compose.yaml config --quiet
```

Also run the existing systemd, Prometheus, Alertmanager, Nginx, README Bash-fence, R2, rootless candidate, and cleanup validators used by `server-ci.sh`. Expected: all pass with no warning or skipped suite.

- [ ] **Step 2: Run a real non-main rootless review on the server**

Install the exact branch scripts to `/opt/mixli/bin`, provision the review account, and invoke `review-request.sh <pr> <sha>` for a real PR ref. Verify:

- the request returns within seconds;
- the transient unit has CPUQuota `600%`, MemoryMax `12G`, IOWeight `100`, Nice `10`, and 45-minute timeout;
- all CI stages execute using the private rootless daemon;
- no rootful candidate tag is created by review mode;
- the GitHub Check Run reaches success; and
- all private daemon, checkout, ref, image, network, volume, and process artifacts are absent afterward.

- [ ] **Step 3: Prove supersession and fail-closed behavior**

Queue two exact SHAs for the same PR in order. Expected: the older unit stops, cleans up, and reports cancelled; the newer unit remains authoritative. Then inject one controlled stage failure and one cleanup failure through existing test-mode hooks. Expected: both checks conclude failure and production remains unchanged.

- [ ] **Step 4: Verify production isolation**

Record before/after evidence for:

```bash
docker ps --format '{{.Names}} {{.Image}} {{.Status}}'
systemctl is-active mixli-stack.service
systemctl is-active mixli-backup-full.timer mixli-backup-incr.timer \
  mixli-backup-check.timer mixli-restore-verify.timer
nft list table inet mixli_cloudflare
```

Expected: review CI does not start, stop, recreate, publish, or modify production services, timers, images, secrets, data, or firewall rules.

- [ ] **Step 5: Run independent reviews**

Use the subagent-driven workflow:

1. Spec-compliance review against `docs/superpowers/specs/2026-08-29-low-cost-two-lane-ci-design.md`.
2. Code-quality/security review focused on `pull_request_target`, forced commands, rootless authority, GitHub App permissions, status races, cancellation, cleanup, and release regression.
3. Fix every finding with a new failing server test before implementation.
4. Re-run both reviews until approved.

- [ ] **Step 6: Commit any verification-driven fixes and push the feature branch**

```bash
git status --short
git diff --check
git push -u origin codex/low-cost-two-lane-ci
```

Expected: clean worktree, pushed exact head, no force push.

- [ ] **Step 7: Integrate using the finishing-branch workflow**

After all tests and reviews pass, present the four standard choices: local merge, pull request, keep branch, or discard. Do not push `main` or trigger production deployment without the user's integration choice.

After integration to `main`, the single main dispatcher runs the protected release gate. Verify the server audit log and deployment health before declaring rollout complete.
