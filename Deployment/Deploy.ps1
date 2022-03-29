param(
    [Parameter(Mandatory = $true)][string]$AKS_RESOURCE_GROUP,    
    [Parameter(Mandatory = $true)][string]$AKS_NAME,    
    [Parameter(Mandatory = $true)][string]$BUILD_ENV,
    [Parameter(Mandatory = $true)][string]$DbName,
    [Parameter(Mandatory = $true)][string]$SqlServer,
    [Parameter(Mandatory = $true)][string]$SqlUsername,
    [Parameter(Mandatory = $true)][string]$Backend,
    [Parameter(Mandatory = $true)][string]$QueueType,
    [Parameter(Mandatory = $true)][string]$AKSMSIId,
    [Parameter(Mandatory = $true)][string]$KeyVaultName,
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$QueueStorageName,
    [Parameter(Mandatory = $true)][string]$BackendStorageName,
    [Parameter(Mandatory = $true)][string]$QueueName,
    [Parameter(Mandatory = $true)][bool]$EnableFrontdoor)

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
$ErrorActionPreference = "Stop"

# Prerequsites: 
# * We have already assigned the managed identity with a role in Container Registry with AcrPull role.
# * We also need to determine if the environment is created properly with the right Azure resources.

$kv = GetResource -stackName shared-key-vault -stackEnvironment prod
$kvName = $kv.name
$sqlPassword = (az keyvault secret show -n contoso-customer-service-sql-password --vault-name $kvName --query value | ConvertFrom-Json)

$AAD_INSTANCE = (az keyvault secret show -n contoso-customer-service-aad-instance --vault-name $kvName --query value | ConvertFrom-Json)
$AAD_DOMAIN = (az keyvault secret show -n contoso-customer-service-aad-domain --vault-name $kvName --query value | ConvertFrom-Json)
$AAD_TENANT_ID = (az keyvault secret show -n contoso-customer-service-aad-tenant-id --vault-name $kvName --query value | ConvertFrom-Json)
$AAD_CLIENT_ID = (az keyvault secret show -n contoso-customer-service-aad-client-id --vault-name $kvName --query value | ConvertFrom-Json)
$AAD_CLIENT_SECRET = (az keyvault secret show -n contoso-customer-service-aad-client-secret --vault-name $kvName --query value | ConvertFrom-Json)
$AAD_AUDIENCE = (az keyvault secret show -n contoso-customer-service-aad-app-audience --vault-name $kvName --query value | ConvertFrom-Json)
$AAD_SCOPES = (az keyvault secret show -n contoso-customer-service-aad-scope --vault-name $kvName --query value | ConvertFrom-Json)
$acr = GetResource -stackName shared-container-registry -stackEnvironment prod
$acrName = $acr.Name

$strs = GetResource -stackName shared-storage -stackEnvironment prod
$BuildAccountName = $strs.name

# The version here can be configurable so we can also pull dev specific packages.
$version = "v4.4"

az storage blob download-batch --destination . -s apps --account-name $BuildAccountName --pattern *$version*.zip
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to download files."
}

# Step 1: Deploy DB.
# Deploy specfic version of SQL script
$sqlFile = "Migrations-$version.sql"
az storage blob download-batch --destination . -s apps --account-name $BuildAccountName --pattern $sqlFile
Invoke-Sqlcmd -InputFile $sqlFile -ServerInstance $SqlServer -Database $DbName -Username $SqlUsername -Password $sqlPassword

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

$foundHelmKedaCoreRepo = ($repoList | Where-Object { $_.name -eq "kedacore" }).Count -eq 1

# Step 4a: Add the ingress-nginx repository
if (!$foundHelmKedaCoreRepo) {
    helm repo add kedacore https://kedacore.github.io/charts
}
else {
    Write-Host "Skip adding kedacore repo with helm as it already exist."
}

helm repo update

# Step 4b.
$testSecret = (kubectl get secret aks-ingress-tls -o json -n $namespace)
if (!$testSecret) {
    az storage blob download-batch -d . -s certs --account-name $BuildAccountName
    kubectl create secret tls aks-ingress-tls `
        --namespace $namespace `
        --key .\demo.contoso.com.key `
        --cert .\demo.contoso.com.crt

    if ($LastExitCode -ne 0) {
        throw "An error has occured. Unable to set TLS for demo.contoso.com."
    }
}
    
# Step 4c. Install ingress controller
helm install ingress-nginx ingress-nginx/ingress-nginx --namespace $namespace `
    --set controller.replicaCount=2 `
    --set controller.metrics.enabled=true

helm install keda kedacore/keda -n $namespace

if ($EnableFrontdoor) {
    $content = Get-Content .\Deployment\external-ingress-with-fd.yaml
}
else {
    $content = Get-Content .\Deployment\external-ingress.yaml    
}

# Note: Interestingly, we need to set namespace in the yaml file although we have setup the namespace here in apply.
$content = $content.Replace('$NAMESPACE', $namespace)
Set-Content -Path ".\external-ingress.yaml" -Value $content
$rawOut = (kubectl apply -f .\external-ingress.yaml --namespace $namespace 2>&1)
if ($LastExitCode -ne 0) {
    $errorMsg = $rawOut -Join '`n'
    if ($errorMsg.Contains("failed calling webhook") -and $errorMsg.Contains("validate.nginx.ingress.kubernetes.io")) {
        Write-Host "Attempting to recover from 'failed calling webhook' error."

        # See: https://pet2cattle.com/2021/02/service-ingress-nginx-controller-admission-not-found
        kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission
        kubectl apply -f .\external-ingress.yaml --namespace $namespace
        if ($LastExitCode -ne 0) {
            throw "An error has occured. Unable to deploy external ingress."
        }
    }
    else {
        throw "An error has occured. Unable to deploy external ingress."
    }    
}

# Step 5: Setup configuration for resources
# $dbConnectionString = "Server=tcp:$SqlServer,1433;Initial Catalog=$DbName;Persist Security Info=False;User ID=$SqlUsername;Password=$SqlPassword;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
# See: https://kubernetes.io/docs/concepts/configuration/secret/#use-case-dotfiles-in-a-secret-volume
# $base64DbConnectionString = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($dbConnectionString))

if ($QueueType -eq "ServiceBus") { 
    $imageName = "contoso-demo-service-bus-shipping-func:$version"
    $SenderQueueConnectionString = az servicebus namespace authorization-rule keys list --resource-group $AKS_RESOURCE_GROUP `
        --namespace-name $AKS_NAME --name Sender --query primaryConnectionString | ConvertFrom-Json    
    
    if ($LastExitCode -ne 0) {
        throw "An error has occured. Unable get service bus connection string."
    }
    $SenderQueueConnectionString = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($SenderQueueConnectionString))

    $ListenerQueueConnectionString = az servicebus namespace authorization-rule keys list --resource-group $AKS_RESOURCE_GROUP `
        --namespace-name $AKS_NAME --name Listener --query primaryConnectionString | ConvertFrom-Json
    if ($LastExitCode -ne 0) {
        throw "An error has occured. Unable get service bus listener connection string."
    }
    $QueueConnectionString = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ListenerQueueConnectionString))
}

if ($QueueType -eq "Storage") {
    $imageName = "contoso-demo-storage-queue-func:$version"
    $key1 = (az storage account keys list -g $AKS_RESOURCE_GROUP -n $QueueStorageName | ConvertFrom-Json)[0].value

    if ($LastExitCode -ne 0) {
        throw "An error has occured. Unable get storage account key."
    }

    $QueueConnectionString = "DefaultEndpointsProtocol=https;AccountName=$QueueStorageName;AccountKey=$key1;EndpointSuffix=core.windows.net"
    $SenderQueueConnectionString = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($QueueConnectionString ));
}

# Step: 5b: Configure Azure Key Vault
$content = Get-Content .\Deployment\azurekeyvault.yaml
$content = $content.Replace('$MANAGEDID', $AKSMSIId)
$content = $content.Replace('$KEYVAULTNAME', $KeyVaultName)
$content = $content.Replace('$TENANTID', $TenantId)

Set-Content -Path ".\azurekeyvault.yaml" -Value $content
kubectl apply -f ".\azurekeyvault.yaml" --namespace $namespace

if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy azure key vault app."
}

# Step 6: Deploy customer service app.

$backendKey = (az storage account keys list -g $AKS_RESOURCE_GROUP -n $BackendStorageName | ConvertFrom-Json)[0].value
$backendConn = "DefaultEndpointsProtocol=https;AccountName=$BackendStorageName;AccountKey=$backendKey;EndpointSuffix=core.windows.net"

$content = Get-Content .\Deployment\backendservice.yaml
$content = $content.Replace('$IMAGE', $imageName)
$content = $content.Replace('$DBSOURCE', $SqlServer)
$content = $content.Replace('$DBNAME', $DbName)
$content = $content.Replace('$DBUSERID', $SqlUsername)
$content = $content.Replace('$ACRNAME', $acrName)
$content = $content.Replace('$AZURE_STORAGE_CONNECTION', $backendConn)
$content = $content.Replace('$AZURE_STORAGEQUEUE_CONNECTION', $QueueConnectionString)

Set-Content -Path ".\backendservice.yaml" -Value $content
kubectl apply -f ".\backendservice.yaml" --namespace $namespace
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy backend service app."
}

# Step 7: Deploy customer service app.
$content = Get-Content .\Deployment\customerservice.yaml
$content = $content.Replace('$DBSOURCE', $SqlServer)
$content = $content.Replace('$DBNAME', $DbName)
$content = $content.Replace('$DBUSERID', $SqlUsername)
$content = $content.Replace('$ACRNAME', $acrName)
$content = $content.Replace('$NAMESPACE', $namespace)

$content = $content.Replace('$AADINSTANCE', $AAD_INSTANCE)
$content = $content.Replace('$AADTENANTID', $AAD_TENANT_ID)
$content = $content.Replace('$AADDOMAIN', $AAD_DOMAIN)
$content = $content.Replace('$AADCLIENTID', $AAD_CLIENT_ID)
$content = $content.Replace('$AADCLIENTSECRET', $AAD_CLIENT_SECRET)
$content = $content.Replace('$AADSCOPES', $AAD_SCOPES)

$content = $content.Replace('$VERSION', $version)

Set-Content -Path ".\customerservice.yaml" -Value $content
kubectl apply -f ".\customerservice.yaml" --namespace $namespace
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy customer service app."
}

# Step 8: Deploy Alternate Id service.
$content = Get-Content .\Deployment\alternateid.yaml
$content = $content.Replace('$DBSOURCE', $SqlServer)
$content = $content.Replace('$DBNAME', $DbName)
$content = $content.Replace('$DBUSERID', $SqlUsername)
$content = $content.Replace('$ACRNAME', $acrName)

$content = $content.Replace('$AADINSTANCE', $AAD_INSTANCE)
$content = $content.Replace('$AADTENANTID', $AAD_TENANT_ID)
$content = $content.Replace('$AADDOMAIN', $AAD_DOMAIN)
$content = $content.Replace('$AADCLIENTID', $AAD_CLIENT_ID)
$content = $content.Replace('$AADAUDIENCE', $AAD_AUDIENCE)

$content = $content.Replace('$VERSION', $version)

Set-Content -Path ".\alternateid.yaml" -Value $content
kubectl apply -f ".\alternateid.yaml" --namespace $namespace

if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy alternate id app."
}

# Step 9: Deploy Partner api.
$content = Get-Content .\Deployment\partnerapi.yaml
$content = $content.Replace('$BASE64CONNECTIONSTRING', $SenderQueueConnectionString)
$content = $content.Replace('$ACRNAME', $acrName)
$content = $content.Replace('$DBSOURCE', $SqlServer)
$content = $content.Replace('$DBNAME', $DbName)
$content = $content.Replace('$DBUSERID', $SqlUsername)
$content = $content.Replace('$SHIPPINGREPOSITORYTYPE', $QueueType)

$content = $content.Replace('$VERSION', $version)

Set-Content -Path ".\partnerapi.yaml" -Value $content
kubectl apply -f ".\partnerapi.yaml" --namespace $namespace

if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy partner api app."
}

# Step 10: Deploy Member service.
$content = Get-Content .\Deployment\memberservice.yaml
$content = $content.Replace('$DBSOURCE', $SqlServer)
$content = $content.Replace('$DBNAME', $DbName)
$content = $content.Replace('$DBUSERID', $SqlUsername)
$content = $content.Replace('$ACRNAME', $acrName)
$content = $content.Replace('$NAMESPACE', $namespace)

$content = $content.Replace('$AADINSTANCE', $AAD_INSTANCE)
$content = $content.Replace('$AADTENANTID', $AAD_TENANT_ID)
$content = $content.Replace('$AADDOMAIN', $AAD_DOMAIN)
$content = $content.Replace('$AADCLIENTID', $AAD_CLIENT_ID)
$content = $content.Replace('$AADAUDIENCE', $AAD_AUDIENCE)

$content = $content.Replace('$VERSION', $version)

Set-Content -Path ".\memberservice.yaml" -Value $content
kubectl apply -f ".\memberservice.yaml" --namespace $namespace
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy member service app."
}

# Step 10: Function scaling based on specific scalers
if ($QueueType -eq "ServiceBus") { 
    $content = Get-Content .\Deployment\backendservicebus.yaml
    $content = $content.Replace('$QUEUENAME', $QueueName)
    $content = $content.Replace('$BASE64CONNECTIONSTRING', $ListenerQueueConnectionString)

    Set-Content -Path ".\backendservicebus.yaml" -Value $content
    kubectl apply -f ".\backendservicebus.yaml" --namespace $namespace
    if ($LastExitCode -ne 0) {
        throw "An error has occured. Unable to deploy service bus keda scaler."
    }
}

if ($QueueType -eq "Storage") {
    $content = Get-Content .\Deployment\backendstorage.yaml
    $content = $content.Replace('$QUEUENAME', $QueueName)
    $content = $content.Replace('$BASE64CONNECTIONSTRING', $QueueConnectionString)
    $content = $content.Replace('$STORAGEACCOUNTNAME', $BackendStorageName)

    Set-Content -Path ".\backendstorage.yaml" -Value $content
    kubectl apply -f ".\backendstorage.yaml" --namespace $namespace
    if ($LastExitCode -ne 0) {
        throw "An error has occured. Unable to deploy storage keda scaler."
    }
}

# Step 11: Output ip address
$serviceip = kubectl get ing demo-ingress -n $namespace -o jsonpath='{.status.loadBalancer.ingress[*].ip}'
Write-Host "::set-output name=serviceip::$serviceip"