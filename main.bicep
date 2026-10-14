targetScope = 'subscription'

@description('Miljønavn. Styrer RG-navn, tags og storage-navn.')
@allowed(['dev', 'prod'])
param environment string

param location string = 'norwayeast'

@description('Kort prefiks for workload, inngår i ressursnavn.')
param workload string = 'avdiac'

var tags = {
  Workload: 'AVD'
  Environment: environment
  ManagedBy: 'Bicep'
  Repo: 'avd-iac'
}

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-avd-iac-${environment}'
  location: location
  tags: tags
}

module storage 'modules/storage-account.bicep' = {
  name: 'storage-${environment}'
  scope: rg
  params: {
    namePrefix: 'st${workload}${environment}'
    location: location
    tags: tags
  }
}

output resourceGroupName string = rg.name
output storageAccountName string = storage.outputs.name
output storageAccountId string = storage.outputs.id
