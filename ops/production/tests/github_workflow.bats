#!/usr/bin/env bats

load test_helper

setup() {
  setup_repo_root
  CI_WORKFLOW="$REPO_ROOT/.github/workflows/server-ci.yml"
  DEPLOY_WORKFLOW="$REPO_ROOT/.github/workflows/deploy-production.yml"
}

@test "hosted workflows only dispatch exact SHA work to the server" {
  grep -Fq '"ci ${REQUESTED_SHA}"' "$CI_WORKFLOW"
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
  grep -Fq 'workflow_dispatch:' "$DEPLOY_WORKFLOW"
  grep -Fq 'branches: [main]' "$DEPLOY_WORKFLOW"
  grep -Fq 'branches: [main]' "$CI_WORKFLOW"
  ! grep -Fq 'branches-ignore:' "$CI_WORKFLOW"
}

@test "mobile platform CI is manual-only" {
  workflow="$REPO_ROOT/.github/workflows/platform-ci.yml"
  grep -Fq 'workflow_dispatch:' "$workflow"
  ! grep -Eq '^[[:space:]]+(push|pull_request):' "$workflow"
}
