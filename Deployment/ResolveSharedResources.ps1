param(
    [Parameter(Mandatory = $true)][string]$ArdEnvironment,
    [Parameter(Mandatory = $true)][string]$Prefix,
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
Write-Host "::set-output name=location::$location"

$subnets = (az network vnet subnet list -g $vnetRg --vnet-name $vnetName | ConvertFrom-Json)
if (!$subnets) {
    throw "Unable to find eligible Subnets from Virtual Network $vnetName!"
}          
$subnetId = ($subnets | Where-Object { $_.name -eq "aks" }).id
if (!$subnetId) {
    throw "Unable to find default Subnet resource!"
}
Write-Host "::set-output name=subnetId::$subnetId"

$appGwSubnetId = ($subnets | Where-Object { $_.name -eq "appgw" }).id
Write-Host "::set-output name=appGwSubnetId::$appGwSubnetId"

$kv = (az resource list --tag ard-resource-id=shared-key-vault | ConvertFrom-Json)
if (!$kv) {
    throw "Unable to find eligible shared key vault resource!"
}
$kvName = $kv.name
Write-Host "::set-output name=keyVaultName::$kvName"
$sharedResourceGroup = $kv.resourceGroup
Write-Host "::set-output name=sharedResourceGroup::$sharedResourceGroup"

# This is the rg where the application should be deployed
$groups = az group list --tag ard-environment=$ArdEnvironment | ConvertFrom-Json
$appResourceGroup = ($groups | Where-Object { $_.tags.'ard-solution-id' -eq $ArdSolutionId }).name
Write-Host "::set-output name=appResourceGroup::$appResourceGroup"

# We can provide a name but it cannot be existing
# https://docs.microsoft.com/en-us/azure/aks/faq#can-i-provide-my-own-name-for-the-aks-node-resource-group
$nodesResourceGroup = "$appResourceGroup-$Prefix"
Write-Host "::set-output name=nodesResourceGroup::$nodesResourceGroup"

# https://docs.microsoft.com/en-us/azure/azure-resource-manager/templates/template-tutorial-use-key-vault
$keyVaultId = $kv.id
Write-Host "::set-output name=keyVaultId::$keyVaultId"

$config = (az resource list --tag ard-resource-id=shared-app-configuration | ConvertFrom-Json)
if (!$config) {
    throw "Unable to find App Config resource!"
}
$sharedResourceGroup = $config.resourceGroup

# Also resolve managed identity to use
$mid = (az identity list -g $sharedResourceGroup | ConvertFrom-Json).id
Write-Host "::set-output name=managedIdentityId::$mid"

$configName = $config.name
$enableFrontdoor = (az appconfig kv show -n $configName --key "$ArdSolutionId/deployment-flags/enable-frontdoor" --label $ArdEnvironment --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get enable-frontdoor flag from $configName."
}
Write-Host "::set-output name=enableFrontdoor::$enableFrontdoor"

$queueType = (az appconfig kv show -n $configName --key "$ArdSolutionId/deployment-flags/queue-type" --label $ArdEnvironment --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get queue-type flag from $configName."
}
Write-Host "::set-output name=queueType::$queueType"

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
Write-Host "::set-output name=enableApplicationGateway::$EnableApplicationGateway"

if ($EnableApplicationGateway) {
    $customerServiceDomain = (az appconfig kv show -n $configName --key "$ArdSolutionId/cert-domain-names/app-gateway/customer-service" --auth-mode login | ConvertFrom-Json).value
    $apiDomain = (az appconfig kv show -n $configName --key "$ArdSolutionId/cert-domain-names/app-gateway/api" --auth-mode login | ConvertFrom-Json).value
    $memberPortalDomain = (az appconfig kv show -n $configName --key "$ArdSolutionId/cert-domain-names/app-gateway/member-portal" --auth-mode login | ConvertFrom-Json).value
}
else {
    $customerServiceDomain = (az appconfig kv show -n $configName --key "$ArdSolutionId/cert-domain-names/ingress/customer-service" --auth-mode login | ConvertFrom-Json).value
    $apiDomain = (az appconfig kv show -n $configName --key "$ArdSolutionId/cert-domain-names/ingress/api" --auth-mode login | ConvertFrom-Json).value
    $memberPortalDomain = (az appconfig kv show -n $configName --key "$ArdSolutionId/cert-domain-names/ingress/member-portal" --auth-mode login | ConvertFrom-Json).value
}

Write-Host "::set-output name=customerServiceHostName::$customerServiceDomain"
Write-Host "::set-output name=apiHostName::$apiDomain"
Write-Host "::set-output name=memberHostName::$memberPortalDomain"

$pip = $networks | Where-Object { $_.type -eq "Microsoft.Network/publicIPAddresses" -and $_.tags.'ard-environment' -eq "prod" }
$pipResId = $pip.id
Write-Host "::set-output name=pipResId::$pipResId"