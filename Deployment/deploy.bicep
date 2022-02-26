param prefix string
param appEnvironment string
param branch string
param location string
@secure()
param sqlPassword string
param kubernetesVersion string = '1.21.2'
param subnetId string
param aksMSIId string
param queueType string
param version string

var stackName = '${prefix}${appEnvironment}'
var tags = {
  'stack-name': 'contoso-customer-service-aks'
  'stack-environment': appEnvironment
  'stack-branch': branch
  'stack-version': version
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
  name: stackName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
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
  name: 'orders'
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

var sqlUsername = 'app'

resource sql 'Microsoft.Sql/servers@2021-02-01-preview' = {
  name: stackName
  location: location
  tags: tags
  properties: {
    administratorLogin: sqlUsername
    administratorLoginPassword: sqlPassword
    version: '12.0'
    publicNetworkAccess: 'Enabled'
  }
}

var dbName = 'app'
resource db 'Microsoft.Sql/servers/databases@2021-02-01-preview' = {
  name: dbName
  parent: sql
  location: location
  tags: tags
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
  }
}

resource sqlfw 'Microsoft.Sql/servers/firewallRules@2021-02-01-preview' = {
  parent: sql
  name: 'AllowAllMicrosoftAzureIps'
  properties: {
    endIpAddress: '0.0.0.0'
    startIpAddress: '0.0.0.0'
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
    }
  }
}

output aksName string = aks.name
output sqlserver string = sql.properties.fullyQualifiedDomainName
output sqlusername string = sqlUsername
output dbname string = dbName

var backendapp = '${stackName}backendapp'
resource backendappStr 'Microsoft.Storage/storageAccounts@2021-02-01' = {
  name: backendapp
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
  tags: tags
}

resource backendappplan 'Microsoft.Web/serverfarms@2020-10-01' = {
  name: backendapp
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
}

var queueConnectionString = (queueType == 'Storage') ? 'DefaultEndpointsProtocol=https;AccountName=${stackName};AccountKey=${listKeys(str.id, str.apiVersion).keys[0].value};EndpointSuffix=core.windows.net' : '${listKeys(sbuListenAuthRule.id, sbu.apiVersion).primaryConnectionString}'
var sqlConnectionString = 'Data Source=${sql.properties.fullyQualifiedDomainName};Initial Catalog=${dbName}; User Id=${sqlUsername};Password=${sqlPassword}'

var backendappConnection = 'DefaultEndpointsProtocol=https;AccountName=${backendappStr.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${listKeys(backendappStr.id, backendappStr.apiVersion).keys[0].value}'
resource backendfuncapp 'Microsoft.Web/sites@2020-12-01' = {
  name: backendapp
  location: location
  tags: tags
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    httpsOnly: true
    serverFarmId: backendappplan.id
    clientAffinityEnabled: true
    siteConfig: {
      webSocketsEnabled: true
      appSettings: [
        {
          'name': 'APPINSIGHTS_INSTRUMENTATIONKEY'
          'value': appinsights.properties.InstrumentationKey
        }
        {
          'name': 'DbConnectionString'
          'value': sqlConnectionString
        }
        {
          'name': 'AzureWebJobsDashboard'
          'value': backendappConnection
        }
        {
          'name': 'AzureWebJobsStorage'
          'value': backendappConnection
        }
        {
          'name': 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          'value': backendappConnection
        }
        {
          'name': 'WEBSITE_CONTENTSHARE'
          'value': 'functions2021'
        }
        {
          'name': 'QueueName'
          'value': queueName
        }
        {
          'name': 'Connection'
          'value': queueConnectionString
        }
        {
          'name': 'FUNCTIONS_WORKER_RUNTIME'
          'value': 'dotnet'
        }
        {
          'name': 'FUNCTIONS_EXTENSION_VERSION'
          'value': '~3'
        }
        {
          'name': 'ApplicationInsightsAgent_EXTENSION_VERSION'
          'value': '~2'
        }
        {
          'name': 'XDT_MicrosoftApplicationInsights_Mode'
          'value': 'default'
        }
      ]
    }
  }
}
output backend string = backendapp
output aadinstance string = environment().authentication.loginEndpoint
output stackname string = stackName
