param(
    [Parameter(Mandatory = $true)][string]$ArdEnvironment,
    [Parameter(Mandatory = $true)][string]$ArdSolutionId)

$ErrorActionPreference = "Stop"

$networks = (az resource list --tag ard-solution-id=networking-pri | ConvertFrom-Json)
if (!$networks) {
    throw "Unable to find eligible shared key vault resource!"
}

$vnet = ($networks | Where-Object { $_.type -eq "Microsoft.Network/virtualNetworks" -and $_.tags.'ard-environment' -eq $ArdEnvironment })
if (!$vnet) {
    throw "Unable to find Virtual Network resource!"
}
$vnetRg = $vnet.resourceGroup
$vnetName = $vnet.name
$location = $vnet.location
"location=$location" >> $env:GITHUB_OUTPUT

$subnets = (az network vnet subnet list -g $vnetRg --vnet-name $vnetName | ConvertFrom-Json)
if (!$subnets) {
    throw "Unable to find eligible Subnets from Virtual Network $vnetName!"
}          
$subnetId = ($subnets | Where-Object { $_.name -eq "aks" }).id
if (!$subnetId) {
    throw "Unable to find default Subnet resource!"
}
"subnetId=$subnetId" >> $env:GITHUB_OUTPUT

$appGwSubnetId = ($subnets | Where-Object { $_.name -eq "appgw" }).id
"appGwSubnetId=$appGwSubnetId" >> $env:GITHUB_OUTPUT

$kv = (az resource list --tag ard-resource-id=shared-key-vault | ConvertFrom-Json)
if (!$kv) {
    throw "Unable to find eligible shared key vault resource!"
}
$kvName = $kv.name
"keyVaultName=$kvName" >> $env:GITHUB_OUTPUT
$sharedResourceGroup = $kv.resourceGroup
"sharedResourceGroup=$sharedResourceGroup" >> $env:GITHUB_OUTPUT

# This is the rg where the application should be deployed
$groups = az group list --tag ard-environment=$ArdEnvironment | ConvertFrom-Json
$appResourceGroup = ($groups | Where-Object { $_.tags.'ard-solution-id' -eq $ArdSolutionId })[0].name
"appResourceGroup=$appResourceGroup" >> $env:GITHUB_OUTPUT

# https://docs.microsoft.com/en-us/azure/azure-resource-manager/templates/template-tutorial-use-key-vault
$keyVaultId = $kv.id
"keyVaultId=$keyVaultId" >> $env:GITHUB_OUTPUT

$config = (az resource list --tag ard-resource-id=shared-app-configuration | ConvertFrom-Json)
if (!$config) {
    throw "Unable to find App Config resource!"
}
$sharedResourceGroup = $config.resourceGroup

# Also resolve managed identity to use
$mid = (az identity list -g $sharedResourceGroup | ConvertFrom-Json).id
"managedIdentityId=$mid" >> $env:GITHUB_OUTPUT

$configName = $config.name
$enableFrontdoor = (az appconfig kv show -n $configName --key "$ArdSolutionId/deployment-flags/enable-frontdoor" --label $ArdEnvironment --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get enable-frontdoor flag from $configName."
}
"enableFrontdoor=$enableFrontdoor" >> $env:GITHUB_OUTPUT

$queueType = (az appconfig kv show -n $configName --key "$ArdSolutionId/deployment-flags/queue-type" --label $ArdEnvironment --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get queue-type from $configName."
}
"queueType=$queueType" >> $env:GITHUB_OUTPUT

$deploymentPrefix = (az appconfig kv show -n $configName --key "$ArdSolutionId/deployment-prefix" --label $ArdEnvironment --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get deployment prefix from $deploymentPrefix."
}
"deploymentPrefix=$deploymentPrefix" >> $env:GITHUB_OUTPUT

# We can provide a name but it cannot be existing
# https://docs.microsoft.com/en-us/azure/aks/faq#can-i-provide-my-own-name-for-the-aks-node-resource-group
$nodesResourceGroup = "$appResourceGroup-$deploymentPrefix"
"nodesResourceGroup=$nodesResourceGroup" >> $env:GITHUB_OUTPUT

$EnableApplicationGateway = (az appconfig kv show -n $configName --key "$ArdSolutionId/deployment-flags/enable-app-gateway" --label $ArdEnvironment --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get enable-application gateway flag  from $configName."
}
# Does an existing app gw already exist? If it does, don't do a deployment as it might
# cause the settings to be reset as settings are managed via AGIC.
if ($EnableApplicationGateway -eq "true") {
    $exist = (az resource list -g $appResourceGroup --resource-type "Microsoft.Network/applicationGateways" | ConvertFrom-Json).Length
    if ($exist -eq 1) {
        $EnableApplicationGateway = "skip"
    }
}
"enableApplicationGateway=$EnableApplicationGateway" >> $env:GITHUB_OUTPUT

$EnableFrontdoor = (az appconfig kv show -n $configName --key "$ArdSolutionId/deployment-flags/enable-frontdoor" --label $ArdEnvironment --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get enable-frontdoor flag  from $configName."
}
"enableFrontdoor=$EnableFrontdoor" >> $env:GITHUB_OUTPUT

$pip = $networks | Where-Object { $_.type -eq "Microsoft.Network/publicIPAddresses" -and $_.tags.'ard-environment' -eq "prod" }
$pipResId = $pip.id
"pipResId=$pipResId" >> $env:GITHUB_OUTPUT