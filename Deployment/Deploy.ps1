param(
    [string]$AKS_RESOURCE_GROUP,
    [string]$AKS_NAME,
    [string]$NETWORKING_PREFIX,
    [string]$BUILD_ENV,
    [string]$AppCode,
    [string]$DeployCode,
    [string]$DbName,
    [string]$SqlServer,
    [string]$SqlUsername,
    [string]$SqlPassword,
    [string]$Backend,
    [string]$AAD_INSTANCE,
    [string]$AAD_DOMAIN,
    [string]$AAD_TENANT_ID,
    [string]$AAD_CLIENT_ID,
    [string]$AAD_CLIENT_SECRET,
    [switch]$UseServiceBus)

$ErrorActionPreference = "Stop"
# Prerequsites: 
# * We have already assigned the managed identity with a role in Container Registry with AcrPull role.
# * We also need to determine if the environment is created properly with the right Azure resources.
$platformRes = (az resource list --tag stack-name=$NETWORKING_PREFIX | ConvertFrom-Json)
if (!$platformRes) {
    throw "Unable to find eligible platform resources!"
}
if ($platformRes.Length -eq 0) {
    throw "Unable to find 'ANY' eligible platform resources!"
}

$acr = ($platformRes | Where-Object { $_.type -eq "Microsoft.ContainerRegistry/registries" -and $_.resourceGroup.EndsWith("-$BUILD_ENV") })
if (!$acr) {
    throw "Unable to find eligible platform container registry!"
}
$acrName = $acr.Name

$strs = ($platformRes | Where-Object { $_.type -eq "Microsoft.Storage/storageAccounts" -and $_.resourceGroup.EndsWith("-$BUILD_ENV") })
if (!$strs) {
    throw "Unable to find eligible platform storage account!"
}
$BuildAccountName = $strs.name

# Step 1: Deploy DB.
Invoke-Sqlcmd -InputFile "$AppCode\Db\Migrations.sql" -ServerInstance $SqlServer -Database $DbName -Username $SqlUsername -Password $SqlPassword

# Step 2: Login to AKS.
az aks get-credentials --resource-group $AKS_RESOURCE_GROUP --name $AKS_NAME

# Step 3: Create a namespace for your resources if it does not exist.
$namespace = "myapps"
$testNamespace = kubectl get namespace $namespace
if (!$testNamespace ) {
    kubectl create namespace $namespace
}
else {
    Write-Host "Skip creating frontend namespace as it already exist."
}

# Step 4: Setup an external ingress controller
$repoList = helm repo list --output json | ConvertFrom-Json
$foundHelmIngressRepo = ($repoList | Where-Object { $_.name -eq "ingress-nginx" }).Count -eq 1

# Step 4a: Add the ingress-nginx repository
if (!$foundHelmIngressRepo ) {
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
}
else {
    Write-Host "Skip adding ingress-nginx repo with helm as it already exist."
}

helm repo update

# Step 4b.
az storage blob download-batch -d . -s certs --account-name $BuildAccountName

kubectl create secret tls aks-ingress-tls `
    --namespace $namespace `
    --key .\demo.contoso.com.key `
    --cert .\demo.contoso.com.crt

if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to set TLS for demo.contoso.com."
}
    
# Step 4c. Install ingress controller
helm install ingress-nginx ingress-nginx/ingress-nginx --namespace $namespace
kubectl apply -f .\$DeployCode\Deployment\external-ingress.yaml --namespace $namespace

# Step 5: Setup configuration for resources
$dbConnectionString = "Server=tcp:$SqlServer,1433;Initial Catalog=$DbName;Persist Security Info=False;User ID=$SqlUsername;Password=$SqlPassword;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
# See: https://kubernetes.io/docs/concepts/configuration/secret/#use-case-dotfiles-in-a-secret-volume
$base64DbConnectionString = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($dbConnectionString))



if ($UseServiceBus) {
    $QueueType = "ServiceBus";
    $SenderQueueConnectionString = az servicebus namespace authorization-rule keys list --resource-group $AKS_RESOURCE_GROUP `
        --namespace-name $AKS_NAME --name Sender --query primaryConnectionString | ConvertFrom-Json
    $ListenerQueueConnectionString = az servicebus namespace authorization-rule keys list --resource-group $AKS_RESOURCE_GROUP `
        --namespace-name $AKS_NAME --name Listener --query primaryConnectionString | ConvertFrom-Json  
        
    $SenderQueueConnectionString = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($SenderQueueConnectionString))
    $ListenerQueueConnectionString = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ListenerQueueConnectionString))
}
else {
    $key1 = (az storage account keys list -g $AKS_RESOURCE_GROUP -n $AKS_NAME | ConvertFrom-Json)[0].value
    $QueueType = "Storage";
    $connStr = "DefaultEndpointsProtocol=https;AccountName=$AKS_NAME;AccountKey=$key1;EndpointSuffix=core.windows.net"
    $connStr = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($connStr))
    $SenderQueueConnectionString = $connStr;
    $ListenerQueueConnectionString = $connStr;
}

# Step 6: Deploy customer service app.
$content = Get-Content .\$DeployCode\Deployment\customerservice.yaml
$content = $content.Replace('$BASE64CONNECTIONSTRING', $base64DbConnectionString)
$content = $content.Replace('$ACRNAME', $acrName)
$content = $content.Replace('$NAMESPACE', $namespace)

$content = $content.Replace('$AADINSTANCE', $AAD_INSTANCE)
$content = $content.Replace('$AADTENANTID', $AAD_TENANT_ID)
$content = $content.Replace('$AADDOMAIN', $AAD_DOMAIN)
$content = $content.Replace('$AADCLIENTID', $AAD_CLIENT_ID)
$content = $content.Replace('$AADCLIENTSECRET', $AAD_CLIENT_SECRET)

Set-Content -Path ".\customerservice.yaml" -Value $content
kubectl apply -f ".\customerservice.yaml" --namespace $namespace
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy customer service app."
}

# Step 7: Deploy Alternate Id service.
$content = Get-Content .\$DeployCode\Deployment\alternateid.yaml
$content = $content.Replace('$BASE64CONNECTIONSTRING', $base64DbConnectionString)
$content = $content.Replace('$ACRNAME', $acrName)

Set-Content -Path ".\alternateid.yaml" -Value $content
kubectl apply -f ".\alternateid.yaml" --namespace $namespace

# Step 8: Deploy Partner api.
$content = Get-Content .\$DeployCode\Deployment\partnerapi.yaml
$content = $content.Replace('$BASE64CONNECTIONSTRING', $base64DbConnectionString)
$content = $content.Replace('$ACRNAME', $acrName)
$content = $content.Replace('$SENDERQUEUECONNECTIONSTRING', $SenderQueueConnectionString)
$content = $content.Replace('$SHIPPINGREPOSITORYTYPE', $QueueType)

Set-Content -Path ".\partnerapi.yaml" -Value $content
kubectl apply -f ".\partnerapi.yaml" --namespace $namespace

# Step 9: Deploy backend
az storage blob download --file contoso-demo-storage-queue-func-v1.zip --container-name apps --name contoso-demo-storage-queue-func-v1.zip --account-name $BuildAccountName
az functionapp deployment source config-zip -g $AKS_RESOURCE_GROUP -n $Backend --src "contoso-demo-storage-queue-func-v1.zip"
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy backend."
}
