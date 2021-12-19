param stackName string
param location string
param appEnvironment string
param branch string
param serviceIP string

var tags = {
  'stack-name': stackName
  'environment': appEnvironment
  'branch': branch
  'team': 'platform'
}

var frontendEndpointName = '${stackName}-azurefd-net'
var backendPoolName = 'demowebsite'
resource afd 'Microsoft.Network/frontDoors@2020-05-01' = {
  name: stackName
  location: location
  tags: tags
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
          hostName: '${stackName}.azurefd.net'
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
              backendHostHeader: serviceIP
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
        name: 'rr'
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
            forwardingProtocol: 'HttpsOnly'
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
