#!/usr/bin/env bash
set -euo pipefail

# Example certmgr renewal script for Azure DNS + Azure Key Vault.
# Prereqs on VM:
# - certbot
# - python3-certbot-dns-azure
# - az CLI
# - Managed identity with:
#   - DNS Zone Contributor on the target DNS zone
#   - Key Vault Certificates Officer on the target Key Vault

LE_EMAIL="${LE_EMAIL:-}"
PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-}"
ADDITIONAL_DOMAINS_CSV="${ADDITIONAL_DOMAINS_CSV:-}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-}"
KEY_VAULT_CERT_NAME="${KEY_VAULT_CERT_NAME:-}"

if [[ -z "${LE_EMAIL}" || -z "${PRIMARY_DOMAIN}" || -z "${KEY_VAULT_NAME}" || -z "${KEY_VAULT_CERT_NAME}" ]]; then
  echo "Missing required variables: LE_EMAIL, PRIMARY_DOMAIN, KEY_VAULT_NAME, KEY_VAULT_CERT_NAME"
  exit 1
fi

az login --identity >/dev/null

domains=("-d" "${PRIMARY_DOMAIN}")
IFS=',' read -r -a san_array <<< "${ADDITIONAL_DOMAINS_CSV}"
for d in "${san_array[@]}"; do
  trimmed="$(echo "${d}" | xargs)"
  if [[ -n "${trimmed}" ]]; then
    domains+=("-d" "${trimmed}")
  fi
done

certbot certonly \
  --non-interactive \
  --agree-tos \
  --email "${LE_EMAIL}" \
  --dns-azure \
  --preferred-challenges dns \
  "${domains[@]}"

pem_path="/etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem"
key_path="/etc/letsencrypt/live/${PRIMARY_DOMAIN}/privkey.pem"
pfx_path="/tmp/${PRIMARY_DOMAIN}.pfx"

openssl pkcs12 -export \
  -out "${pfx_path}" \
  -inkey "${key_path}" \
  -in "${pem_path}" \
  -password pass:

az keyvault certificate import \
  --vault-name "${KEY_VAULT_NAME}" \
  --name "${KEY_VAULT_CERT_NAME}" \
  --file "${pfx_path}" \
  --password ""

echo "Certificate renewed and imported to Key Vault."
