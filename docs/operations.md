# Cert Runner Operations (Example)

## What this repo demonstrates

- Azure DNS for ACME DNS-01 challenge support.
- Azure Key Vault as certificate target.
- Linux VM with public IP as one-shot cert runner.
- certmgr/certbot style automation script for renewal and import.

## Deploy example infrastructure

Set environment variables in your local shell or CI pipeline, then deploy.

PowerShell example:

$env:AZ_SUBSCRIPTION_ID='00000000-0000-0000-0000-000000000000'
$env:AZ_RESOURCE_GROUP='your-resource-group'
$env:CERT_DNS_ZONE_NAME='example.com'
$env:CERT_KEYVAULT_NAME='your-keyvault-name'
$env:CERT_PRIMARY_DOMAIN='example.com'
$env:CERT_ADDITIONAL_DOMAINS_JSON='["*.example.com"]'
$env:CERT_LE_EMAIL='ops@example.com'
$env:CERT_VM_ADMIN_SSH_PUBLIC_KEY='ssh-rsa REPLACE_ME'
$env:CERT_KEYVAULT_CERT_NAME='tls-cert'

./scripts/deploy-example.ps1

## Run renewal script on the VM

1. Copy scripts/certmgr-renew.sh to /opt/certmgr/certmgr-renew.sh.
2. Set execute permissions:

```bash
chmod +x /opt/certmgr/certmgr-renew.sh
```

3. Export required environment variables and execute:

export LE_EMAIL='ops@example.com'
export PRIMARY_DOMAIN='example.com'
export ADDITIONAL_DOMAINS_CSV='*.example.com'
export KEY_VAULT_NAME='your-keyvault-name'
export KEY_VAULT_CERT_NAME='tls-cert'
/opt/certmgr/certmgr-renew.sh

## Optional: schedule automation on VM

Create a cron entry to run daily:

```bash
0 2 * * * /opt/certmgr/certmgr-renew.sh >> /var/log/certmgr-renew.log 2>&1
```

## Cleanup guidance

- Delete VM, NIC, public IP, NSG, and VNet after successful certificate import.
- Keep only Key Vault certificate object and downstream edge references.
