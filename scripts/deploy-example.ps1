param(
    [string]$TemplateFile = 'infra/cert-runner/main.bicep'
)

$ErrorActionPreference = 'Stop'

$requiredVars = @(
    'AZ_SUBSCRIPTION_ID',
    'AZ_RESOURCE_GROUP',
    'CERT_DNS_ZONE_NAME',
    'CERT_DNS_ZONE_RESOURCE_GROUP',
    'CERT_KEYVAULT_NAME',
    'CERT_KEYVAULT_RESOURCE_GROUP',
    'CERT_PRIMARY_DOMAIN',
    'CERT_ADDITIONAL_DOMAINS_JSON',
    'CERT_LE_EMAIL',
    'CERT_VM_ADMIN_SSH_PUBLIC_KEY',
    'CERT_KEYVAULT_CERT_NAME'
)

$missing = @()
foreach ($name in $requiredVars) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        $missing += $name
    }
}

if ($missing.Count -gt 0) {
    throw "Missing required environment variables: $($missing -join ', ')"
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot
$templatePath = Join-Path $repoRoot $TemplateFile

if (-not (Test-Path $templatePath)) {
    throw "Template file not found: $templatePath"
}

$sub = [Environment]::GetEnvironmentVariable('AZ_SUBSCRIPTION_ID')
$rg = [Environment]::GetEnvironmentVariable('AZ_RESOURCE_GROUP')

az account set --subscription $sub | Out-Null

$args = @(
        'deployment', 'group', 'create',
        '--resource-group', $rg,
        '--template-file', $templatePath,
        '--parameters',
        "dnsZoneName=$([Environment]::GetEnvironmentVariable('CERT_DNS_ZONE_NAME'))",
        "dnsZoneResourceGroup=$([Environment]::GetEnvironmentVariable('CERT_DNS_ZONE_RESOURCE_GROUP'))",
        "keyVaultName=$([Environment]::GetEnvironmentVariable('CERT_KEYVAULT_NAME'))",
        "keyVaultResourceGroup=$([Environment]::GetEnvironmentVariable('CERT_KEYVAULT_RESOURCE_GROUP'))",
        "primaryDomain=$([Environment]::GetEnvironmentVariable('CERT_PRIMARY_DOMAIN'))",
        "additionalDomains=$([Environment]::GetEnvironmentVariable('CERT_ADDITIONAL_DOMAINS_JSON'))",
        "letsEncryptEmail=$([Environment]::GetEnvironmentVariable('CERT_LE_EMAIL'))",
        "adminSshPublicKey=$([Environment]::GetEnvironmentVariable('CERT_VM_ADMIN_SSH_PUBLIC_KEY'))",
        "keyVaultCertificateName=$([Environment]::GetEnvironmentVariable('CERT_KEYVAULT_CERT_NAME'))"
)

az @args
