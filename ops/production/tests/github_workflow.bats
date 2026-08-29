#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  CI_WORKFLOW="$REPO_ROOT/.github/workflows/server-ci.yml"
  DEPLOY_WORKFLOW="$REPO_ROOT/.github/workflows/deploy-production.yml"
}

@test "hosted workflows only dispatch exact SHA work to the server" {
  grep -Fq '"ci ${GITHUB_SHA}"' "$CI_WORKFLOW"
  grep -Fq '"deploy ${GITHUB_SHA}"' "$DEPLOY_WORKFLOW"
  ! grep -Eq 'actions/checkout|flutter-action|setup-node|npm (ci|test)|flutter (test|build)' \
    "$CI_WORKFLOW" "$DEPLOY_WORKFLOW"
}

@test "dispatch jobs are read-only, production-gated, serialized, and bounded" {
  for workflow in "$CI_WORKFLOW" "$DEPLOY_WORKFLOW"; do
    grep -Fq 'contents: read' "$workflow"
    grep -Fq 'environment: production' "$workflow"
    grep -Fq 'cancel-in-progress: false' "$workflow"
    grep -Fq 'timeout-minutes: 2' "$workflow"
  done
}

@test "SSH requires the dedicated key and pinned known host" {
  for workflow in "$CI_WORKFLOW" "$DEPLOY_WORKFLOW"; do
    grep -Fq 'MIXLI_DEPLOY_SSH_KEY' "$workflow"
    grep -Fq 'MIXLI_DEPLOY_KNOWN_HOST' "$workflow"
    grep -Fq -- '-o BatchMode=yes' "$workflow"
    grep -Fq -- '-o IdentitiesOnly=yes' "$workflow"
    grep -Fq -- '-o StrictHostKeyChecking=yes' "$workflow"
    grep -Fq -- '-o UserKnownHostsFile=' "$workflow"
    ! grep -Fq 'StrictHostKeyChecking=no' "$workflow"
  done
}

@test "automatic production deploys originate only from main" {
  grep -Fq 'branches: [main]' "$DEPLOY_WORKFLOW"
  grep -Fq 'branches: [main]' "$CI_WORKFLOW"
  ! grep -Fq 'branches-ignore:' "$CI_WORKFLOW"
}

@test "production SSH secrets are unavailable to branch-controlled manual workflows" {
  for workflow in "$CI_WORKFLOW" "$DEPLOY_WORKFLOW"; do
    ! grep -Fq 'workflow_dispatch:' "$workflow"
    grep -Fq 'branches: [main]' "$workflow"
  done
  grep -Fq 'GitHub production environment branch protection is defense in depth' \
    "$REPO_ROOT/ops/production/README.md"
}

@test "mobile platform CI is manual-only" {
  workflow="$REPO_ROOT/.github/workflows/platform-ci.yml"
  grep -Fq 'workflow_dispatch:' "$workflow"
  ! grep -Eq '^[[:space:]]+(push|pull_request):' "$workflow"
}

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
