#!/usr/bin/env bash
# Seed the homelab-wildcard TLS secret into gateway-system before cert-manager
# runs, preventing Let's Encrypt rate-limit exhaustion on cluster rebuilds.
#
# Behaviour:
#   Valid cert in certs/   → seed directly into the cluster.
#   Missing/expiring cert  → issue via Let's Encrypt (certbot + Cloudflare
#                            DNS-01), write to certs/, then seed.
#
# Prerequisites for issuance:
#   certbot installed:              brew install certbot
#   Cloudflare plugin installed:    pip install certbot-dns-cloudflare
#   Cloudflare token (one of):
#     CF_API_TOKEN env var
#     VAULT_ADDR + VAULT_TOKEN  (reads cloudflare/api-token from Vault)
#
# To refresh certs/ after cert-manager renews in-cluster:
#   kubectl get secret -n gateway-system homelab-wildcard-tls \
#     -o jsonpath='{.data.tls\.crt}' | base64 -d > certs/fullchain.pem
#   kubectl get secret -n gateway-system homelab-wildcard-tls \
#     -o jsonpath='{.data.tls\.key}' | base64 -d > certs/privkey.pem

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="$REPO_ROOT/certs"
FULLCHAIN="$CERT_DIR/fullchain.pem"
PRIVKEY="$CERT_DIR/privkey.pem"
DOMAIN="homelab.xiehang.com"
NAMESPACE="gateway-system"
SECRET_NAME="homelab-wildcard-tls"
EMAIL="xiehang@gmail.com"
RENEW_THRESHOLD_DAYS=30

log() { printf '[seed-certs] %s\n' "$*"; }

cert_valid() {
    [[ -f "$FULLCHAIN" && -f "$PRIVKEY" ]] || return 1
    openssl x509 -in "$FULLCHAIN" -noout \
        -checkend $(( RENEW_THRESHOLD_DAYS * 86400 )) 2>/dev/null || return 1
    local cert_pub key_pub
    cert_pub=$(openssl x509 -in "$FULLCHAIN" -noout -pubkey 2>/dev/null)
    key_pub=$(openssl pkey -in "$PRIVKEY" -pubout 2>/dev/null)
    [[ "$cert_pub" == "$key_pub" ]]
}

resolve_cf_token() {
    if [[ -n "${CF_API_TOKEN:-}" ]]; then
        echo "$CF_API_TOKEN"
        return
    fi
    if command -v vault >/dev/null 2>&1 \
       && [[ -n "${VAULT_ADDR:-}" && -n "${VAULT_TOKEN:-}" ]]; then
        vault kv get -field=api-token cloudflare/api-token
        return
    fi
    log "ERROR: set CF_API_TOKEN, or set VAULT_ADDR + VAULT_TOKEN to read from Vault." >&2
    exit 1
}

issue_cert() {
    log "Issuing new certificate from Let's Encrypt (Cloudflare DNS-01)..."
    command -v certbot >/dev/null 2>&1 \
        || { log "ERROR: certbot not found (brew install certbot)" >&2; exit 1; }
    python3 -c "import certbot_dns_cloudflare" 2>/dev/null \
        || { log "ERROR: certbot-dns-cloudflare not found (pip install certbot-dns-cloudflare)" >&2; exit 1; }

    local cf_token
    cf_token=$(resolve_cf_token)

    local cf_creds
    cf_creds=$(mktemp)
    chmod 600 "$cf_creds"
    printf 'dns_cloudflare_api_token = %s\n' "$cf_token" >"$cf_creds"
    # shellcheck disable=SC2064
    trap "rm -f '$cf_creds'" EXIT

    local certbot_dir="$CERT_DIR/.certbot"
    mkdir -p "$certbot_dir"

    certbot certonly \
        --non-interactive \
        --agree-tos \
        --email "$EMAIL" \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$cf_creds" \
        -d "*.${DOMAIN}" -d "${DOMAIN}" \
        --config-dir "$certbot_dir" \
        --work-dir  "$certbot_dir/work" \
        --logs-dir  "$certbot_dir/logs"

    local live_dir
    live_dir=$(find "$certbot_dir/live" -maxdepth 1 -mindepth 1 -type d \
                   ! -name README | head -1)
    cp "$live_dir/fullchain.pem" "$FULLCHAIN"
    cp "$live_dir/privkey.pem"   "$PRIVKEY"
    log "Certificate written to $CERT_DIR"
}

seed_cluster() {
    log "Seeding $SECRET_NAME into $NAMESPACE..."
    kubectl create namespace "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl create secret tls "$SECRET_NAME" \
        --namespace "$NAMESPACE" \
        --cert="$FULLCHAIN" --key="$PRIVKEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    log "Secret ${NAMESPACE}/${SECRET_NAME} applied."
}

mkdir -p "$CERT_DIR"

if cert_valid; then
    log "Valid certificate found in certs/ (≥${RENEW_THRESHOLD_DAYS}d remaining)."
else
    log "No valid certificate in certs/; issuing from Let's Encrypt."
    issue_cert
fi

seed_cluster
