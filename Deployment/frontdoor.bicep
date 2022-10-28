param stackName string
param serviceIP string

var frontendEndpointName = '${stackName}-azurefd-net'
var backendPoolName = 'customer-service-backend-pool'
var frontdoorFqdn = '${stackName}.azurefd.net'

resource afd 'Microsoft.Network/frontDoors@2021-06-01' = {
  name: stackName
  location: 'global'
  properties: {
    healthProbeSettings: [
      {
        name: 'hp'
        properties: {
          healthProbeMethod: 'GET'
          intervalInSeconds: 30
          path: '/'
          protocol: 'Http'
        }
      }
    ]
    loadBalancingSettings: [
      {
        name: 'lb'
        properties: {
          sampleSize: 4
          successfulSamplesRequired: 2
          additionalLatencyMilliseconds: 0
        }
      }
    ]
    frontendEndpoints: [
      {
        name: frontendEndpointName
        properties: {
          hostName: frontdoorFqdn
        }
      }
    ]
    backendPools: [
      {
        name: backendPoolName
        properties: {
          backends: [
            {
              address: serviceIP
              httpPort: 80
              httpsPort: 443
              priority: 1
              weight: 50
              backendHostHeader: frontdoorFqdn
            }
          ]
          loadBalancingSettings: {
            id: resourceId('Microsoft.Network/frontDoors/loadBalancingSettings', stackName, 'lb')
          }
          healthProbeSettings: {
            id: resourceId('Microsoft.Network/frontDoors/healthProbeSettings', stackName, 'hp')
          }
        }
      }
    ]
    routingRules: [
      {
        name: 'contoso-customer-app-routing'
        properties: {
          frontendEndpoints: [
            {
              id: resourceId('Microsoft.Network/frontDoors/frontendEndpoints', stackName, frontendEndpointName)
            }
          ]
          acceptedProtocols: [
            'Https'
          ]
          patternsToMatch: [
            '/*'
          ]
          routeConfiguration: {
            '@odata.type': '#Microsoft.Azure.FrontDoor.Models.FrontdoorForwardingConfiguration'
            forwardingProtocol: 'HttpOnly'
            backendPool: {
              id: resourceId('Microsoft.Network/frontDoors/backendPools', stackName, backendPoolName)
            }
          }
          enabledState: 'Enabled'
        }
      }
    ]
  }
}
