param prefix string
param appEnvironment string
param branch string
param location string
param sharedResourceGroup string
param keyVaultName string
param kubernetesVersion string = '1.23.3'
param subnetId string
param aksMSIId string
param queueType string
param version string
param lastUpdated string = utcNow('u')
param nodesResourceGroup string
param backendFuncStorageSuffix string
param storageQueueSuffix string
param stackNameTag string

var stackName = '${prefix}${appEnvironment}'
var tags = {
  'stack-name': stackNameTag
  'stack-environment': appEnvironment
  'stack-branch': branch
  'stack-version': version
  'stack-last-updated': lastUpdated
  'stack-sub-name': 'demo'
}

resource appinsights 'Microsoft.Insights/components@2020-02-02' = {
  name: stackName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    ImmediatePurgeDataOn30Days: true
    IngestionMode: 'ApplicationInsights'
  }
}

resource str 'Microsoft.Storage/storageAccounts@2021-04-01' = if (queueType == 'Storage') {
  name: '${stackName}${storageQueueSuffix}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          id: subnetId
          action: 'Allow'
        }
      ]
    }
  }
}

resource strqueue 'Microsoft.Storage/storageAccounts/queueServices@2021-04-01' = if (queueType == 'Storage') {
  name: 'default'
  parent: str
}

var queueName = 'orders'
resource strqueuename 'Microsoft.Storage/storageAccounts/queueServices/queues@2021-04-01' = if (queueType == 'Storage') {
  name: queueName
  parent: strqueue
}

resource sbu 'Microsoft.ServiceBus/namespaces@2021-06-01-preview' = if (queueType == 'ServiceBus') {
  name: stackName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
}

resource sbuSenderAuthRule 'Microsoft.ServiceBus/namespaces/AuthorizationRules@2021-06-01-preview' = if (queueType == 'ServiceBus') {
  parent: sbu
  name: 'Sender'
  properties: {
    rights: [
      'Send'
    ]
  }
}

resource sbuListenAuthRule 'Microsoft.ServiceBus/namespaces/AuthorizationRules@2021-06-01-preview' = if (queueType == 'ServiceBus') {
  parent: sbu
  name: 'Listener'
  properties: {
    rights: [
      'Listen'
    ]
  }
}

resource sbuQueue 'Microsoft.ServiceBus/namespaces/queues@2021-06-01-preview' = if (queueType == 'ServiceBus') {
  parent: sbu
  name: queueName
  properties: {
    lockDuration: 'PT30S'
    maxSizeInMegabytes: 1024
    requiresDuplicateDetection: false
    requiresSession: false
    defaultMessageTimeToLive: 'P14D'
    deadLetteringOnMessageExpiration: false
    enableBatchedOperations: true
    duplicateDetectionHistoryTimeWindow: 'PT10M'
    maxDeliveryCount: 10
    enablePartitioning: false
    enableExpress: false
  }
}

//https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/key-vault-parameter?tabs=azure-cli#use-getsecret-function

resource kv 'Microsoft.KeyVault/vaults@2019-09-01' existing = {
  name: keyVaultName
  scope: resourceGroup(subscription().subscriptionId, sharedResourceGroup)
}

module sql './sql.bicep' = {
  name: 'deploy-${appEnvironment}-${version}-sql'
  params: {
    subnetId: subnetId
    stackName: stackName
    sqlPassword: kv.getSecret('contoso-customer-service-sql-password')
    tags: tags
    location: location
  }
}

resource wks 'Microsoft.OperationalInsights/workspaces@2021-06-01' = {
  name: stackName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2021-08-01' = {
  name: stackName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aksMSIId}': {}
    }
  }
  properties: {
    dnsPrefix: prefix
    kubernetesVersion: kubernetesVersion
    networkProfile: {
      networkPlugin: 'kubenet'
      serviceCidr: '10.250.0.0/16'
      dnsServiceIP: '10.250.0.10'
    }
    // We can provide a name but it cannot be existing
    // https://docs.microsoft.com/en-us/azure/aks/faq#can-i-provide-my-own-name-for-the-aks-node-resource-group
    nodeResourceGroup: nodesResourceGroup
    agentPoolProfiles: [
      {
        name: 'agentpool'
        type: 'VirtualMachineScaleSets'
        mode: 'System'
        osDiskSizeGB: 60
        count: 1
        minCount: 1
        maxCount: 3
        enableAutoScaling: true
        vmSize: 'Standard_B2ms'
        osType: 'Linux'
        osDiskType: 'Managed'
        vnetSubnetID: subnetId
        tags: tags
      }
    ]
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: wks.id
        }
      }
      azureKeyvaultSecretsProvider: {
        enabled: true
      }
    }
  }
}

output aksName string = aks.name
output managedIdentityId string = aks.properties.addonProfiles.azureKeyvaultSecretsProvider.identity.clientId

resource backendappStr 'Microsoft.Storage/storageAccounts@2021-02-01' = {
  name: '${stackName}${backendFuncStorageSuffix}'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          id: subnetId
          action: 'Allow'
        }
      ]
    }
  }
  tags: tags
}

output queueName string = queueName
