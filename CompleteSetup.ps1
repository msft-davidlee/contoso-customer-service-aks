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

$appGw = (az resource list -g $resourceGroupName --resource-type "Microsoft.Network/applicationGateways" | ConvertFrom-Json)[0]
if ($appGw) {
    # This is to account for the issue presented in the logs when we enable application gateway with add-on
    # Could not create a role assignment for application gateway: 
    # /subscriptions/***/resourceGroups/aks-dev/providers/Microsoft.Network/applicationGateways/<> 
    # specified in ingressApplicationGateway addon. Are you an Owner on this subscription?
    $addOn = (az aks addon show --addon ingress-appgw -n $aksName -g $resourceGroupName | ConvertFrom-Json)
    $objectId = $addOn.identity.objectId
    az role assignment create --role Contributor --assignee $objectId --scope $appGw.id

    az role assignment create --role Reader --assignee $objectId --resource-group $appGw.resourceGroup
}

kubectl get services -n myapps
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to list all services"
}