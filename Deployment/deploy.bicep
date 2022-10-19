param prefix string
param appEnvironment string
param location string
param sharedResourceGroup string
param keyVaultName string
param kubernetesVersion string = '1.24.6'
param subnetId string
param aksMSIId string
param queueType string
param version string
param nodesResourceGroup string
param backendFuncStorageSuffix string
param storageQueueSuffix string
param publicIPResId string
param enableAppGateway string
param appGwSubnetId string

var stackName = '${prefix}${appEnvironment}'

resource appinsights 'Microsoft.Insights/components@2020-02-02' = {
  name: stackName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    ImmediatePurgeDataOn30Days: true
    IngestionMode: 'ApplicationInsights'
  }
}

resource str 'Microsoft.Storage/storageAccounts@2022-05-01' = if (queueType == 'Storage') {
  name: '${stackName}${storageQueueSuffix}'
  location: location
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

resource strqueue 'Microsoft.Storage/storageAccounts/queueServices@2022-05-01' = if (queueType == 'Storage') {
  name: 'default'
  parent: str
}

var queueName = 'orders'
resource strqueuename 'Microsoft.Storage/storageAccounts/queueServices/queues@2022-05-01' = if (queueType == 'Storage') {
  name: queueName
  parent: strqueue
}

resource sbu 'Microsoft.ServiceBus/namespaces@2021-11-01' = if (queueType == 'ServiceBus') {
  name: stackName
  location: location
  sku: {
    name: 'Basic'
  }
}

resource sbuSenderAuthRule 'Microsoft.ServiceBus/namespaces/AuthorizationRules@2022-01-01-preview' = if (queueType == 'ServiceBus') {
  parent: sbu
  name: 'Sender'
  properties: {
    rights: [
      'Send'
    ]
  }
}

resource sbuListenAuthRule 'Microsoft.ServiceBus/namespaces/AuthorizationRules@2022-01-01-preview' = if (queueType == 'ServiceBus') {
  parent: sbu
  name: 'Listener'
  properties: {
    rights: [
      'Listen'
    ]
  }
}

resource sbuQueue 'Microsoft.ServiceBus/namespaces/queues@2022-01-01-preview' = if (queueType == 'ServiceBus') {
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

resource kv 'Microsoft.KeyVault/vaults@2022-07-01' existing = {
  name: keyVaultName
  scope: resourceGroup(subscription().subscriptionId, sharedResourceGroup)
}

module sql './sql.bicep' = {
  name: 'deploy-${appEnvironment}-${version}-sql'
  params: {
    subnetId: subnetId
    stackName: stackName
    sqlPassword: kv.getSecret('contoso-customer-service-sql-password')
    location: location
  }
}

resource wks 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: stackName
  location: location
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

resource aks 'Microsoft.ContainerService/managedClusters@2022-08-03-preview' = {
  name: stackName
  location: location
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

resource backendappStr 'Microsoft.Storage/storageAccounts@2022-05-01' = {
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
}

output queueName string = queueName

// We don't actually need to create this because it should be created automatically.
// However, we would like it to be tagged so that's why we are defining it here.
var containerInsightsName = 'ContainerInsights(${wks.name})'
resource containerinsights 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: containerInsightsName
  location: location
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

resource appGw 'Microsoft.Network/applicationGateways@2022-05-01' = if (enableAppGateway == 'true') {
  name: stackName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aksMSIId}': {}
    }
  }
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
    }
    autoscaleConfiguration: {
      minCapacity: 1
      maxCapacity: 2
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
          publicIPAddress: {
            id: publicIPResId
          }
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
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', stackName, 'appGwPublicFrontendIp')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', stackName, 'default-frontend-port')
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
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', stackName, 'default-listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', stackName, 'default-backend-pool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', stackName, 'default-backend-http-setting')
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
