#!/usr/bin/env bash
# Shared helpers for Compact MaaS install verify and native MaaS regression checks.
# Source from verify-guis.sh / fix-compact-maas-native-maas.sh — do not execute directly.
set -euo pipefail

compact_maas_cluster_domain() {
  oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true
}

compact_maas_gateway_url() {
  local domain="${1:-$(compact_maas_cluster_domain)}"
  [[ -n "$domain" ]] && printf 'https://maas.%s' "$domain"
}

compact_maas_oauth_issuer() {
  local domain route_host
  route_host="$(oc get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "$route_host" ]]; then
    printf 'https://%s' "$route_host"
    return 0
  fi
  domain="${1:-$(compact_maas_cluster_domain)}"
  [[ -n "$domain" ]] || return 0
  # ingresses.config domain is often apps.<cluster>; OAuth host is oauth-openshift.<same>
  if [[ "$domain" == apps.* ]]; then
    printf 'https://oauth-openshift.%s' "$domain"
  else
    printf 'https://oauth-openshift.apps.%s' "$domain"
  fi
}

# RHOAI 3.5+: maas-api in redhat-ai-gateway-infra; 3.4: redhat-ods-applications
compact_maas_maas_api_namespace() {
  if oc get deployment maas-api -n redhat-ai-gateway-infra &>/dev/null; then
    echo redhat-ai-gateway-infra
  elif oc get deployment maas-api -n redhat-ods-applications &>/dev/null; then
    echo redhat-ods-applications
  else
    echo redhat-ai-gateway-infra
  fi
}

compact_maas_bbr_anchor_present() {
  oc get envoyfilter compact-maas-bbr-anchor -n openshift-ingress &>/dev/null
}

# Pick a subscription for ephemeral key mint tests (override with COMPACT_MAAS_TEST_SUBSCRIPTION).
compact_maas_pick_test_subscription() {
  if [[ -n "${COMPACT_MAAS_TEST_SUBSCRIPTION:-}" ]]; then
    echo "$COMPACT_MAAS_TEST_SUBSCRIPTION"
    return 0
  fi

  local from_cm=""
  from_cm=$(oc get configmap compact-maas-config -n compact-maas \
    -o jsonpath='{.data.ENROLLMENT_DEFAULT_SUBSCRIPTION}' 2>/dev/null || true)
  if [[ -n "$from_cm" ]]; then
    echo "$from_cm"
    return 0
  fi

  oc get maassubscription -n models-as-a-service \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | head -1
}

# Compare Compact MaaS deployment env to live cluster domain (OAuth + gateway URL).
# Prints mismatch lines to stdout; returns 0 when OK, 1 when mismatched or unknown.
compact_maas_verify_deployment_config() {
  local ns="${1:-compact-maas}"
  local domain expected_gw expected_oauth gw_url oauth_url mismatches=0

  domain="$(compact_maas_cluster_domain)"
  if [[ -z "$domain" ]]; then
    echo "cluster domain not found (ingresses.config/cluster)"
    return 1
  fi

  expected_gw="$(compact_maas_gateway_url "$domain")"
  expected_oauth="$(compact_maas_oauth_issuer "$domain")"

  if ! oc get deploy compact-maas -n "$ns" &>/dev/null; then
    echo "deployment/compact-maas not found in ${ns}"
    return 1
  fi

  gw_url=$(oc get deploy compact-maas -n "$ns" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MAAS_GATEWAY_URL")].value}' 2>/dev/null || true)
  oauth_url=$(oc get deploy compact-maas -n "$ns" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OAUTH_ISSUER")].value}' 2>/dev/null || true)

  if [[ -z "$oauth_url" ]]; then
    oauth_url=$(oc get configmap compact-maas-config -n "$ns" \
      -o jsonpath='{.data.OAUTH_ISSUER}' 2>/dev/null || true)
  fi

  if [[ -n "$gw_url" && "$gw_url" != "$expected_gw" ]]; then
    echo "MAAS_GATEWAY_URL=${gw_url} (expected ${expected_gw})"
    mismatches=$((mismatches + 1))
  fi
  if [[ -n "$oauth_url" && "$oauth_url" != "$expected_oauth" ]]; then
    echo "OAUTH_ISSUER=${oauth_url} (expected ${expected_oauth})"
    mismatches=$((mismatches + 1))
  fi

  [[ "$mismatches" -eq 0 ]]
}

# Mint ephemeral sk-oai-* via gateway (same path Compact MaaS Keys page uses).
# Sets COMPACT_MAAS_LAST_KEY_HTTP_CODE and COMPACT_MAAS_LAST_KEY_BODY on failure.
# Returns 0 on 2xx with a key in the response body.
compact_maas_verify_native_key_mint() {
  local domain gw oc_token sub_name http_code body key_id

  COMPACT_MAAS_LAST_KEY_HTTP_CODE=""
  COMPACT_MAAS_LAST_KEY_BODY=""
  COMPACT_MAAS_LAST_KEY_ID=""
  COMPACT_MAAS_LAST_KEY_VALUE=""

  domain="$(compact_maas_cluster_domain)"
  if [[ -z "$domain" ]]; then
    COMPACT_MAAS_LAST_KEY_BODY="cluster domain not found"
    return 1
  fi

  gw="$(compact_maas_gateway_url "$domain")"
  oc_token="$(oc whoami -t 2>/dev/null || true)"
  if [[ -z "$oc_token" ]]; then
    COMPACT_MAAS_LAST_KEY_BODY="oc whoami -t failed"
    return 1
  fi

  sub_name="$(compact_maas_pick_test_subscription)"
  if [[ -z "$sub_name" ]]; then
    COMPACT_MAAS_LAST_KEY_BODY="no MaaSSubscription in models-as-a-service"
    return 1
  fi

  local tmp_body
  tmp_body="$(mktemp)"
  http_code=$(curl -sk -o "$tmp_body" -w '%{http_code}' -X POST "${gw}/maas-api/v1/api-keys" \
    -H "Authorization: Bearer ${oc_token}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"compact-maas-verify-$(date +%s)\",\"subscription\":\"${sub_name}\",\"expiresIn\":\"1h\",\"ephemeral\":true}" \
    --max-time 30 2>/dev/null || echo "000")

  body="$(cat "$tmp_body" 2>/dev/null || true)"
  rm -f "$tmp_body"

  COMPACT_MAAS_LAST_KEY_HTTP_CODE="$http_code"
  COMPACT_MAAS_LAST_KEY_BODY="$body"

  if [[ ! "$http_code" =~ ^2 ]]; then
    return 1
  fi

  if command -v python3 &>/dev/null; then
    COMPACT_MAAS_LAST_KEY_VALUE=$(printf '%s' "$body" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('key') or d.get('token') or '')" 2>/dev/null || true)
    COMPACT_MAAS_LAST_KEY_ID=$(printf '%s' "$body" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('id') or '')" 2>/dev/null || true)
  else
    COMPACT_MAAS_LAST_KEY_VALUE=$(printf '%s' "$body" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    COMPACT_MAAS_LAST_KEY_ID=$(printf '%s' "$body" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  fi

  [[ -n "$COMPACT_MAAS_LAST_KEY_VALUE" ]]
}

compact_maas_revoke_ephemeral_key() {
  local gw domain oc_token
  [[ -z "${COMPACT_MAAS_LAST_KEY_ID:-}" ]] && return 0
  domain="$(compact_maas_cluster_domain)"
  gw="$(compact_maas_gateway_url "$domain")"
  oc_token="$(oc whoami -t 2>/dev/null || true)"
  [[ -z "$oc_token" || -z "$gw" ]] && return 0
  curl -sk -X DELETE "${gw}/maas-api/v1/api-keys/${COMPACT_MAAS_LAST_KEY_ID}" \
    -H "Authorization: Bearer ${oc_token}" >/dev/null 2>&1 || true
}

# Heuristic: maas-api logs show missing username when BBR anchor strips Authorino headers.
compact_maas_maas_api_missing_username_log() {
  local ns
  ns="$(compact_maas_maas_api_namespace)"
  oc logs deployment/maas-api -n "$ns" --tail=80 2>/dev/null \
    | grep -E 'Missing or empty username header|X-MaaS-Username=absent' | tail -1 || true
}
