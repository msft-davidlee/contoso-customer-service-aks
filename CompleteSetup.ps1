param([Parameter(Mandatory = $true)][string]$ArdEnvironment)

$ErrorActionPreference = "Stop"

$ArdSolutionId = "aks-demo"

$groups = az group list --tag ard-environment=$ArdEnvironment | ConvertFrom-Json
$resourceGroupName = ($groups | Where-Object { $_.tags.'ard-solution-id' -eq $ArdSolutionId -and !$_.tags.'aks-managed-cluster-rg' }).name
$aks = (az resource list -g $resourceGroupName --resource-type "Microsoft.ContainerService/managedClusters" | ConvertFrom-Json)[0]
if ($LastExitCode -ne 0) {
    throw "An error has occured. Error locating AKS."
}

if (!$aks) {
    throw "Unable to locate AKS."
}

az aks get-credentials -n $aks.name -g $resourceGroupName --overwrite-existing
$acr = (az resource list --tag ard-resource-id=shared-container-registry | ConvertFrom-Json)
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

$appGws = (az resource list -g $resourceGroupName --resource-type "Microsoft.Network/applicationGateways" | ConvertFrom-Json)
if ($appGws -and $appGws.Length -eq 1) {
    
    $appGw = $appGws[0]
    az extension add --name aks-preview

    $isInstalled = az aks addon show --addon ingress-appgw -n $aksName -g $resourceGroupName
    if (!$isInstalled) {
        az aks enable-addons -n $aksName -g $resourceGroupName -a ingress-appgw --appgw-id $appGw.id
        if ($LastExitCode -ne 0) {
            throw "An error has occured. Unable to enable Application gateway add-on."
        }
    }

    $assignee = (az aks addon show --addon ingress-appgw -n $aksName -g $resourceGroupName | ConvertFrom-Json).identity.objectId
    $scope = (az identity list -g $resourceGroupName | ConvertFrom-Json).id 
    az role assignment create --role "Managed Identity Operator" --assignee $assignee --scope $scope
}