param(
    [Parameter(Mandatory = $true)][string]$BUILD_ENV,
    [Parameter(Mandatory = $true)][string]$Prefix,
    [Parameter(Mandatory = $true)][string]$StackNameTag)

function GetResource([string]$stackName, [string]$stackEnvironment) {
    $platformRes = (az resource list --tag stack-name=$stackName | ConvertFrom-Json)
    if (!$platformRes) {
        throw "Unable to find eligible $stackName resource!"
    }
    if ($platformRes.Length -eq 0) {
        throw "Unable to find 'ANY' eligible $stackName resource!"
    }
    
    $res = ($platformRes | Where-Object { $_.tags.'stack-environment' -eq $stackEnvironment })
    if (!$res) {
        throw "Unable to find $stackName resource by $stackEnvironment environment!"
    }
    
    return $res
}

$allResources = GetResource -stackName platform -stackEnvironment $BUILD_ENV
$vnet = $allResources | Where-Object { $_.type -eq 'Microsoft.Network/virtualNetworks' -and (!$_.name.EndsWith('-nsg')) -and $_.name.Contains('-pri-') }
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
    throw "Unable to find Subnet resource!"
}
Write-Host "::set-output name=subnetId::$subnetId"


$kv = GetResource -stackName shared-key-vault -stackEnvironment prod
$kvName = $kv.name
Write-Host "::set-output name=keyVaultName::$kvName"
$sharedResourceGroup = $kv.resourceGroup
Write-Host "::set-output name=sharedResourceGroup::$sharedResourceGroup"

# This is the rg where the application should be deployed
$groups = az group list --tag stack-environment=$BUILD_ENV | ConvertFrom-Json
$appResourceGroup = ($groups | Where-Object { $_.tags.'stack-name' -eq 'aks' }).name
Write-Host "::set-output name=appResourceGroup::$appResourceGroup"

# We can provide a name but it cannot be existing
# https://docs.microsoft.com/en-us/azure/aks/faq#can-i-provide-my-own-name-for-the-aks-node-resource-group
$nodesResourceGroup = "$appResourceGroup-$Prefix"
Write-Host "::set-output name=nodesResourceGroup::$nodesResourceGroup"

# https://docs.microsoft.com/en-us/azure/azure-resource-manager/templates/template-tutorial-use-key-vault
$keyVaultId = $kv.id
Write-Host "::set-output name=keyVaultId::$keyVaultId"

# Also resolve managed identity to use
$identity = az identity list -g $appResourceGroup | ConvertFrom-Json
$mid = $identity.id
Write-Host "::set-output name=managedIdentityId::$mid"

$config = GetResource -stackName shared-configuration -stackEnvironment prod
$configName = $config.name
$enableFrontdoor = (az appconfig kv show -n $configName --key "$StackNameTag/deployment-flags/enable-frontdoor" --label $BUILD_ENV --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get enable-frontdoor flag from $configName."
}
Write-Host "::set-output name=enableFrontdoor::$enableFrontdoor"

$queueType = (az appconfig kv show -n $configName --key "$StackNameTag/deployment-flags/queue-type" --label $BUILD_ENV --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get queue-type flag from $configName."
}
Write-Host "::set-output name=queueType::$queueType"

$EnableApplicationGateway = (az appconfig kv show -n $configName --key "$StackNameTag/deployment-flags/enable-app-gateway" --label $BUILD_ENV --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get enable-application gateway flag  from $configName."
}
Write-Host "::set-output name=enableApplicationGateway::$EnableApplicationGateway"

$staticIPResourceId = (GetResource -stackName aks-public-ip -stackEnvironment prod).id
Write-Host "::set-output name=staticIPResourceId::$staticIPResourceId"

$certDomainNamesJson = (az appconfig kv show -n $configName --key "$STACK_NAME_TAG/cert-domain-names" --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get cert domain names from $configName."
}

if ($EnableApplicationGateway){
    $certDomainNames = ($certDomainNamesJson | ConvertFrom-Json).applicationgateway
}else {
    $certDomainNames = ($certDomainNamesJson | ConvertFrom-Json).ingress
}


$customerServiceDomain = $certDomainNames.customerservice
$apiDomain = $certDomainNames.api
$memberPortalDomain = $certDomainNames.memberPortal

Write-Host "::set-output name=customerServiceHostName::$customerServiceDomain"
Write-Host "::set-output name=apiHostName::$apiDomain"
Write-Host "::set-output name=memberHostName::$memberPortalDomain"
