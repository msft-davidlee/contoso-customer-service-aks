param([Parameter(Mandatory = $true)][string]$BUILD_ENV)

$ErrorActionPreference = "Stop"

$groups = az group list --tag stack-environment=$BUILD_ENV | ConvertFrom-Json
$resourceGroupName = ($groups | Where-Object { $_.tags.'stack-name' -eq 'aks' -and $_.tags.'stack-environment' -eq $BUILD_ENV }).name
$aks = (az resource list -g $resourceGroupName --resource-type "Microsoft.ContainerService/managedClusters" | ConvertFrom-Json)[0]
az aks get-credentials -n $aks.name -g $resourceGroupName --overwrite-existing
$acr = (az resource list --tag stack-name='shared-container-registry' | ConvertFrom-Json)[0]
$acrName = $acr.name
az aks update -n $aks.name -g $resourceGroupName --attach-acr $acrName
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to update aks with acr."
}

$aksName = $aks.name
$objectId = (az aks show -g $resourceGroupName -n $aksName --query addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -o tsv)
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get object Id for performing role assignment."
}

$resId = (az group show --name $acr.resourceGroup | ConvertFrom-Json).id
az role assignment create --assignee $objectId --role "Key Vault Secrets User" --scope $resId
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to perform Key Vault Secrets User role asignment for aks."
}

az aks check-acr -n $aksName -g $resourceGroupName --acr "$acrName.azurecr.io"
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to verify if aks and acr are connected."
}

# Create namespaces first as we want appgw to watch them
$namespace = "myapps"
$testNamespace = kubectl get namespace $namespace
if (!$testNamespace ) {
    kubectl create namespace $namespace
}
else {
    Write-Host "Skip creating $namespace namespace as it already exist."
}

$apiNamespace = "apis"
$testApiNamespace = kubectl get namespace $apiNamespace
if (!$testApiNamespace) {
    kubectl create namespace $apiNamespace
}
else {
    Write-Host "Skip creating $apiNamespace namespace as it already exist."
}

$appGws = (az resource list -g $resourceGroupName --resource-type "Microsoft.Network/applicationGateways" | ConvertFrom-Json)
if ($appGws -and $appGws.Length -eq 1) {
    
    $appGw = $appGws[0]
    az extension add --name aks-preview

    $isInstalled = az aks addon show --addon ingress-appgw -n $aksName -g $resourceGroupName
    if (!$isInstalled) {

        $namespace1 = "dev"
        $namespace2 = "stg"
        $namespace3 = "prd"

        kubectl create namespace $namespace1
        kubectl create namespace $namespace2
        kubectl create namespace $namespace3

        az aks enable-addons -n $aksName -g $resourceGroupName -a ingress-appgw --appgw-id $appGw.id --appgw-watch-namespace "dev,stg,prd"
        if ($LastExitCode -ne 0) {
            throw "An error has occured. Unable to enable Application gateway add-on."
        }
    }

    $assignee = (az aks addon show --addon ingress-appgw -n $aksName -g $resourceGroupName | ConvertFrom-Json).identity.objectId
    $scope = (az identity list -g $resourceGroupName | ConvertFrom-Json).id 
    az role assignment create --role "Managed Identity Operator" --assignee $assignee --scope $scope
}
else {
    Write-Host "No application gateway found in $resourceGroupName"
}