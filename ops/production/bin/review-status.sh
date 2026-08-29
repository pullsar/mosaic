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
