# Mobile Release Lane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Android release assembly to a manual/published-release GitHub workflow, keep web/API deployment gated by the complete server lane, and remove the unused Android toolchain from the server CI image.

**Architecture:** The production server remains authoritative for infrastructure, API/PostgreSQL, Dart/Flutter tests, Chrome behavior, platform declarations, and the production web build. A least-privilege GitHub-hosted job builds an APK only for an explicit ref or published release, while the server Flutter image becomes web/browser-only and retains no Android SDK, NDK, CMake, Java, production credential, or deployment authority.

**Tech Stack:** GitHub Actions YAML, Flutter 3.44.7, Bash 5, Bats, Docker, systemd transient units, Git.

---

## File map

- Create `.github/workflows/android-release.yml`: isolated manual/published-release APK validation and bounded artifact upload.
- Modify `ops/production/tests/github_workflow.bats`: specify Android triggers, exact-ref checkout, pinned toolchain/actions, artifact retention, and least privilege.
- Modify `ops/production/tests/server_ci.bats`: prove the server still builds web and never invokes APK assembly.
- Modify `ops/production/tests/flutter_image.bats`: replace obsolete Android/CMake probes with a web/browser-only image contract.
- Modify `ops/production/bin/server-ci.sh`: remove APK assembly and its artifact assertion while preserving all other stages.
- Modify `ops/production/flutter/Dockerfile`: remove the Android SDK, NDK, CMake, Java, Android precache, and their environment paths.
- Modify `ops/production/README.md`: document the web/API and exceptional mobile lane boundary.
- Modify `docs/event-delivery.md`: correct the stale claim that Android/iOS builds are merge gates.
- Modify `docs/m2-consumer-runtime-client-plan.md`: correct the stale platform-workflow trigger description.

All tests, image builds, and application builds run on `152.53.55.38`. Local work is limited to editing, Git inspection, commits, and pushes.

---

### Task 1: Lock the new workflow and server boundaries with failing contracts

**Files:**
- Modify: `ops/production/tests/github_workflow.bats`
- Modify: `ops/production/tests/server_ci.bats`
- Modify: `ops/production/tests/flutter_image.bats`

- [ ] **Step 1: Add the Android workflow path to test setup**

Add this assignment beside the existing workflow paths in `setup()`:

```bash
ANDROID_WORKFLOW="$REPO_ROOT/.github/workflows/android-release.yml"
```

- [ ] **Step 2: Expand the mobile and workflow-set contracts**

Replace the existing mobile trigger test with:

```bash
@test "mobile platform CI is manual or release-only" {
  for workflow in "$ANDROID_WORKFLOW" "$IOS_WORKFLOW"; do
    grep -Fq 'workflow_dispatch:' "$workflow"
    grep -Fq 'release:' "$workflow"
    grep -Fq 'types: [published]' "$workflow"
    ! grep -Eq '^[[:space:]]+(push|pull_request|pull_request_target):' "$workflow"
    ! grep -Fq 'environment: production' "$workflow"
  done
}
```

Rename the workflow-set test to `only dispatch and exceptional mobile workflows remain` and add:

```bash
[ -f "$REPO_ROOT/.github/workflows/android-release.yml" ]
```

Extend `production SSH secrets are unavailable to branch-controlled manual workflows` with:

```bash
! grep -Fq 'MIXLI_DEPLOY_' "$ANDROID_WORKFLOW"
! grep -Fq 'MIXLI_REVIEW_' "$ANDROID_WORKFLOW"
```

- [ ] **Step 3: Add the complete Android workflow contract**

Append this test to `ops/production/tests/github_workflow.bats`:

```bash
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
```

- [ ] **Step 4: Replace the server APK requirement with an exclusion contract**

Remove `'flutter build apk --release'` from the `required` loop in `covers infrastructure API Flutter and production build checks`, then append:

```bash
@test "server release gate builds web but excludes Android artifact assembly" {
  workspace="$(sed -n '/^flutter_workspace()/,/^}/p' \
    "$REPO_ROOT/ops/production/bin/server-ci.sh")"
  [[ "$workspace" == *'flutter build web --release --pwa-strategy=none'* ]]
  [[ "$workspace" != *'flutter build apk'* ]]
  [[ "$workspace" != *'app-release.apk'* ]]
}
```

- [ ] **Step 5: Replace the server image Android probe with a web-only contract**

Replace `pins the Android and browser toolchain inside the Flutter image` in `ops/production/tests/flutter_image.bats` with two separate static/runtime contracts:

```bash
@test "server Flutter Dockerfile contains browser tooling but no mobile build toolchain" {
  grep -Fq 'CHROME_EXECUTABLE=/usr/local/bin/chromium-ci' "$DOCKERFILE"
  grep -Fq -- '--no-sandbox' "$DOCKERFILE"
  grep -Fq 'flutter precache --web' "$DOCKERFILE"

  run grep -Eq \
    'ANDROID_CMDLINE_TOOLS|ANDROID_(HOME|SDK_ROOT)|JAVA_HOME|openjdk-|cmake/|ndk/|precache --web --android' \
    "$DOCKERFILE"
  [ "$status" -eq 1 ]
}

@test "server Flutter image exposes browser tooling without mobile environment" {
  run docker run --rm "$IMAGE" bash -lc '
    test -z "${ANDROID_HOME:-}"
    test -z "${ANDROID_SDK_ROOT:-}"
    test -z "${JAVA_HOME:-}"
    test ! -e /opt/android-sdk
    test -x "$CHROME_EXECUTABLE"
    "$CHROME_EXECUTABLE" --version
  '
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 6: Commit and push the RED contracts**

```bash
git add ops/production/tests/github_workflow.bats \
  ops/production/tests/server_ci.bats \
  ops/production/tests/flutter_image.bats
git commit -m "test(ci): specify exceptional Android release lane"
git push origin codex/low-cost-two-lane-ci
```

- [ ] **Step 7: Run only the new contracts on the server and verify RED**

In a root shell on `152.53.55.38`:

```bash
branch=codex/low-cost-two-lane-ci
repo=/srv/mixli/repository
sudo -u mixli-build git -C "$repo" fetch --force --no-tags origin "$branch"
sha="$(sudo -u mixli-build git -C "$repo" rev-parse FETCH_HEAD)"
test_root="$(mktemp -d /tmp/mixli-mobile-red.XXXXXX)"
sudo -u mixli-build git -C "$repo" archive "$sha" | tar -x -C "$test_root"
cd "$test_root"
bats --filter 'mobile platform CI|only dispatch and exceptional|Android builds only' \
  ops/production/tests/github_workflow.bats
bats --filter 'server release gate builds web' ops/production/tests/server_ci.bats
bats --filter 'server Flutter Dockerfile contains browser tooling' \
  ops/production/tests/flutter_image.bats
```

Expected: the workflow contracts fail because `android-release.yml` is absent; the server and image contracts fail because APK assembly and the Android toolchain are still present. Remove only the validated `test_root` created by `mktemp` after recording the failures.

```bash
cd /
case "$test_root" in
  /tmp/mixli-mobile-red.*) rm -rf -- "$test_root" ;;
  *) exit 70 ;;
esac
```

---

### Task 2: Add the exceptional Android workflow

**Files:**
- Create: `.github/workflows/android-release.yml`

- [ ] **Step 1: Create the manual/published-release workflow**

Create `.github/workflows/android-release.yml` with:

```yaml
name: android-release

on:
  workflow_dispatch:
    inputs:
      ref:
        description: Exact branch, tag, or commit to build
        required: true
        default: main
        type: string
  release:
    types: [published]

concurrency:
  group: android-${{ github.event_name == 'release' && github.event.release.tag_name || inputs.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  apk:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - name: Checkout release or selected manual ref
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ github.event_name == 'release' && github.event.release.tag_name || inputs.ref }}
          persist-credentials: false
      - name: Flutter
        uses: subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2 # v2
        with:
          flutter-version: '3.44.7'
          cache: true
      - name: Resolve locked workspace
        run: flutter pub get --enforce-lockfile
      - name: Build Android release validation artifact
        working-directory: apps/mosaic_app
        run: |
          flutter build apk --release
          test -f build/app/outputs/flutter-apk/app-release.apk
      - name: Upload Android validation artifact
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: mixli-android-apk
          path: apps/mosaic_app/build/app/outputs/flutter-apk/app-release.apk
          if-no-files-found: error
          retention-days: 7
```

- [ ] **Step 2: Push the implementation and rerun the workflow contracts on the server**

```bash
git add .github/workflows/android-release.yml
git commit -m "ci: add exceptional Android release workflow"
git push origin codex/low-cost-two-lane-ci
```

In a root shell on `152.53.55.38`, fetch and extract the new exact branch head:

```bash
branch=codex/low-cost-two-lane-ci
repo=/srv/mixli/repository
sudo -u mixli-build git -C "$repo" fetch --force --no-tags origin "$branch"
sha="$(sudo -u mixli-build git -C "$repo" rev-parse FETCH_HEAD)"
test_root="$(mktemp -d /tmp/mixli-android-workflow.XXXXXX)"
sudo -u mixli-build git -C "$repo" archive "$sha" | tar -x -C "$test_root"
cd "$test_root"
bats --filter 'mobile platform CI|only dispatch and exceptional|Android builds only' \
  ops/production/tests/github_workflow.bats
cd /
case "$test_root" in
  /tmp/mixli-android-workflow.*) rm -rf -- "$test_root" ;;
  *) exit 70 ;;
esac
```

Expected: all selected workflow contracts pass without starting an Android build.

---

### Task 3: Remove Android assembly and tooling from the server lane

**Files:**
- Modify: `ops/production/bin/server-ci.sh`
- Modify: `ops/production/flutter/Dockerfile`

- [ ] **Step 1: Remove only APK assembly from `flutter_workspace()`**

Make the end of the Flutter command block exactly:

```bash
     (cd packages/platform_flutter && flutter test)
     (cd apps/mosaic_app && flutter test)
     (cd apps/mosaic_app && flutter build web --release --pwa-strategy=none)'
```

Keep the web artifact copy, `platform_declarations()`, and every stage in `main()` unchanged.

- [ ] **Step 2: Remove the Android-only image dependencies**

In `ops/production/flutter/Dockerfile`:

- keep `ARG FLUTTER_VERSION` and `ARG FLUTTER_SHA256`;
- remove both `ANDROID_CMDLINE_TOOLS` arguments;
- remove `openjdk-21-jdk-headless` from the package install;
- remove the Android command-line tools download and SDK install `RUN` blocks;
- remove `ANDROID_HOME`, `ANDROID_SDK_ROOT`, and `JAVA_HOME` from `ENV`;
- remove Android directories from `PATH`; and
- replace the Flutter configuration/precache command with:

```dockerfile
RUN flutter config --no-analytics --enable-web --no-enable-android \
    && flutter precache --web
```

The retained environment block must be:

```dockerfile
ENV HOME=/home/flutter \
    PUB_CACHE=/home/flutter/.pub-cache \
    CHROME_EXECUTABLE=/usr/local/bin/chromium-ci \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/home/flutter/.pub-cache/bin:${PATH}
```

- [ ] **Step 3: Commit and push the minimal server implementation**

```bash
git add ops/production/bin/server-ci.sh ops/production/flutter/Dockerfile
git commit -m "perf(ci): make server Flutter lane web-only"
git push origin codex/low-cost-two-lane-ci
```

- [ ] **Step 4: Run focused GREEN verification on the server**

In a root shell on `152.53.55.38`, fetch and extract the new exact branch head, then build the image there:

```bash
branch=codex/low-cost-two-lane-ci
repo=/srv/mixli/repository
sudo -u mixli-build git -C "$repo" fetch --force --no-tags origin "$branch"
sha="$(sudo -u mixli-build git -C "$repo" rev-parse FETCH_HEAD)"
test_root="$(mktemp -d /tmp/mixli-mobile-green.XXXXXX)"
sudo -u mixli-build git -C "$repo" archive "$sha" | tar -x -C "$test_root"
cd "$test_root"
docker build -f ops/production/flutter/Dockerfile \
  -t mixli-flutter-builder:mobile-lane-test .
MIXLI_FLUTTER_IMAGE=mixli-flutter-builder:mobile-lane-test \
  bats ops/production/tests/flutter_image.bats
bats ops/production/tests/server_ci.bats
bats ops/production/tests/github_workflow.bats
```

Expected: every selected Bats suite passes. The image build contains no Android SDK download or Android precache stage.

- [ ] **Step 5: Remove the temporary image on the server**

```bash
docker image rm mixli-flutter-builder:mobile-lane-test
cd /
case "$test_root" in
  /tmp/mixli-mobile-green.*) rm -rf -- "$test_root" ;;
  *) exit 70 ;;
esac
```

Expected: the exact temporary tag is removed; production tags are untouched.

---

### Task 4: Align operator and platform documentation

**Files:**
- Modify: `ops/production/README.md`
- Modify: `docs/event-delivery.md`
- Modify: `docs/m2-consumer-runtime-client-plan.md`

- [ ] **Step 1: Replace the CI lane summary in the production runbook**

Replace the sentence ending `iOS simulator validation runs only manually or when a release is published.` with:

```text
The server release gate covers infrastructure, API/PostgreSQL, Dart/Flutter and
Chrome tests, platform declarations, and the production web build. Android APK
and iOS simulator validation run only by manual dispatch or when a release is
published; those workflows have no production environment, credentials, or
deployment authority. Their artifacts validate compilation but do not prove
production store signing or publication.
```

- [ ] **Step 2: Correct stale merge-gate descriptions**

In `docs/event-delivery.md`, replace the sentence beginning `Repository CI covers` with:

```text
Repository and server CI cover the shared runtime, HTTP classification, native
SQLite reuse, stable event IDs, offline -> reopen -> online drain, IndexedDB
durability in Chrome, and the production web build as merge/deployment gates.
Android release and iOS simulator builds run only by manual dispatch or for a
published release. API CI verifies exact event retry remains idempotent in
PostgreSQL.
```

In `docs/m2-consumer-runtime-client-plan.md`, replace `web/Android/iOS release builds pass because touched paths trigger platform CI;` with:

```text
the server-gated web release build passes, and manually requested or published-release Android/iOS validation passes when a mobile artifact is required;
```

- [ ] **Step 3: Check documentation consistency without building locally**

```bash
rg -n "Android release|Android APK|iOS simulator|platform CI" \
  ops/production/README.md docs/event-delivery.md \
  docs/m2-consumer-runtime-client-plan.md \
  docs/superpowers/specs/2026-08-31-mobile-release-lane-design.md
git diff --check
```

Expected: current documentation consistently describes exceptional mobile workflows, and `git diff --check` is silent.

- [ ] **Step 4: Commit and push documentation**

```bash
git add ops/production/README.md docs/event-delivery.md \
  docs/m2-consumer-runtime-client-plan.md
git commit -m "docs(ci): document exceptional mobile release checks"
git push origin codex/low-cost-two-lane-ci
```

---

### Task 5: Run the complete exact-SHA server gate

**Files:**
- Verify only; no repository changes.

- [ ] **Step 1: Create an exact detached server checkout**

On `152.53.55.38`:

```bash
branch=codex/low-cost-two-lane-ci
repo=/srv/mixli/repository
sudo -u mixli-build git -C "$repo" fetch --force --no-tags origin "$branch"
sha="$(sudo -u mixli-build git -C "$repo" rev-parse FETCH_HEAD)"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]]
checkout="/srv/mixli/builds/$sha"
if [[ ! -e "$checkout" ]]; then
  sudo -u mixli-build git -C "$repo" worktree add --detach "$checkout" "$sha"
fi
test "$(sudo -u mixli-build git -C "$checkout" rev-parse HEAD)" = "$sha"
```

- [ ] **Step 2: Run the candidate server runner in a bounded transient unit**

```bash
unit="mixli-manual-ci-${sha:0:12}"
systemd-run --unit="$unit" --collect --wait \
  --property=Type=exec \
  --property=TimeoutStartSec=45min \
  "$checkout/ops/production/bin/server-ci.sh" "$checkout" "$sha"
journalctl -u "$unit" --no-pager
```

Expected: all host/container Bats contracts, API/PostgreSQL integration, Dart/Flutter/Chrome suites, platform declarations, and `flutter build web --release` pass. No `flutter build apk` or Gradle/CMake APK stage appears.

- [ ] **Step 3: Verify deterministic cleanup**

```bash
systemctl list-units --all 'mixli-manual-ci-*'
docker ps --filter "name=mixli-ci-${sha:0:12}"
docker network ls --filter "name=mixli-ci-${sha:0:12}"
docker volume ls --filter "name=${sha:0:12}"
```

Expected: no active manual CI unit, exact-SHA CI container, CI network, or CI volume remains. Record the unit exit status and exact SHA as release evidence.

---

### Task 6: Review, install, integrate, and deploy the exact protected-main SHA

**Files:**
- Review and deployment only; repository changes occur only if review finds a defect.

- [ ] **Step 1: Run final repository checks without local builds**

```bash
git diff origin/main...HEAD --check
git status --short --branch
git log --oneline origin/main..HEAD
```

Expected: clean worktree, no whitespace errors, and only the intended mobile-lane commits.

- [ ] **Step 2: Perform the required code-review workflow**

Use `superpowers:requesting-code-review` against `origin/main...HEAD`. Resolve every correctness, security, reliability, or cost regression and rerun Task 5 if executable files change.

- [ ] **Step 3: Use the finishing-branch workflow for integration choice**

Use `superpowers:finishing-a-development-branch` and present its integration options. Do not push or merge protected `main` without the user's selected integration action.

- [ ] **Step 4: Install the validated runner immediately before the selected integration**

Only after the user selects an integration action that will update protected `main`, install the exact candidate runner on the server before that update can trigger the automatic deployment workflow:

```bash
branch=codex/low-cost-two-lane-ci
repo=/srv/mixli/repository
sudo -u mixli-build git -C "$repo" fetch --force --no-tags origin "$branch"
candidate_sha="$(sudo -u mixli-build git -C "$repo" rev-parse FETCH_HEAD)"
[[ "$candidate_sha" =~ ^[0-9a-f]{40}$ ]]
candidate_checkout="/srv/mixli/builds/$candidate_sha"
test "$(sudo -u mixli-build git -C "$candidate_checkout" rev-parse HEAD)" = \
  "$candidate_sha"
backup="/opt/mixli/bin/server-ci.sh.pre-${candidate_sha:0:12}"
install -o root -g root -m 0755 /opt/mixli/bin/server-ci.sh "$backup"
install -o root -g root -m 0755 \
  "$candidate_checkout/ops/production/bin/server-ci.sh" \
  /opt/mixli/bin/server-ci.sh
test "$(sha256sum /opt/mixli/bin/server-ci.sh | cut -d' ' -f1)" = \
  "$(sha256sum "$candidate_checkout/ops/production/bin/server-ci.sh" | cut -d' ' -f1)"
```

Expected: the installed root-owned runner is byte-identical to the exact branch head that passed Task 5, so the impending protected-main deployment cannot invoke the obsolete APK stage. If integration is abandoned, restore the recoverable exact backup with `install -o root -g root -m 0755 "$backup" /opt/mixli/bin/server-ci.sh`.

- [ ] **Step 5: Complete the selected integration and resolve protected main**

Execute the integration action selected in Step 3. Then, on the server:

```bash
repo=/srv/mixli/repository
sudo -u mixli-build git -C "$repo" fetch --prune origin main
main_sha="$(sudo -u mixli-build git -C "$repo" rev-parse origin/main)"
[[ "$main_sha" =~ ^[0-9a-f]{40}$ ]]
candidate_tree="$(sudo -u mixli-build git -C "$repo" rev-parse "$candidate_sha^{tree}")"
main_tree="$(sudo -u mixli-build git -C "$repo" rev-parse "$main_sha^{tree}")"
test "$candidate_tree" = "$main_tree"
```

Expected: protected `main` has the exact reviewed tree. A merge or squash commit may give `main_sha` a different identity; the deployment gate must therefore validate `main_sha` independently. If the trees differ because `main` advanced concurrently, reconcile that new state and rerun the affected review and server checks before deployment.

- [ ] **Step 6: Observe or manually request the exact deployment**

If the protected-main dispatcher has not already queued the deployment:

```bash
sudo /opt/mixli/bin/deployment-request.sh "$main_sha"
```

Then monitor:

```bash
unit="mixli-deploy-${main_sha:0:12}.service"
journalctl -u "$unit" -f
```

Expected: exact-SHA CI passes, candidate images are retained and promoted, migrations and candidate health checks pass, traffic switches atomically, and rollback remains armed until public verification succeeds.

- [ ] **Step 7: Verify the running application and release evidence**

```bash
/opt/mixli/bin/verify-production.sh origin
/opt/mixli/bin/verify-production.sh public
curl --fail --silent --show-error https://mixli.app/health
curl --fail --silent --show-error https://mixli.app/ready
tail -n 5 /srv/mixli/log/deploy-events.log
```

Expected: origin and public verification pass, both health endpoints return success, and the deployment audit log records `deployed:$main_sha` for the protected-main commit.

- [ ] **Step 8: Complete the verification workflow**

Use `superpowers:verification-before-completion`. Report the exact commit, server gate result, deployment unit result, public/origin health result, and confirmation that Android is now exceptional/manual or published-release-only.
