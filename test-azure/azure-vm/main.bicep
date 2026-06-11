targetScope = 'subscription'

@description('Azure region for all test resources.')
param location string = 'japaneast'

@description('Resource group name to create or update.')
param resourceGroupName string = 'rg-fluent-ali-test'

@description('Prefix included in resource names for easy identification.')
param namePrefix string = 'fluent-ali-test'

@description('Admin user name for the Linux VM.')
param adminUsername string = 'azureuser'

@description('SSH public key used to sign in to the Linux VM.')
param adminSshPublicKey string

@description('Source CIDR allowed to access SSH. Use your current public IP with /32 when possible.')
param sshSourceAddressPrefix string = '*'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module vmEnvironment 'resources.bicep' = {
  name: '${namePrefix}-environment'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    sshSourceAddressPrefix: sshSourceAddressPrefix
  }
}

output resourceGroup string = rg.name
output vmName string = vmEnvironment.outputs.vmName
output publicIpName string = vmEnvironment.outputs.publicIpName
output logAnalyticsWorkspaceName string = vmEnvironment.outputs.logAnalyticsWorkspaceName
output dcrName string = vmEnvironment.outputs.dcrName
output dcrImmutableId string = vmEnvironment.outputs.dcrImmutableId
output logsIngestionEndpoint string = vmEnvironment.outputs.logsIngestionEndpoint
output streamName string = vmEnvironment.outputs.streamName
output tableName string = vmEnvironment.outputs.tableName