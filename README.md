# Cert Runner Repository

This repository is a dedicated example implementation for certificate automation in Azure using:

- Azure DNS (ACME DNS challenge integration)
- Azure Key Vault (certificate target)
- Linux VM with public IP (ephemeral cert-runner)
- certmgr/certbot style automation scripts

## Structure

- `infra/cert-runner/main.bicep`: Example infrastructure deployment (DNS + KV integration points, Linux VM, public IP, RBAC assignment example).
- `infra/cert-runner/main.json`: ARM template scaffold placeholder compatible with current automation interfaces.
- `scripts/certmgr-renew.sh`: Example renewal + import script.
- `scripts/publish-template-to-storage.ps1`: Uploads template to Storage and emits SAS URI for Azure Automation use.
- `docs/operations.md`: Deployment and operations runbook for the example.

## Intended Automation Flow

1. Azure Automation runbook checks certificate expiry in Key Vault.
2. If renewal is needed, deploy cert-runner stack from a stable template URL.
3. Runner renews certificate via Azure DNS challenge and imports into Key Vault.
4. Runner resources are deleted after success/failure.
5. Run result is written to `cert-runner-last-status` in Key Vault.

## Quick Validation

Use environment variables so no personal or environment-specific values are stored in repo history.

Required environment variables:

- AZ_SUBSCRIPTION_ID
- AZ_RESOURCE_GROUP
- CERT_DNS_ZONE_NAME
- CERT_DNS_ZONE_RESOURCE_GROUP
- CERT_KEYVAULT_NAME
- CERT_KEYVAULT_RESOURCE_GROUP
- CERT_PRIMARY_DOMAIN
- CERT_ADDITIONAL_DOMAINS_JSON
- CERT_LE_EMAIL
- CERT_VM_ADMIN_SSH_PUBLIC_KEY
- CERT_KEYVAULT_CERT_NAME

Validation command:

az account set --subscription "$env:AZ_SUBSCRIPTION_ID"
az deployment group validate --resource-group "$env:AZ_RESOURCE_GROUP" --template-file infra/cert-runner/main.bicep --parameters dnsZoneName="$env:CERT_DNS_ZONE_NAME" dnsZoneResourceGroup="$env:CERT_DNS_ZONE_RESOURCE_GROUP" keyVaultName="$env:CERT_KEYVAULT_NAME" keyVaultResourceGroup="$env:CERT_KEYVAULT_RESOURCE_GROUP" primaryDomain="$env:CERT_PRIMARY_DOMAIN" additionalDomains="$env:CERT_ADDITIONAL_DOMAINS_JSON" letsEncryptEmail="$env:CERT_LE_EMAIL" adminSshPublicKey="$env:CERT_VM_ADMIN_SSH_PUBLIC_KEY" keyVaultCertificateName="$env:CERT_KEYVAULT_CERT_NAME"
