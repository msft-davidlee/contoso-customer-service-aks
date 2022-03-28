param(
    [string]$BUILD_ENV)

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
        throw "Unable to find resource by environment!"
    }
    
    return $res
}

$allResources = GetResource -stackName networking -stackEnvironment $BUILD_ENV
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

$nodesResourceGroup = ($groups | Where-Object { $_.tags.'stack-name' -eq 'aks-nodes' }).name
Write-Host "::set-output name=nodesResourceGroup::$nodesResourceGroup"

# https://docs.microsoft.com/en-us/azure/azure-resource-manager/templates/template-tutorial-use-key-vault
$keyVaultId = $kv.id
Write-Host "::set-output name=keyVaultId::$keyVaultId"

# Also resolve managed identity to use
$mid = (az identity list -g $appResourceGroup | ConvertFrom-Json).id
Write-Host "::set-output name=managedIdentityId::$mid"

$config = GetResource -stackName shared-configuration -stackEnvironment prod
$configName = $config.name
$enableFrontdoor = (az appconfig kv show -n $configName --key "contoso-customer-service-aks/deployment-flags/enable-frontdoor" --label $BUILD_ENV --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get enable-frontdoor flag from $configName."
}
Write-Host "::set-output name=enableFrontdoor::$enableFrontdoor"

$queueType = (az appconfig kv show -n $configName --key "contoso-customer-service-aks/deployment-flags/queue-type" --label $BUILD_ENV --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get queue-type flag from $configName."
}
Write-Host "::set-output name=queueType::$queueType"