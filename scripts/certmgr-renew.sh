#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${CERTMGR_ENV_FILE:-/opt/certmgr/certmgr.env}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

LE_EMAIL="${LE_EMAIL:-}"
PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-}"
ADDITIONAL_DOMAINS_CSV="${ADDITIONAL_DOMAINS_CSV:-}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-}"
KEY_VAULT_RESOURCE_GROUP="${KEY_VAULT_RESOURCE_GROUP:-}"
KEY_VAULT_CERT_NAME="${KEY_VAULT_CERT_NAME:-}"
KEY_VAULT_SECRET_NAME="${KEY_VAULT_SECRET_NAME:-}"
KEY_VAULT_ACCESS_MODE="${KEY_VAULT_ACCESS_MODE:-}"
KEY_VAULT_PRIVATE_DNS_ZONE_RESOURCE_GROUP="${KEY_VAULT_PRIVATE_DNS_ZONE_RESOURCE_GROUP:-}"
PRIMARY_HOSTNAME="${PRIMARY_HOSTNAME:-}"
INCLUDE_WILDCARD_HOSTNAME="${INCLUDE_WILDCARD_HOSTNAME:-true}"
DNS_ZONE_NAME="${DNS_ZONE_NAME:-}"
DNS_ZONE_RESOURCE_GROUP="${DNS_ZONE_RESOURCE_GROUP:-}"
CONFIG_SECRET_NAME="${CONFIG_SECRET_NAME:-cert-runner-config}"
STATUS_SECRET_NAME="${STATUS_SECRET_NAME:-cert-runner-last-status}"
DEPLOYMENT_SECRET_NAME="${DEPLOYMENT_SECRET_NAME:-cert-runner-last-deployment}"
RENEWAL_THRESHOLD_DAYS="${RENEWAL_THRESHOLD_DAYS:-21}"
TARGET_RESOURCE_GROUP="${TARGET_RESOURCE_GROUP:-}"
RUNNER_PREFIX="${RUNNER_PREFIX:-l7cert}"
TEMPLATE_URI="${TEMPLATE_URI:-}"

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$name" >&2
    exit 1
  }
}

json_bool() {
  local value="${1,,}"
  if [[ "$value" == "true" || "$value" == "1" || "$value" == "yes" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

normalize_domains() {
  local primary_host="$1"
  local domains_csv="$2"
  local include_wildcard="$3"
  declare -A seen=()
  local results=()

  if [[ -n "$domains_csv" ]]; then
    IFS=',' read -r -a csv_domains <<< "$domains_csv"
    for entry in "${csv_domains[@]}"; do
      entry="$(echo "$entry" | xargs | tr '[:upper:]' '[:lower:]')"
      if [[ -n "$entry" && "$entry" == *.* && -z "${seen[$entry]:-}" ]]; then
        seen[$entry]=1
        results+=("$entry")
      fi
    done
  fi

  if [[ -n "$primary_host" ]]; then
    local base_host
    base_host="$(echo "$primary_host" | xargs | tr '[:upper:]' '[:lower:]')"
    base_host="${base_host#\*.}"
    if [[ -n "$base_host" && "$base_host" == *.* ]]; then
      if [[ -z "${seen[$base_host]:-}" ]]; then
        seen[$base_host]=1
        results+=("$base_host")
      fi
      if [[ "$(json_bool "$include_wildcard")" == 'true' ]]; then
        local wildcard="*.${base_host}"
        if [[ -z "${seen[$wildcard]:-}" ]]; then
          seen[$wildcard]=1
          results+=("$wildcard")
        fi
      fi
    fi
  fi

  printf '%s\n' "${results[@]}"
}

kv_secret_value() {
  local secret_name="$1"
  az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$secret_name" --query value -o tsv 2>/dev/null || true
}

kv_set_secret() {
  local secret_name="$1"
  local secret_value="$2"
  az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "$secret_name" --value "$secret_value" --content-type application/json -o none
}

config_get() {
  local json="$1"
  local key="$2"
  jq -r --arg key "$key" '.[$key] // empty' <<< "$json"
}

certificate_domains() {
  local cert_json="$1"
  {
    jq -r '.policy.x509CertificateProperties.subjectAlternativeNames.dnsNames[]? // empty' <<< "$cert_json"
    local subject
    subject="$(jq -r '.policy.x509CertificateProperties.subject // empty' <<< "$cert_json")"
    if [[ "$subject" =~ CN=([^,]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  } | awk 'NF {print tolower($0)}' | sort -u
}

find_matching_certificate() {
  local preferred_cert_name="$1"
  local preferred_secret_name="$2"
  shift 2
  local desired=("$@")
  local candidate_names=()

  [[ -n "$preferred_secret_name" ]] && candidate_names+=("$preferred_secret_name")
  [[ -n "$preferred_cert_name" ]] && candidate_names+=("$preferred_cert_name")

  for name in "${candidate_names[@]}"; do
    local cert_json
    cert_json="$(az keyvault certificate show --vault-name "$KEY_VAULT_NAME" --name "$name" -o json 2>/dev/null || true)"
    if [[ -z "$cert_json" ]]; then
      continue
    fi

    if [[ ${#desired[@]} -eq 0 ]]; then
      printf '%s' "$cert_json"
      return 0
    fi

    while IFS= read -r domain; do
      for desired_domain in "${desired[@]}"; do
        if [[ "$domain" == "$desired_domain" ]]; then
          printf '%s' "$cert_json"
          return 0
        fi
      done
    done < <(certificate_domains "$cert_json")
  done

  local names
  names="$(az keyvault certificate list --vault-name "$KEY_VAULT_NAME" --query '[].name' -o tsv 2>/dev/null || true)"
  if [[ -n "$names" ]]; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local cert_json
      cert_json="$(az keyvault certificate show --vault-name "$KEY_VAULT_NAME" --name "$name" -o json 2>/dev/null || true)"
      [[ -z "$cert_json" ]] && continue
      while IFS= read -r domain; do
        for desired_domain in "${desired[@]}"; do
          if [[ "$domain" == "$desired_domain" ]]; then
            printf '%s' "$cert_json"
            return 0
          fi
        done
      done < <(certificate_domains "$cert_json")
    done <<< "$names"
  fi

  return 1
}

days_until() {
  local iso="$1"
  local expiry_epoch now_epoch
  expiry_epoch="$(date -d "$iso" +%s)"
  now_epoch="$(date -u +%s)"
  echo $(((expiry_epoch - now_epoch) / 86400))
}

public_cert_thumbprint() {
  local host="$1"
  openssl s_client -connect "${host}:443" -servername "$host" </dev/null 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha1 2>/dev/null \
    | awk -F= '{print $2}' \
    | tr -d ':' \
    | tr '[:lower:]' '[:upper:]'
}

write_dns_hooks() {
  cat > /opt/certmgr/auth-hook.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ZONE_NAME="${DNS_ZONE_NAME}"
ZONE_RG="${DNS_ZONE_RESOURCE_GROUP}"
CHALLENGE_DOMAIN="${CERTBOT_DOMAIN#\*.}"
if [[ "$CHALLENGE_DOMAIN" == "$ZONE_NAME" ]]; then
  RECORD_NAME="_acme-challenge"
else
  SUFFIX=".${ZONE_NAME}"
  HOSTPART="${CHALLENGE_DOMAIN%$SUFFIX}"
  RECORD_NAME="_acme-challenge.${HOSTPART}"
fi
az network dns record-set txt create --resource-group "$ZONE_RG" --zone-name "$ZONE_NAME" --name "$RECORD_NAME" --ttl 60 -o none
az network dns record-set txt add-record --resource-group "$ZONE_RG" --zone-name "$ZONE_NAME" --record-set-name "$RECORD_NAME" --value "$CERTBOT_VALIDATION" -o none
sleep 30
EOF

  cat > /opt/certmgr/cleanup-hook.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ZONE_NAME="${DNS_ZONE_NAME}"
ZONE_RG="${DNS_ZONE_RESOURCE_GROUP}"
CHALLENGE_DOMAIN="${CERTBOT_DOMAIN#\*.}"
if [[ "$CHALLENGE_DOMAIN" == "$ZONE_NAME" ]]; then
  RECORD_NAME="_acme-challenge"
else
  SUFFIX=".${ZONE_NAME}"
  HOSTPART="${CHALLENGE_DOMAIN%$SUFFIX}"
  RECORD_NAME="_acme-challenge.${HOSTPART}"
fi
az network dns record-set txt remove-record --resource-group "$ZONE_RG" --zone-name "$ZONE_NAME" --record-set-name "$RECORD_NAME" --value "$CERTBOT_VALIDATION" -o none || true
EOF

  chmod +x /opt/certmgr/auth-hook.sh /opt/certmgr/cleanup-hook.sh
}

require_cmd az
require_cmd jq
require_cmd openssl
require_cmd certbot

az login --identity >/dev/null

CONFIG_JSON="$(kv_secret_value "$CONFIG_SECRET_NAME")"
if [[ -n "$CONFIG_JSON" ]]; then
  [[ -z "$LE_EMAIL" ]] && LE_EMAIL="$(config_get "$CONFIG_JSON" 'LetEncryptEmail')"
  [[ -z "$TARGET_RESOURCE_GROUP" ]] && TARGET_RESOURCE_GROUP="$(config_get "$CONFIG_JSON" 'TargetResourceGroup')"
  [[ -z "$PRIMARY_HOSTNAME" ]] && PRIMARY_HOSTNAME="$(config_get "$CONFIG_JSON" 'PrimaryHostname')"
  [[ -z "$ADDITIONAL_DOMAINS_CSV" ]] && ADDITIONAL_DOMAINS_CSV="$(config_get "$CONFIG_JSON" 'AcmeDomainsCsv')"
  [[ -z "$KEY_VAULT_RESOURCE_GROUP" ]] && KEY_VAULT_RESOURCE_GROUP="$(config_get "$CONFIG_JSON" 'KeyVaultResourceGroup')"
  [[ -z "$KEY_VAULT_CERT_NAME" ]] && KEY_VAULT_CERT_NAME="$(config_get "$CONFIG_JSON" 'KeyVaultCertificateName')"
  [[ -z "$KEY_VAULT_SECRET_NAME" ]] && KEY_VAULT_SECRET_NAME="$(config_get "$CONFIG_JSON" 'KeyVaultSecretName')"
  [[ -z "$KEY_VAULT_ACCESS_MODE" ]] && KEY_VAULT_ACCESS_MODE="$(config_get "$CONFIG_JSON" 'KeyVaultAccessMode')"
  [[ -z "$KEY_VAULT_PRIVATE_DNS_ZONE_RESOURCE_GROUP" ]] && KEY_VAULT_PRIVATE_DNS_ZONE_RESOURCE_GROUP="$(config_get "$CONFIG_JSON" 'KeyVaultPrivateDnsZoneResourceGroup')"
  [[ -z "$DNS_ZONE_NAME" ]] && DNS_ZONE_NAME="$(config_get "$CONFIG_JSON" 'DnsZoneName')"
  [[ -z "$DNS_ZONE_RESOURCE_GROUP" ]] && DNS_ZONE_RESOURCE_GROUP="$(config_get "$CONFIG_JSON" 'DnsZoneResourceGroup')"
  [[ -z "$RUNNER_PREFIX" ]] && RUNNER_PREFIX="$(config_get "$CONFIG_JSON" 'RunnerPrefix')"
  [[ -z "$TEMPLATE_URI" ]] && TEMPLATE_URI="$(config_get "$CONFIG_JSON" 'TemplateUri')"
fi

mapfile -t desired_domains < <(normalize_domains "$PRIMARY_HOSTNAME" "$ADDITIONAL_DOMAINS_CSV" "$INCLUDE_WILDCARD_HOSTNAME")
if [[ ${#desired_domains[@]} -eq 0 && -n "$PRIMARY_DOMAIN" ]]; then
  mapfile -t desired_domains < <(normalize_domains "$PRIMARY_DOMAIN" "$ADDITIONAL_DOMAINS_CSV" "$INCLUDE_WILDCARD_HOSTNAME")
fi

if [[ ${#desired_domains[@]} -eq 0 ]]; then
  echo 'No valid desired domains resolved.' >&2
  exit 1
fi

PRIMARY_DOMAIN="${desired_domains[0]}"

if [[ -z "$LE_EMAIL" || -z "$KEY_VAULT_NAME" || -z "$DNS_ZONE_NAME" || -z "$DNS_ZONE_RESOURCE_GROUP" ]]; then
  echo 'Missing required variables after config merge.' >&2
  exit 1
fi

matched_cert_json="$(find_matching_certificate "$KEY_VAULT_CERT_NAME" "$KEY_VAULT_SECRET_NAME" "${desired_domains[@]}" || true)"
outcome='Unknown'
message=''
renewal_needed='true'
cert_name_effective="$KEY_VAULT_CERT_NAME"
previous_expiry=''
previous_thumbprint=''
public_thumbprint=''
public_matches='false'

if [[ -n "$matched_cert_json" ]]; then
  cert_name_effective="$(jq -r '.name' <<< "$matched_cert_json")"
  previous_expiry="$(jq -r '.attributes.expires // empty' <<< "$matched_cert_json")"
  previous_thumbprint="$(jq -r '.x509ThumbprintHex // empty' <<< "$matched_cert_json")"
  public_thumbprint="$(public_cert_thumbprint "$PRIMARY_DOMAIN" || true)"
  if [[ -n "$previous_thumbprint" && -n "$public_thumbprint" && "$previous_thumbprint" == "$public_thumbprint" ]]; then
    public_matches='true'
  fi
  if [[ -n "$previous_expiry" ]]; then
    days_left="$(days_until "$previous_expiry")"
    if [[ "$days_left" -gt "$RENEWAL_THRESHOLD_DAYS" ]]; then
      outcome='Skipped'
      renewal_needed='false'
      if [[ "$public_matches" == 'true' ]]; then
        message='Existing certificate is still valid and matches the public certificate.'
      else
        message='Existing certificate is still valid, but the public certificate does not match the Key Vault certificate.'
      fi
    fi
  fi
fi

config_payload="$(jq -cn \
  --arg le "$LE_EMAIL" \
  --arg targetRg "$TARGET_RESOURCE_GROUP" \
  --arg kv "$KEY_VAULT_NAME" \
  --arg kvrg "$KEY_VAULT_RESOURCE_GROUP" \
  --arg cert "$cert_name_effective" \
  --arg secret "$KEY_VAULT_SECRET_NAME" \
  --arg accessMode "$KEY_VAULT_ACCESS_MODE" \
  --arg kvPrivateDnsRg "$KEY_VAULT_PRIVATE_DNS_ZONE_RESOURCE_GROUP" \
  --arg host "$PRIMARY_HOSTNAME" \
  --arg dns "$DNS_ZONE_NAME" \
  --arg dnsrg "$DNS_ZONE_RESOURCE_GROUP" \
  --arg configSecret "$CONFIG_SECRET_NAME" \
  --arg statusSecret "$STATUS_SECRET_NAME" \
  --arg deploymentSecret "$DEPLOYMENT_SECRET_NAME" \
  --arg prefix "$RUNNER_PREFIX" \
  --arg templateUri "$TEMPLATE_URI" \
  --arg domains_csv "$(IFS=,; echo "${desired_domains[*]}")" \
  --argjson threshold "$RENEWAL_THRESHOLD_DAYS" \
  --argjson include_wildcard "$(json_bool "$INCLUDE_WILDCARD_HOSTNAME")" \
  --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{LetEncryptEmail:$le,TargetResourceGroup:$targetRg,KeyVaultName:$kv,KeyVaultResourceGroup:$kvrg,KeyVaultCertificateName:$cert,KeyVaultSecretName:$secret,KeyVaultAccessMode:$accessMode,KeyVaultPrivateDnsZoneResourceGroup:$kvPrivateDnsRg,PrimaryHostname:$host,DnsZoneName:$dns,DnsZoneResourceGroup:$dnsrg,AcmeDomainsCsv:$domains_csv,IncludeWildcardHostname:$include_wildcard,ConfigSecretName:$configSecret,StatusSecretName:$statusSecret,DeploymentSecretName:$deploymentSecret,RenewalThresholdDays:$threshold,RunnerPrefix:$prefix,TemplateUri:$templateUri,updatedUtc:$updated}')"
kv_set_secret "$CONFIG_SECRET_NAME" "$config_payload"

deployment_payload="$(jq -cn \
  --arg rg "$TARGET_RESOURCE_GROUP" \
  --arg domain "$PRIMARY_DOMAIN" \
  --arg cert "$cert_name_effective" \
  --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{targetResourceGroup:$rg,primaryDomain:$domain,keyVaultCertificateName:$cert,startedUtc:$started}')"
kv_set_secret "$DEPLOYMENT_SECRET_NAME" "$deployment_payload"

if [[ "$renewal_needed" == 'true' ]]; then
  mkdir -p /opt/certmgr
  write_dns_hooks
  certbot_args=(
    certonly
    --non-interactive
    --agree-tos
    --email "$LE_EMAIL"
    --manual
    --preferred-challenges dns
    --manual-auth-hook /opt/certmgr/auth-hook.sh
    --manual-cleanup-hook /opt/certmgr/cleanup-hook.sh
    --manual-public-ip-logging-ok
  )
  for domain in "${desired_domains[@]}"; do
    certbot_args+=( -d "$domain" )
  done
  certbot "${certbot_args[@]}"

  pem_path="/etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem"
  key_path="/etc/letsencrypt/live/${PRIMARY_DOMAIN}/privkey.pem"
  pfx_path="/tmp/${PRIMARY_DOMAIN}.pfx"

  openssl pkcs12 -export \
    -out "$pfx_path" \
    -inkey "$key_path" \
    -in "$pem_path" \
    -password pass:

  az keyvault certificate import \
    --vault-name "$KEY_VAULT_NAME" \
    --name "$cert_name_effective" \
    --file "$pfx_path" \
    --password "" \
    -o none

  matched_cert_json="$(az keyvault certificate show --vault-name "$KEY_VAULT_NAME" --name "$cert_name_effective" -o json)"
  outcome='Success'
  message='Certificate renewed/imported into Key Vault.'
fi

current_expiry="$(jq -r '.attributes.expires // empty' <<< "$matched_cert_json" 2>/dev/null || true)"
current_thumbprint="$(jq -r '.x509ThumbprintHex // empty' <<< "$matched_cert_json" 2>/dev/null || true)"
public_thumbprint="$(public_cert_thumbprint "$PRIMARY_DOMAIN" || true)"
if [[ -n "$current_thumbprint" && -n "$public_thumbprint" && "$current_thumbprint" == "$public_thumbprint" ]]; then
  public_matches='true'
else
  public_matches='false'
fi

status_payload="$(jq -cn \
  --arg outcome "$outcome" \
  --arg message "$message" \
  --arg kv "$KEY_VAULT_NAME" \
  --arg cert "$cert_name_effective" \
  --arg secret "$KEY_VAULT_SECRET_NAME" \
  --arg previousExpiry "$previous_expiry" \
  --arg currentExpiry "$current_expiry" \
  --arg previousThumbprint "$previous_thumbprint" \
  --arg currentThumbprint "$current_thumbprint" \
  --arg publicThumbprint "$public_thumbprint" \
  --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson publicMatches "$(json_bool "$public_matches")" \
  --argjson renewalNeeded "$(json_bool "$renewal_needed")" \
  --argjson desiredDomains "$(printf '%s\n' "${desired_domains[@]}" | jq -R . | jq -s .)" \
  '{outcome:$outcome,message:$message,keyVaultName:$kv,keyVaultCertificateName:$cert,keyVaultSecretName:$secret,previousExpiryUtc:$previousExpiry,currentExpiryUtc:$currentExpiry,previousThumbprint:$previousThumbprint,currentThumbprint:$currentThumbprint,publicThumbprint:$publicThumbprint,publicMatchesKeyVault:$publicMatches,renewalNeeded:$renewalNeeded,desiredDomains:$desiredDomains,completedUtc:$completed}')"
kv_set_secret "$STATUS_SECRET_NAME" "$status_payload"

log "$message"
