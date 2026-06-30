targetScope = 'resourceGroup'

@description('Deployment location for the cert-runner stack.')
param location string = resourceGroup().location

@description('Name prefix for cert-runner resources.')
param prefix string = 'l7cert'

@description('DNS zone name for ACME DNS-01 validation.')
param dnsZoneName string

@description('Key Vault name where certificate is imported.')
param keyVaultName string

@description('Certificate object name in Key Vault.')
param keyVaultCertificateName string

@description('Primary domain name for certificate issuance.')
param primaryDomain string

@description('Additional SAN entries for certificate issuance.')
param additionalDomains array = []

@description('Linux VM size for the one-shot runner.')
param vmSize string = 'Standard_B2s'

@description('Admin username for the runner VM.')
param adminUsername string = 'azureuser'

@secure()
@description('SSH public key for the runner VM.')
param adminSshPublicKey string

@description('CIDR allowed for SSH. Use a locked-down source in practice.')
param sshAllowedCidr string = '0.0.0.0/0'

@description('Contact email for Lets Encrypt registration.')
param letsEncryptEmail string

@description('Cloud-init content. Defaults to installing certbot and az cli.')
param cloudInit string = ''

@description('Delete the VM after successful import.')
param deleteVmOnSuccess bool = true

var vmName = '${prefix}-runner-vm'
var pipName = '${prefix}-runner-pip'
var nsgName = '${prefix}-runner-nsg'
var vnetName = '${prefix}-runner-vnet'
var subnetName = 'runner-subnet'
var nicName = '${prefix}-runner-nic'

var defaultCloudInit = '''
#cloud-config
package_update: true
packages:
  - certbot
  - python3-certbot-dns-azure
  - jq
runcmd:
  - [ bash, -lc, "curl -sL https://aka.ms/InstallAzureCLIDeb | bash" ]
  - [ bash, -lc, "mkdir -p /opt/certmgr" ]
  - [ bash, -lc, "echo Ready > /opt/certmgr/bootstrap.complete" ]
'''

resource dnsZone 'Microsoft.Network/dnsZones@2023-07-01-preview' existing = {
  name: dnsZoneName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
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
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: pipName
  location: location
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
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
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
      customData: base64(empty(cloudInit) ? defaultCloudInit : cloudInit)
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

resource dnsRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dnsZone.id, vm.id, 'dns-zone-contributor')
  scope: dnsZone
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'befefa01-2a29-4197-83a8-272ff33ce314')
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, vm.id, 'keyvault-certificates-officer')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a4417e6f-fecd-4de8-b567-7b0420556985')
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output runnerVmName string = vm.name
output runnerPublicIp string = pip.properties.ipAddress
output dnsZoneId string = dnsZone.id
output keyVaultId string = keyVault.id
output certDomains array = union([
  primaryDomain
], additionalDomains)
output keyVaultCertificateNameOut string = keyVaultCertificateName
output letsEncryptEmailOut string = letsEncryptEmail
output note string = deleteVmOnSuccess
  ? 'Example deployed. Configure certmgr script execution and delete VM after success.'
  : 'Example deployed. VM retained for debugging.'
