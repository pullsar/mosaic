#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  REVIEW_WORKFLOW="$REPO_ROOT/.github/workflows/review-dispatch.yml"
  DEPLOY_WORKFLOW="$REPO_ROOT/.github/workflows/deploy-production.yml"
  ANDROID_WORKFLOW="$REPO_ROOT/.github/workflows/android-release.yml"
  IOS_WORKFLOW="$REPO_ROOT/.github/workflows/ios-release.yml"
}

@test "hosted workflows only dispatch exact SHA work to the server" {
  grep -Fq '"review ${PR_NUMBER} ${HEAD_SHA}"' "$REVIEW_WORKFLOW"
  grep -Fq '"deploy ${GITHUB_SHA}"' "$DEPLOY_WORKFLOW"
  ! grep -Eq 'actions/checkout|flutter-action|setup-node|npm (ci|test)|flutter (test|build)' \
    "$REVIEW_WORKFLOW" "$DEPLOY_WORKFLOW"
}

@test "dispatch jobs are read-only, production-gated, serialized, and bounded" {
  for workflow in "$REVIEW_WORKFLOW" "$DEPLOY_WORKFLOW"; do
    grep -Fq 'contents: read' "$workflow"
    grep -Fq 'timeout-minutes: 2' "$workflow"
  done
  grep -Fq 'cancel-in-progress: true' "$REVIEW_WORKFLOW"
  ! grep -Fq 'environment: production' "$REVIEW_WORKFLOW"
  grep -Fq 'environment: production' "$DEPLOY_WORKFLOW"
  grep -Fq 'cancel-in-progress: false' "$DEPLOY_WORKFLOW"
}

@test "SSH lanes require separate dedicated keys and pinned known hosts" {
  grep -Fq 'MIXLI_REVIEW_SSH_KEY' "$REVIEW_WORKFLOW"
  grep -Fq 'MIXLI_REVIEW_KNOWN_HOST' "$REVIEW_WORKFLOW"
  ! grep -Fq 'MIXLI_DEPLOY_SSH_KEY' "$REVIEW_WORKFLOW"
  grep -Fq 'MIXLI_DEPLOY_SSH_KEY' "$DEPLOY_WORKFLOW"
  grep -Fq 'MIXLI_DEPLOY_KNOWN_HOST' "$DEPLOY_WORKFLOW"
  ! grep -Fq 'MIXLI_REVIEW_SSH_KEY' "$DEPLOY_WORKFLOW"
  for workflow in "$REVIEW_WORKFLOW" "$DEPLOY_WORKFLOW"; do
    grep -Fq -- '-o BatchMode=yes' "$workflow"
    grep -Fq -- '-o IdentitiesOnly=yes' "$workflow"
    grep -Fq -- '-o StrictHostKeyChecking=yes' "$workflow"
    grep -Fq -- '-o UserKnownHostsFile=' "$workflow"
    ! grep -Fq 'StrictHostKeyChecking=no' "$workflow"
  done
}

@test "automatic production deploys originate only from main" {
  grep -Fq 'branches: [main]' "$DEPLOY_WORKFLOW"
  grep -Fq 'pull_request_target:' "$REVIEW_WORKFLOW"
  ! grep -Eq '^[[:space:]]+push:' "$REVIEW_WORKFLOW"
}

@test "production SSH secrets are unavailable to branch-controlled manual workflows" {
  ! grep -Fq 'workflow_dispatch:' "$DEPLOY_WORKFLOW"
  grep -Fq 'branches: [main]' "$DEPLOY_WORKFLOW"
  ! grep -Fq 'MIXLI_DEPLOY_' "$REVIEW_WORKFLOW"
  ! grep -Fq 'MIXLI_DEPLOY_' "$ANDROID_WORKFLOW"
  ! grep -Fq 'MIXLI_REVIEW_' "$ANDROID_WORKFLOW"
  ! grep -Fq 'MIXLI_DEPLOY_' "$IOS_WORKFLOW"
  grep -Fq 'GitHub production environment branch protection is defense in depth' \
    "$REPO_ROOT/ops/production/README.md"
}

@test "mobile platform CI is manual or release-only" {
  for workflow in "$ANDROID_WORKFLOW" "$IOS_WORKFLOW"; do
    grep -Fq 'workflow_dispatch:' "$workflow"
    grep -Fq 'release:' "$workflow"
    grep -Fq 'types: [published]' "$workflow"
    ! grep -Eq '^[[:space:]]+(push|pull_request|pull_request_target):' "$workflow"
    ! grep -Fq 'environment: production' "$workflow"
  done
}

@test "only dispatch and exceptional mobile workflows remain" {
  [ -f "$REPO_ROOT/.github/workflows/review-dispatch.yml" ]
  [ -f "$REPO_ROOT/.github/workflows/deploy-production.yml" ]
  [ -f "$REPO_ROOT/.github/workflows/android-release.yml" ]
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

@test "Android builds only an exact requested release artifact with least privilege" {
  workflow="$ANDROID_WORKFLOW"
  grep -Fq 'contents: read' "$workflow"
  grep -Fq 'runs-on: ubuntu-latest' "$workflow"
  grep -Fq 'timeout-minutes: 30' "$workflow"
  grep -Fq "github.event_name == 'release' && github.event.release.tag_name || inputs.ref" "$workflow"
  grep -Fq "default: main" "$workflow"
  grep -Fq "flutter-version: '3.44.7'" "$workflow"
  grep -Fq 'flutter pub get --enforce-lockfile' "$workflow"
  grep -Fq 'flutter build apk --release' "$workflow"
  grep -Fq 'test -f build/app/outputs/flutter-apk/app-release.apk' "$workflow"
  grep -Fq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$workflow"
  grep -Fq 'path: apps/mosaic_app/build/app/outputs/flutter-apk/app-release.apk' "$workflow"
  grep -Fq 'if-no-files-found: error' "$workflow"
  grep -Fq 'retention-days: 7' "$workflow"
  grep -Fq 'persist-credentials: false' "$workflow"
  ! grep -Eq 'secrets\.|MIXLI_(DEPLOY|REVIEW|R2|DATABASE|CLOUDFLARE)' "$workflow"
}
