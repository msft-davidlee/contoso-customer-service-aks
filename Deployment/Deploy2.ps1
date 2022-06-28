param(
    [Parameter(Mandatory = $true)][string]$BUILD_ENV,
    [Parameter(Mandatory = $true)][string]$QueueName,
    [Parameter(Mandatory = $true)][string]$QueueType,
    [Parameter(Mandatory = $true)][string]$AKSMSIId,
    [Parameter(Mandatory = $true)][string]$APP_VERSION,
    [Parameter(Mandatory = $true)][string]$BACKEND_FUNC_STORAGE_SUFFIX,
    [Parameter(Mandatory = $true)][string]$STORAGE_QUEUE_SUFFIX,
    [Parameter(Mandatory = $true)][string]$STACK_NAME_TAG,
    [Parameter(Mandatory = $true)][string]$EnableApplicationGateway)

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
        throw "Unable to find resource by environment for $stackName!"
    }
        
    return $res
}
$ErrorActionPreference = "Stop"


# Prerequsites: 
# * We have already assigned the managed identity with a role in Container Registry with AcrPull role.
# * We also need to determine if the environment is created properly with the right Azure resources.
$all = GetResource -stackName $STACK_NAME_TAG -stackEnvironment $BUILD_ENV
$aks = $all | Where-Object { $_.type -eq 'Microsoft.ContainerService/managedClusters' }
$AKS_RESOURCE_GROUP = $aks.resourceGroup
$AKS_NAME = $aks.name

# Step 2: Login to AKS.
az aks get-credentials --resource-group $AKS_RESOURCE_GROUP --name $AKS_NAME
Write-Host "::set-output name=aksName::$AKS_NAME"

az extension add --name aks-preview

$isInstalled = az aks addon show --addon ingress-appgw -n $AKS_NAME -g $AKS_RESOURCE_GROUP

if (!$isInstalled) {        
    throw "An error has occured. Unable to verify Application gateway add-on is installed on AKS Cluster. Please run CompleteSetup.ps1 script now and when you are done, you can rerun this GitHub workflow."
}
else {
    Write-Host "Perfect, application gateway add-on is already installed."
}

$namespace1 = "dev"
$namespace2 = "stg"
$namespace3 = "prd"

kubectl apply -f ".\Deployment\app1.yaml" --namespace $namespace1
kubectl apply -f ".\Deployment\app2.yaml" --namespace $namespace2
kubectl apply -f ".\Deployment\app3.yaml" --namespace $namespace3

kubectl apply -f ".\Deployment\ing1.yaml" --namespace $namespace1
kubectl apply -f ".\Deployment\ing2.yaml" --namespace $namespace2
kubectl apply -f ".\Deployment\ing3.yaml" --namespace $namespace3


