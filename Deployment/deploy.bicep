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
param enableAppGateway string
param appGwSubnetId string

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

resource str 'Microsoft.Storage/storageAccounts@2021-08-01' = if (queueType == 'Storage') {
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

resource strqueue 'Microsoft.Storage/storageAccounts/queueServices@2021-08-01' = if (queueType == 'Storage') {
  name: 'default'
  parent: str
}

var queueName = 'orders'
resource strqueuename 'Microsoft.Storage/storageAccounts/queueServices/queues@2021-08-01' = if (queueType == 'Storage') {
  name: queueName
  parent: strqueue
}

resource sbu 'Microsoft.ServiceBus/namespaces@2021-11-01' = if (queueType == 'ServiceBus') {
  name: stackName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
}

resource sbuSenderAuthRule 'Microsoft.ServiceBus/namespaces/AuthorizationRules@2021-11-01' = if (queueType == 'ServiceBus') {
  parent: sbu
  name: 'Sender'
  properties: {
    rights: [
      'Send'
    ]
  }
}

resource sbuListenAuthRule 'Microsoft.ServiceBus/namespaces/AuthorizationRules@2021-11-01' = if (queueType == 'ServiceBus') {
  parent: sbu
  name: 'Listener'
  properties: {
    rights: [
      'Listen'
    ]
  }
}

resource sbuQueue 'Microsoft.ServiceBus/namespaces/queues@2021-11-01' = if (queueType == 'ServiceBus') {
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

resource kv 'Microsoft.KeyVault/vaults@2021-11-01-preview' existing = {
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

// Note: AAD Pod Identity is disabled by default on clusters with Kubenet network plugin. 
// The NMI pods will fail to run with error AAD Pod Identity is not supported for Kubenet.
// https://github.com/Azure/aad-pod-identity/blob/master/website/content/en/docs/Configure/aad_pod_identity_on_kubenet.md

resource aks 'Microsoft.ContainerService/managedClusters@2022-01-02-preview' = {
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
      networkPlugin: (enableAppGateway == 'true' || enableAppGateway == 'skip') ? 'azure' : 'kubenet'
      serviceCidr: (enableAppGateway == 'true' || enableAppGateway == 'skip') ? '10.0.240.0/21' : '10.250.0.0/16'
      dnsServiceIP: (enableAppGateway == 'true' || enableAppGateway == 'skip') ? '10.0.240.10' : '10.250.0.10'
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

resource backendappStr 'Microsoft.Storage/storageAccounts@2021-08-01' = {
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

// We don't actually need to create this because it should be created automatically.
// However, we would like it to be tagged so that's why we are defining it here.
var containerInsightsName = 'ContainerInsights(${wks.name})'
resource containerinsights 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: containerInsightsName
  location: location
  tags: tags
  plan: {
    name: containerInsightsName
    promotionCode: ''
    product: 'OMSGallery/ContainerInsights'
    publisher: 'Microsoft'
  }
  properties: {
    workspaceResourceId: wks.id
  }
}

var appGwId = resourceId('Microsoft.Network/applicationGateways', stackName)

resource appGw 'Microsoft.Network/applicationGateways@2021-05-01' = if (enableAppGateway == 'true') {
  name: stackName
  location: location
  tags: tags
  // identity: {
  //   type: 'UserAssigned'
  //   userAssignedIdentities: {
  //     '${aksMSIId}': {}
  //   }
  // }
  properties: {
    sku: {
      name: 'WAF_Medium'
      tier: 'WAF'
      capacity: 1
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: appGwSubnetId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGwPublicFrontendIp'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.8.10'
        }
      }
    ]
    frontendPorts: [
      {
        name: 'default-frontend-port'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'default-backend-pool'
        properties: {
          backendAddresses: []
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'default-backend-http-setting'
        properties: {
          port: 80
          protocol: 'Http'
        }
      }
    ]
    httpListeners: [
      {
        name: 'default-listener'
        properties: {
          frontendIPConfiguration: {
            id: '${appGwId}/frontendIPConfigurations/appGwPublicFrontendIp'
          }
          frontendPort: {
            id: '${appGwId}/frontendPorts/default-frontend-port'
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'default-routing'
        properties: {
          ruleType: 'Basic'
          httpListener: {
            id: '${appGwId}/httpListeners/default-listener'
          }
          backendAddressPool: {
            id: '${appGwId}/backendAddressPools/default-backend-pool'
          }
          backendHttpSettings: {
            id: '${appGwId}/backendHttpSettingsCollection/default-backend-http-setting'
          }
        }
      }
    ]
    webApplicationFirewallConfiguration: {
      enabled: true
      firewallMode: 'Detection'
      ruleSetType: 'OWASP'
      ruleSetVersion: '3.0'
    }
  }
}
