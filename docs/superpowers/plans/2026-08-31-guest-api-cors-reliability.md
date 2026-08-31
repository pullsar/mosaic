# Guest API CORS Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the production Flutter web guest feed by injecting the exact Mixli web-origin allowlist into every API replica and proving browser preflight through both origin and Cloudflare deployment checks.

**Architecture:** Keep the API's existing deny-by-default exact-origin CORS hook. Production Compose owns an overrideable default for the apex and redirect host, while the production verifier exercises the same `OPTIONS` request Flutter web sends before guest actor registration. No Flutter, feed, ranking, credential, or Cloudflare routing behavior changes.

**Tech Stack:** Docker Compose, Bash, Bats, jq, curl, Fastify CORS hook, server-hosted CI/deployment runners.

---

### Task 1: Lock the production browser-origin contract

**Files:**
- Modify: `ops/production/tests/compose_config.bats`
- Modify: `ops/production/tests/verify_script.bats`

- [ ] **Step 1: Add the failing Compose contract**

Append a Bats test that requires every API replica to receive the exact production default:

```bash
@test "all API replicas receive the strict Mixli browser origin allowlist" {
  run jq -e '
    . as $cfg |
    ["api-blue-1", "api-blue-2", "api-green-1", "api-green-2"] | all(
      . as $service |
      $cfg.services[$service].environment.MOSAIC_WEB_ORIGINS ==
        "https://mixli.app,https://www.mixli.app"
    )
  ' <<<"$CONFIG_JSON"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Add the failing verifier contract**

Update the expected test-mode totals to `9 passed, 0 failed` for origin and `4 passed, 0 failed` for public, update the forced-failure total to `8 passed, 1 failed`, and add:

```bash
@test "production verifier proves the Flutter web actor preflight" {
  check="$(sed -n '/^check_guest_browser_api()/,/^}/p' "$VERIFY")"
  [[ "$check" == *'curl_preflight_headers api.mixli.app /v1/actors'* ]]
  [[ "$check" == *'https://mixli.app'* ]]
  [[ "$check" == *'access-control-allow-origin'* ]]
  [[ "$check" == *'authorization'* ]]
  [[ "$check" == *'content-type'* ]]
}
```

- [ ] **Step 3: Run the focused tests on the server and prove RED**

Push the test-only commit to `codex/fix-guest-cors`, fetch its exact SHA into a disposable server checkout, and run:

```bash
bats ops/production/tests/compose_config.bats ops/production/tests/verify_script.bats
```

Expected: the new Compose allowlist test fails because `MOSAIC_WEB_ORIGINS` is absent, and the verifier test fails because no browser preflight check exists.

- [ ] **Step 4: Commit the failing regression tests**

```bash
git add ops/production/tests/compose_config.bats ops/production/tests/verify_script.bats
git commit -m "test(prod): require guest browser API preflight"
```

### Task 2: Inject and verify the exact production origins

**Files:**
- Modify: `ops/production/compose.yaml`
- Modify: `ops/production/env/production.env.example`
- Modify: `ops/production/bin/verify-production.sh`

- [ ] **Step 1: Inject the strict overrideable allowlist**

Add this to the shared API environment mapping in Compose:

```yaml
MOSAIC_WEB_ORIGINS: ${MOSAIC_WEB_ORIGINS:-https://mixli.app,https://www.mixli.app}
```

Add the matching operator-visible default to `production.env.example`:

```dotenv
MOSAIC_WEB_ORIGINS=https://mixli.app,https://www.mixli.app
```

- [ ] **Step 2: Add a production browser-preflight probe**

Add `curl_preflight_headers()` beside the existing curl helpers. It must issue `OPTIONS`, send origin `https://mixli.app`, request `POST`, request `content-type,authorization`, use the origin CA/resolve path in origin mode, and use the public URL in public mode.

Add `check_guest_browser_api()` that parses response headers case-insensitively and requires:

```text
Access-Control-Allow-Origin: https://mixli.app
Access-Control-Allow-Headers: ...content-type...authorization...
```

Register `run_check 'guest browser API' check_guest_browser_api` in both verifier modes.

- [ ] **Step 3: Run the focused tests on the server and prove GREEN**

In a disposable exact-head server checkout, run:

```bash
bats ops/production/tests/compose_config.bats ops/production/tests/verify_script.bats
shellcheck ops/production/bin/verify-production.sh
docker compose --env-file ops/production/env/production.env.example \
  -f ops/production/compose.yaml config --quiet
```

Expected: all focused checks pass.

- [ ] **Step 4: Commit the implementation**

```bash
git add ops/production/compose.yaml ops/production/env/production.env.example \
  ops/production/bin/verify-production.sh
git commit -m "fix(prod): allow Mixli guest browser API access"
```

### Task 3: Validate, merge, deploy, and reproduce a real guest feed

**Files:**
- Verify only: repository authoritative gates and production runtime

- [ ] **Step 1: Run the exact release CI lane on the server**

Push the branch and invoke the existing exact-SHA server review/release runner. Expected: infrastructure contracts, API tests, Flutter tests, web release build, and all checked-in release gates pass without running heavy tests on the local PC.

- [ ] **Step 2: Review the final diff**

Review `origin/main...HEAD` for security, reliability, test, and deployment regressions. Confirm there is no wildcard CORS, credential mode, unrelated UI change, or secret material.

- [ ] **Step 3: Merge and push the exact reviewed head to `main`**

Fast-forward or merge only after exact-head CI is green, then verify `origin/main` resolves to the intended SHA.

- [ ] **Step 4: Deploy through the root-owned runner**

Invoke `/opt/mixli/bin/deployment.sh <exact-main-sha>`. Expected: both API replicas are recreated with the allowlist, the browser-preflight verifier passes before completion, and the deployment records the exact SHA.

- [ ] **Step 5: Verify the live guest exchange through Cloudflare**

Run a public preflight and then use a disposable actor ID/token to perform:

```text
POST /v1/actors -> 200 or 201
POST /v1/feed   -> 200 with at least one Play
```

Also require the origin verifier, public verifier, release header, and current pool health to pass. Do not log or persist the disposable actor token.

- [ ] **Step 6: Confirm production evidence**

Confirm the public preflight returns the exact apex allow-origin header, a new feed decision exists, and the response's Play document decodes against the web capability envelope. Report the deployed SHA and evidence without exposing credentials or environment secrets.
