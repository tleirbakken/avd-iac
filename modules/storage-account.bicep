@description('Prefiks for navnet. Resten fylles med uniqueString – gir globalt unikt, deterministisk navn.')
@minLength(3)
param namePrefix string

param location string = resourceGroup().location
param tags object = {}

// Maks 24 tegn, kun små bokstaver og tall
var name = take('${toLower(namePrefix)}${uniqueString(resourceGroup().id)}', 24)

resource storage 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Disabled'
  }
}

output name string = storage.name
output id string = storage.id
