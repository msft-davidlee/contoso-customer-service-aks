param prefix string
param appEnvironment string
param staticIPResourceId string
param stackNameTag string
param branch string
param location string
param version string
param lastUpdated string = utcNow('u')
param aksMSIId string
param keyVaultName string
param subnetId string
//param aksIPAddress string
//param customerServiceHostName string

var stackName = '${prefix}${appEnvironment}'
var tags = {
  'stack-name': stackNameTag
  'stack-environment': appEnvironment
  'stack-branch': branch
  'stack-version': version
  'stack-last-updated': lastUpdated
  'stack-sub-name': 'demo'
}

//var appGwId = resourceId('Microsoft.Network/applicationGateways', stackName)
resource appGw 'Microsoft.Network/applicationGateways@2021-05-01' = {
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
    sslCertificates: [
      {
        name: 'appgwcert'
        properties: {
          keyVaultSecretId: 'https://${keyVaultName}${environment().suffixes.keyvaultDns}/secrets/contosgwcerts'
        }
      }
    ]
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
            id: subnetId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGwPublicFrontendIp'
        properties: {
          publicIPAddress: {
            id: staticIPResourceId
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

output applicationGatewayResourceId string = appGw.id
