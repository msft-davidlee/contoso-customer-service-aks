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
param aksIPAddress string
param customerServiceHostName string

var stackName = '${prefix}${appEnvironment}'
var tags = {
  'stack-name': stackNameTag
  'stack-environment': appEnvironment
  'stack-branch': branch
  'stack-version': version
  'stack-last-updated': lastUpdated
  'stack-sub-name': 'demo'
}

var appGwId = resourceId('Microsoft.Network/applicationGateways', stackName)
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
    frontendPorts: [
      {
        name: 'port_https'
        properties: {
          port: 443
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'customer-service'
        properties: {
          backendAddresses: [
            {
              ipAddress: aksIPAddress
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'customer-service-app-https-setting'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          hostName: customerServiceHostName
          pickHostNameFromBackendAddress: false
          affinityCookieName: 'ApplicationGatewayAffinity'
          requestTimeout: 20
          probe: {
            id: '${appGwId}/probes/customer-service-app-https-setting-probe'
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'customer-service-app'
        properties: {
          frontendIPConfiguration: {
            id: '${appGwId}/frontendIPConfigurations/appGwPublicFrontendIp'
          }
          frontendPort: {
            id: '${appGwId}/frontendPorts/port_https'
          }
          protocol: 'Https'
          sslCertificate: {
            id: '${appGwId}/sslCertificates/appgwcert'
          }
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'frontend-to-customer-service-app'
        properties: {
          ruleType: 'Basic'
          httpListener: {
            id: '${appGwId}/httpListeners/customer-service-app'
          }
          backendAddressPool: {
            id: '${appGwId}/backendAddressPools/customer-service'
          }
          backendHttpSettings: {
            id: '${appGwId}/backendHttpSettingsCollection/customer-service-app-https-setting'
          }
        }
      }
    ]
    probes: [
      {
        name: 'customer-service-app-https-setting-probe'
        properties: {
          protocol: 'Https'
          host: customerServiceHostName
          path: '/health'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
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
