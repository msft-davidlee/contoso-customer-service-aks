param location string
param stackName string
param subnetId string
param tags object
@secure()
param sqlPassword string

var sqlUsername = 'app'

resource sql 'Microsoft.Sql/servers@2021-02-01-preview' = {
  name: stackName
  location: location
  tags: tags
  properties: {
    administratorLogin: sqlUsername
    administratorLoginPassword: sqlPassword
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
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

resource sqlfw 'Microsoft.Sql/servers/virtualNetworkRules@2021-08-01-preview' = {
  parent: sql
  name: 'AllowAKSSubnet'
  properties: {
    ignoreMissingVnetServiceEndpoint: false
    virtualNetworkSubnetId: subnetId
  }
}

output sqlFqdn string = sql.properties.fullyQualifiedDomainName
output dbName string = dbName
