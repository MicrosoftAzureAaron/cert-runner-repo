@description('Deployment location for the cert-runner stack.')
param location string = resourceGroup().location

@description('Name prefix for cert-runner resources.')
param prefix string = 'l7cert'

@description('DNS zone name for ACME DNS-01 validation.')
param dnsZoneName string

@description('Resource group containing the DNS zone.')
param dnsZoneResourceGroup string = resourceGroup().name

@description('Key Vault name where certificate is imported.')
param keyVaultName string

@description('Resource group containing the Key Vault.')
param keyVaultResourceGroup string = resourceGroup().name

@description('Create a managed Key Vault in this deployment resource group if one does not exist.')
param createManagedKeyVault bool = false

@description('Key Vault connectivity mode: PublicAccess, ServiceEndpoint, or PrivateEndpoint.')
param keyVaultAccessMode string = 'PublicAccess'

@description('Tenant ID for a managed Key Vault when createManagedKeyVault is true.')
param keyVaultTenantId string = subscription().tenantId

@description('Keep managed Key Vault after cert-runner cleanup.')
param persistManagedKeyVault bool = true

@description('Apply delete lock to managed persistent Key Vault.')
param applyManagedKeyVaultLock bool = true

@description('deleteAfterUtc tag value for managed persistent Key Vault.')
param dndDeleteAfterUtc string = 'Never'

@description('Certificate object name in Key Vault.')
param keyVaultCertificateName string

@description('Optional preferred Key Vault secret or object name to check before falling back to certificate name/domain matching.')
param keyVaultSecretName string = ''

@description('Primary domain name for certificate issuance.')
param primaryDomain string

@description('Optional hostname used by the VM-side script to resolve root and wildcard certificate expectations.')
param primaryHostname string = ''

@description('Include wildcard hostname when resolving desired certificate domains from primaryHostname.')
param includeWildcardHostname bool = true

@description('Additional SAN entries for certificate issuance.')
param additionalDomains array = []

@description('Linux VM size for the one-shot runner.')
param vmSize string = 'Standard_B2s'

@description('Admin username for the runner VM.')
param adminUsername string = 'azureuser'

@description('SSH public key for the runner VM.')
@secure()
param adminSshPublicKey string

@description('CIDR allowed for SSH. Use a locked-down source in practice.')
param sshAllowedCidr string = '0.0.0.0/0'

@description('Contact email for Lets Encrypt registration.')
param letsEncryptEmail string

@description('Cloud-init content. Defaults to installing certbot and az cli.')
param cloudInit string = ''

@description('Delete the VM after successful import.')
param deleteVmOnSuccess bool = true

@description('Key Vault secret name used to persist cert-runner configuration for future runs.')
param configSecretName string = 'cert-runner-config'

@description('Key Vault secret name used to persist the latest cert-runner status payload.')
param statusSecretName string = 'cert-runner-last-status'

@description('Key Vault secret name used to persist deployment context written by the runner VM.')
param deploymentSecretName string = 'cert-runner-last-deployment'

@description('Threshold in days used by the runner VM when deciding whether renewal is necessary.')
param renewalThresholdDays int = 21

@description('URI for the VM-side cert runner script to download and execute.')
param runnerScriptUri string = 'https://raw.githubusercontent.com/MicrosoftAzureAaron/cert-runner-repo/master/scripts/certmgr-renew.sh'

@description('Private DNS zone name used for Key Vault private endpoint resolution.')
param keyVaultPrivateDnsZoneName string = 'privatelink.vaultcore.azure.net'

@description('Resource group containing the private DNS zone for Key Vault.')
param keyVaultPrivateDnsZoneResourceGroup string = resourceGroup().name

@description('Create private DNS zone in the current RG when using private endpoint mode.')
param createPrivateDnsZone bool = false

@description('UTC timestamp applied to temporary runner resources at creation.')
param runnerDeployedAtUtc string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

@description('UTC expiry timestamp applied to temporary runner resources at creation.')
param runnerDeleteAfterUtc string = dateTimeAdd(utcNow(), 'PT6H', 'yyyy-MM-ddTHH:mm:ssZ')

var vmName = '${prefix}-runner-vm'
var pipName = '${prefix}-runner-pip'
var nsgName = '${prefix}-runner-nsg'
var vnetName = '${prefix}-runner-vnet'
var subnetName = 'runner-subnet'
var nicName = '${prefix}-runner-nic'
var privateEndpointName = '${prefix}-kv-pe'
var privateDnsZoneLinkName = '${prefix}-kvdns-link'
var isPublicAccessMode = (keyVaultAccessMode == 'PublicAccess')
var isServiceEndpointMode = (keyVaultAccessMode == 'ServiceEndpoint')
var isPrivateEndpointMode = (keyVaultAccessMode == 'PrivateEndpoint')
var effectiveKeyVaultId = (createManagedKeyVault
  ? keyVault.id
  : resourceId(keyVaultResourceGroup, 'Microsoft.KeyVault/vaults', keyVaultName))
var privateDnsZoneId = (createPrivateDnsZone
  ? keyVaultPrivateDnsZone.id
  : resourceId(keyVaultPrivateDnsZoneResourceGroup, 'Microsoft.Network/privateDnsZones', keyVaultPrivateDnsZoneName))
var canManagePrivateDnsInCurrentRg = (keyVaultPrivateDnsZoneResourceGroup == resourceGroup().name)
var runnerLifecycleTags = {
  deployedBy: 'cert-runner-template'
  cleanupPolicy: 'EOD'
  cleanupScope: 'Resource'
  deployedAtUtc: runnerDeployedAtUtc
  deleteAfterUtc: runnerDeleteAfterUtc
  solution: 'CertRunner'
  owner: 'aarosanders'
  environment: 'lab'
  costProfile: 'ephemeral'
}
var defaultCloudInit = '#cloud-config\r\npackage_update: true\r\npackages:\r\n  - certbot\r\n  - jq\r\n  - openssl\r\n  - curl\r\n  - dnsutils\r\nruncmd:\r\n  - [ bash, -lc, "curl -sL https://aka.ms/InstallAzureCLIDeb | bash" ]\r\n  - [ bash, -lc, "mkdir -p /opt/certmgr" ]\r\n  - [ bash, -lc, "echo Ready > /opt/certmgr/bootstrap.complete" ]\r\n'

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  tags: runnerLifecycleTags
  properties: {
    securityRules: [
      {
        name: 'allow-ssh'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: sshAllowedCidr
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'allow-http'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: runnerLifecycleTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.99.0.0/24'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.99.0.0/26'
          networkSecurityGroup: {
            id: nsg.id
          }
          privateEndpointNetworkPolicies: (isPrivateEndpointMode ? 'Disabled' : 'Enabled')
          serviceEndpoints: (isServiceEndpointMode
            ? [
                {
                  service: 'Microsoft.KeyVault'
                }
              ]
            : [])
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: pipName
  location: location
  tags: runnerLifecycleTags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nicName
  location: location
  tags: runnerLifecycleTags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: reference(vnet.id, '2024-05-01').subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: runnerLifecycleTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
      customData: base64((empty(cloudInit) ? defaultCloudInit : cloudInit))
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
          }
        }
      ]
    }
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (createManagedKeyVault) {
  name: keyVaultName
  location: location
  tags: {
    cleanupPolicy: 'DND'
    deleteAfterUtc: dndDeleteAfterUtc
    certRunnerPersistent: string(persistManagedKeyVault)
    deployedBy: 'cert-runner-template'
  }
  properties: {
    tenantId: keyVaultTenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    publicNetworkAccess: (isPrivateEndpointMode ? 'Disabled' : 'Enabled')
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: (isPublicAccessMode ? 'Allow' : 'Deny')
      virtualNetworkRules: (isServiceEndpointMode
        ? [
            {
              id: reference(vnet.id, '2024-05-01').subnets[0].id
            }
          ]
        : [])
      ipRules: []
    }
  }
}

resource keyVaultName_Microsoft_Authorization_cert_runner_dnd_lock 'Microsoft.KeyVault/vaults/providers/locks@2020-05-01' = if (createManagedKeyVault && persistManagedKeyVault && applyManagedKeyVaultLock) {
  name: '${keyVaultName}/Microsoft.Authorization/cert-runner-dnd-lock'
  properties: {
    level: 'CanNotDelete'
    notes: 'Persisted by cert-runner deployment for future renewals.'
  }
  dependsOn: [
    keyVault
  ]
}

resource keyVaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (isPrivateEndpointMode && createPrivateDnsZone && canManagePrivateDnsInCurrentRg) {
  name: keyVaultPrivateDnsZoneName
  location: 'global'
  tags: {
    deployedBy: 'cert-runner-template'
    cleanupPolicy: 'EOD'
    cleanupScope: 'Resource'
    deployedAtUtc: runnerDeployedAtUtc
    deleteAfterUtc: runnerDeleteAfterUtc
    solution: 'CertRunner'
    owner: 'aarosanders'
    environment: 'lab'
    costProfile: 'ephemeral'
  }
}

resource keyVaultPrivateDnsZoneName_privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (isPrivateEndpointMode && createPrivateDnsZone && canManagePrivateDnsInCurrentRg) {
  parent: keyVaultPrivateDnsZone
  name: '${privateDnsZoneLinkName}'
  location: 'global'
  tags: runnerLifecycleTags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (isPrivateEndpointMode) {
  name: privateEndpointName
  location: location
  tags: runnerLifecycleTags
  properties: {
    subnet: {
      id: reference(vnet.id, '2024-05-01').subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: 'kv-connection'
        properties: {
          privateLinkServiceId: effectiveKeyVaultId
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

resource privateEndpointName_default 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (isPrivateEndpointMode && createPrivateDnsZone && canManagePrivateDnsInCurrentRg) {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault-dns'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
  dependsOn: [
    keyVaultPrivateDnsZoneName_privateDnsZoneLink
  ]
}

output runnerVmName string = vmName
output runnerPrincipalId string = reference(vm.id, '2024-03-01', 'full').identity.principalId
output runnerPublicIp string = reference(pip.id, '2024-05-01').ipAddress
output dnsZoneId string = resourceId(dnsZoneResourceGroup, 'Microsoft.Network/dnsZones', dnsZoneName)
output keyVaultId string = effectiveKeyVaultId
output keyVaultAccessModeUsed string = keyVaultAccessMode
output managedKeyVaultCreated bool = createManagedKeyVault
output privateEndpointCreated bool = isPrivateEndpointMode
output certDomains array = union(
  [
    primaryDomain
  ],
  additionalDomains
)
output keyVaultCertificateNameOut string = keyVaultCertificateName
output letsEncryptEmailOut string = letsEncryptEmail
output note string = (deleteVmOnSuccess
  ? 'Example deployed. Configure certmgr script execution and delete VM after success.'
  : 'Example deployed. VM retained for debugging.')
