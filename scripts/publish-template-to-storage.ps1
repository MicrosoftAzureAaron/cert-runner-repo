param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$ContainerName,

    [int]$SasDays = 180
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot
$templatePath = Join-Path $repoRoot 'infra\cert-runner\main.json'

if (-not (Test-Path $templatePath)) {
    throw "Template not found: $templatePath"
}

az account set --subscription $SubscriptionId | Out-Null

az storage container create --account-name $StorageAccountName --name $ContainerName --auth-mode login --public-access off | Out-Null

$blobName = 'cert-runner/main.json'
az storage blob upload --account-name $StorageAccountName --container-name $ContainerName --name $blobName --file $templatePath --overwrite --auth-mode login | Out-Null

$expiry = (Get-Date).ToUniversalTime().AddDays($SasDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
$sas = az storage blob generate-sas --account-name $StorageAccountName --container-name $ContainerName --name $blobName --permissions r --expiry $expiry --https-only --auth-mode login -o tsv
if (-not $sas) {
    throw 'Failed to generate SAS token.'
}

$uri = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$blobName`?$sas"
Write-Host "TemplateUri: $uri"
