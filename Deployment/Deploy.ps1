param(
    [Parameter(Mandatory = $true)][string]$ArdEnvironment,
    [Parameter(Mandatory = $true)][string]$QueueName,
    [Parameter(Mandatory = $true)][string]$QueueType,
    [Parameter(Mandatory = $true)][string]$AKSMSIId,
    [Parameter(Mandatory = $true)][string]$APP_VERSION,
    [Parameter(Mandatory = $true)][string]$BACKEND_FUNC_STORAGE_SUFFIX,
    [Parameter(Mandatory = $true)][string]$STORAGE_QUEUE_SUFFIX,
    [Parameter(Mandatory = $true)][string]$ArdSolutionId,
    [Parameter(Mandatory = $true)][string]$EnableApplicationGateway)

$ErrorActionPreference = "Stop"

# This is because the deploy.bicep is using the notation of skip but our powershell script
# here is not, so we are resetting it.
if ($EnableApplicationGateway -eq "skip") {
    $EnableApplicationGateway = "true"
}

# Prerequsites: 
# * We have already assigned the managed identity with a role in Container Registry with AcrPull role.
# * We also need to determine if the environment is created properly with the right Azure resources.
$all = az resource list --tag ard-solution-id=$ArdSolutionId | ConvertFrom-Json
$all = $all | Where-Object { $_.tags.'ard-environment' -eq $ArdEnvironment }
$aks = $all | Where-Object { $_.type -eq 'Microsoft.ContainerService/managedClusters' }
$AKS_RESOURCE_GROUP = $aks.resourceGroup
$AKS_NAME = $aks.name

$acr = (az resource list --tag ard-resource-id=shared-container-registry | ConvertFrom-Json)
$acrName = $acr.Name

$allMessages = (az aks check-acr -n $AKS_NAME -g $AKS_RESOURCE_GROUP --acr "$acrName.azurecr.io" 2>&1)
$allMessage = $allMessages -Join '`n'
Write-Host $allMessage
$acrErr = "An error has occured. Unable to verify if aks and acr are connected. Please run CompleteSetup.ps1 script now and when you are done, you can rerun this GitHub workflow."
if ($LastExitCode -ne 0) {
    throw $acrErr
}

if ($allMessage.ToUpper().Contains("FAILED")) {
    throw $acrErr
}
else {
    Write-Host $allMessage
}

$count = ($allMessage | Select-String -Pattern "SUCCEEDED" -AllMatches).Matches.Count
if ($count -lt 3) {
    Write-Host "SUCCEEDED Count = $count"
    throw $acrErr
}

# Step 2: Login to AKS.
az aks get-credentials --resource-group $AKS_RESOURCE_GROUP --name $AKS_NAME
Write-Host "::set-output name=aksName::$AKS_NAME"

$sql = $all | Where-Object { $_.type -eq 'Microsoft.Sql/servers' }
$sqlSv = az sql server show --name $sql.name -g $sql.resourceGroup | ConvertFrom-Json
$SqlServer = $sqlSv.fullyQualifiedDomainName
$SqlUsername = $sqlSv.administratorLogin

$db = $all | Where-Object { $_.type -eq 'Microsoft.Sql/servers/databases' }
$dbNameParts = $db.name.Split('/')
$DbName = $dbNameParts[1]

$kv = (az resource list --tag ard-resource-id=shared-key-vault | ConvertFrom-Json)
if (!$kv) {
    throw "Unable to find eligible shared key vault resource!"
}
$KeyVaultName = $kv.name

$AAD_INSTANCE = (az keyvault secret show -n contoso-customer-service-aad-instance --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_DOMAIN = (az keyvault secret show -n contoso-customer-service-aad-domain --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_TENANT_ID = (az keyvault secret show -n contoso-customer-service-aad-tenant-id --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_CLIENT_ID = (az keyvault secret show -n contoso-customer-service-aad-client-id --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_CLIENT_SECRET = (az keyvault secret show -n contoso-customer-service-aad-client-secret --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_AUDIENCE = (az keyvault secret show -n contoso-customer-service-aad-app-audience --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_SCOPES = (az keyvault secret show -n contoso-customer-service-aad-scope --vault-name $KeyVaultName --query value | ConvertFrom-Json)

$log = $all | Where-Object { $_.type -eq 'microsoft.insights/components' }
az extension add --name application-insights
$appInsightsKey = az monitor app-insights component show --app $log.name -g $log.resourceGroup --query "instrumentationKey" -o tsv
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable get app insights instrumentation key."
}

$config = (az resource list --tag ard-resource-id=shared-app-configuration | ConvertFrom-Json)
$configName = $config.name

$customerServiceDomain = (az appconfig kv show -n $configName --key "$ArdSolutionId/cert-domain-names/ingress/customer-service" --auth-mode login | ConvertFrom-Json).value
$apiDomain = (az appconfig kv show -n $configName --key "$ArdSolutionId/cert-domain-names/ingress/api" --auth-mode login | ConvertFrom-Json).value
$memberPortalDomain = (az appconfig kv show -n $configName --key "$ArdSolutionId/cert-domain-names/ingress/member-portal" --auth-mode login | ConvertFrom-Json).value

if (!$customerServiceDomain) {
    throw "Unable to get Customer Service Domain"
}

if (!$apiDomain) {
    throw "Unable to get API Domain"
}

if (!$memberPortalDomain) {
    throw "Unable to get Member Portal Domain"
}

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

if ($EnableApplicationGateway -ne "true") {

    # Step 4a: Add the ingress-nginx repository
    $foundHelmIngressRepo = ($repoList | Where-Object { $_.name -eq "ingress-nginx" }).Count -eq 1    
    if (!$foundHelmIngressRepo ) {
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx   
    }
    else {
        Write-Host "Skip adding ingress-nginx repo with helm as it already exist."
    }
}

$foundHelmKedaCoreRepo = ($repoList | Where-Object { $_.name -eq "kedacore" }).Count -eq 1
if (!$foundHelmKedaCoreRepo) {
    helm repo add kedacore https://kedacore.github.io/charts
}
else {
    Write-Host "Skip adding kedacore repo with helm as it already exist."
}

helm repo update

# Step 4b.
$testSecret = (kubectl get secret aks-csv-tls -o json -n $namespace)
if (!$testSecret) {

    $strs = (az resource list --tag ard-resource-id=shared-storage | ConvertFrom-Json)
    if (!$strs) {
        throw "Unable to find eligible platform storage account!"
    }
    $BuildAccountName = $strs.name

    az storage blob download-batch -d . -s certs --account-name $BuildAccountName

    kubectl create secret tls aks-csv-tls `
        --namespace $namespace `
        --key .\cert.key `
        --cert .\cert.cer

    kubectl create secret tls aks-api-tls `
        --namespace $namespace `
        --key .\cert.key `
        --cert .\cert.cer

    kubectl create secret tls aks-mem-tls `
        --namespace $namespace `
        --key .\cert.key `
        --cert .\cert.cer

    if ($LastExitCode -ne 0) {
        throw "An error has occured. Unable to set TLS for secrets."
    }
}

if ($EnableApplicationGateway -eq "true") {

    # Step 4c. Check if Application Gateway Ingress Controller (AGIC) using add-on method is installed.
    az extension add --name aks-preview

    $isInstalled = az aks addon show --addon ingress-appgw -n $AKS_NAME -g $AKS_RESOURCE_GROUP
    
    if (!$isInstalled) {        
        throw "An error has occured. Unable to verify Application gateway add-on is installed on AKS Cluster. Please run CompleteSetup.ps1 script now and when you are done, you can rerun this GitHub workflow."
    }
    else {
        Write-Host "Perfect, application gateway add-on is already installed."
    }
}
else {

    # Step 4c. Install ingress controller
    # See: https://github.com/kubernetes/ingress-nginx/blob/main/docs/user-guide/monitoring.md

    # Public IP is assigned only for Prod which we will reuse.
    # See: https://docs.microsoft.com/en-us/azure/aks/ingress-static-ip?tabs=azure-cli
    $networks = (az resource list --tag ard-solution-id=networking-pri | ConvertFrom-Json)
    if (!$networks) {
        throw "Unable to find eligible shared key vault resource!"
    }

    $pip = $networks | Where-Object { $_.type -eq "Microsoft.Network/publicIPAddresses" -and $_.tags.'ard-environment' -eq "prod" }
    $ip = $pip.ipAddress    
    $ipFqdn = "contosocoffeehouseapps"
    $ipResGroup = $pipRes.resourceGroup

    Write-Host "Configure ingress with static IP: $ip $ipFqdn $ipResGroup"

    helm install ingress-nginx ingress-nginx/ingress-nginx --namespace $namespace `
        --set controller.replicaCount=2 `
        --set controller.service.loadBalancerIP=$ip `
        --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"=$ipFqdn `
        --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-resource-group"=$ipResGroup `
        --set controller.service.annotations."service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path"="/healthz" `
        --set controller.nodeSelector."kubernetes\.io/os"=linux `
        --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux `
        --set controller.metrics.enabled=true `
        --set-string controller.podAnnotations."prometheus\.io/scrape"="true" `
        --set-string controller.podAnnotations."prometheus\.io/port"="10254"   
}

helm install keda kedacore/keda -n $namespace

# Step 5: Setup configuration for resources

if ($QueueType -eq "ServiceBus") { 
    $imageName = "contoso-demo-service-bus-shipping-func:$APP_VERSION"

    $sb = $all | Where-Object { $_.type -eq 'Microsoft.ServiceBus/namespaces' }
    $ServiceBusName = $sb.name

    $SenderQueueConnectionString = az servicebus namespace authorization-rule keys list --resource-group $AKS_RESOURCE_GROUP `
        --namespace-name $ServiceBusName --name Sender --query primaryConnectionString | ConvertFrom-Json    
    
    if ($LastExitCode -ne 0) {
        throw "An error has occured. Unable get service bus connection string."
    }
    $SenderQueueConnectionString = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($SenderQueueConnectionString))

    $QueueConnectionString = az servicebus namespace authorization-rule keys list --resource-group $AKS_RESOURCE_GROUP `
        --namespace-name $ServiceBusName --name Listener --query primaryConnectionString | ConvertFrom-Json
    if ($LastExitCode -ne 0) {
        throw "An error has occured. Unable get service bus listener connection string."
    }
    $ListenerQueueConnectionString = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($QueueConnectionString))
}

if ($QueueType -eq "Storage") {

    $storage = $all | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts' -and $_.name.EndsWith($STORAGE_QUEUE_SUFFIX) }
    if (!$storage) {
        throw "Unable to locate storage queue account name."
    }
    $QueueStorageName = $storage.name

    $imageName = "contoso-demo-storage-queue-func:$APP_VERSION"
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

$TenantId = az account show --query "tenantId" -o tsv
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable get tenant Id."
}
$content = $content.Replace('$TENANTID', $TenantId)

Set-Content -Path ".\azurekeyvault.yaml" -Value $content
kubectl apply -f ".\azurekeyvault.yaml" --namespace $namespace

if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy azure key vault app."
}

# Step: 5c: Configure Prometheus
$content = Get-Content .\Deployment\prometheus\kustomization.yaml
$content = $content.Replace('$NAMESPACE', $namespace)
Set-Content -Path ".\Deployment\prometheus\kustomization.yaml" -Value $content

$content = Get-Content .\Deployment\prometheus\prometheus.yaml
$content = $content.Replace('$NAMESPACE', $namespace)
Set-Content -Path ".\Deployment\prometheus\prometheus.yaml" -Value $content

kubectl apply --kustomize Deployment/prometheus -n $namespace
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to apply prometheus directory."
}

# Step 6: Deploy customer service app.

$storage = $all | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts' -and $_.name.EndsWith($BACKEND_FUNC_STORAGE_SUFFIX) }
if (!$storage) {
    throw "Unable to locate backend func storage account name."
}
$BackendStorageName = $storage.name

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
$content = $content.Replace('$QUEUENAME', $QueueName)
$content = $content.Replace('$APPINSIGHTSKEY', $appInsightsKey)

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
$content = $content.Replace('$APPINSIGHTSKEY', $appInsightsKey)
$content = $content.Replace('$VERSION', $APP_VERSION)

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
$content = $content.Replace('$NAMESPACE', $namespace)

$content = $content.Replace('$AADINSTANCE', $AAD_INSTANCE)
$content = $content.Replace('$AADTENANTID', $AAD_TENANT_ID)
$content = $content.Replace('$AADDOMAIN', $AAD_DOMAIN)
$content = $content.Replace('$AADCLIENTID', $AAD_CLIENT_ID)
$content = $content.Replace('$AADAUDIENCE', $AAD_AUDIENCE)
$content = $content.Replace('$APPINSIGHTSKEY', $appInsightsKey)
$content = $content.Replace('$VERSION', $APP_VERSION)

Set-Content -Path ".\alternateid.yaml" -Value $content
kubectl apply -f ".\alternateid.yaml" --namespace $namespace

if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy alternate id app."
}

# Step 9: Deploy Partner api.
$content = Get-Content .\Deployment\partnerapi.yaml
$content = $content.Replace('$BASE64CONNECTIONSTRING', $SenderQueueConnectionString)
$content = $content.Replace('$ACRNAME', $acrName)
$content = $content.Replace('$NAMESPACE', $namespace)
$content = $content.Replace('$DBSOURCE', $SqlServer)
$content = $content.Replace('$DBNAME', $DbName)
$content = $content.Replace('$DBUSERID', $SqlUsername)
$content = $content.Replace('$SHIPPINGREPOSITORYTYPE', $QueueType)
$content = $content.Replace('$AADINSTANCE', $AAD_INSTANCE)
$content = $content.Replace('$AADTENANTID', $AAD_TENANT_ID)
$content = $content.Replace('$AADDOMAIN', $AAD_DOMAIN)
$content = $content.Replace('$AADCLIENTID', $AAD_CLIENT_ID)
$content = $content.Replace('$AADAUDIENCE', $AAD_AUDIENCE)
$content = $content.Replace('$APPINSIGHTSKEY', $appInsightsKey)
$content = $content.Replace('$VERSION', $APP_VERSION)

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
$content = $content.Replace('$APPINSIGHTSKEY', $appInsightsKey)
$content = $content.Replace('$VERSION', $APP_VERSION)

Set-Content -Path ".\memberservice.yaml" -Value $content
kubectl apply -f ".\memberservice.yaml" --namespace $namespace
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy member service app."
}

# Step 10: Deploy Points service.
$content = Get-Content .\Deployment\pointsservice.yaml
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
$content = $content.Replace('$APPINSIGHTSKEY', $appInsightsKey)
$content = $content.Replace('$VERSION', $APP_VERSION)

Set-Content -Path ".\pointsservice.yaml" -Value $content
kubectl apply -f ".\pointsservice.yaml" --namespace $namespace
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy points service app."
}

# Step 7: Deploy Member Portal
$AADINSTANCEB2C = (az keyvault secret show -n contoso-customer-service-b2c-instance --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AADDOMAINB2C = (az keyvault secret show -n contoso-customer-service-b2c-domain --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AADCLIENTIDB2C = (az keyvault secret show -n contoso-customer-service-b2c-client-id --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AADPOLICYIDB2C = (az keyvault secret show -n contoso-customer-service-b2c-policy-id --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AADSIGNOUTCALLBACKPATHB2C = (az keyvault secret show -n contoso-customer-service-b2c-sign-out-callback-path --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_CLIENT_ID = (az keyvault secret show -n contoso-customer-service-aad-memberportal-client-id --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_CLIENT_SECRET = (az keyvault secret show -n contoso-customer-service-aad-memberportal-client-secret --vault-name $KeyVaultName --query value | ConvertFrom-Json)

$content = Get-Content .\Deployment\memberportal.yaml
$content = $content.Replace('$ACRNAME', $acrName)
$content = $content.Replace('$NAMESPACE', $namespace)
$content = $content.Replace('$AADINSTANCEB2C', $AADINSTANCEB2C)
$content = $content.Replace('$AADDOMAINB2C', $AADDOMAINB2C)
$content = $content.Replace('$AADCLIENTIDB2C', $AADCLIENTIDB2C)
$content = $content.Replace('$AADPOLICYIDB2C', $AADPOLICYIDB2C)
$content = $content.Replace('$AADSIGNOUTCALLBACKPATHB2C', $AADSIGNOUTCALLBACKPATHB2C)
$content = $content.Replace('$AADINSTANCE', $AAD_INSTANCE)
$content = $content.Replace('$AADTENANTID', $AAD_TENANT_ID)
$content = $content.Replace('$AADDOMAIN', $AAD_DOMAIN)
$content = $content.Replace('$AADCLIENTID', $AAD_CLIENT_ID)
$content = $content.Replace('$AADCLIENTSECRET', $AAD_CLIENT_SECRET)
$content = $content.Replace('$AADSCOPES', $AAD_SCOPES)
$content = $content.Replace('$APPINSIGHTSKEY', $appInsightsKey)
$content = $content.Replace('$VERSION', $APP_VERSION)

Set-Content -Path ".\memberportal.yaml" -Value $content
kubectl apply -f ".\memberportal.yaml" --namespace $namespace
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy customer service app."
}

# Step 11: Function scaling based on specific scalers
if ($QueueType -eq "ServiceBus") { 
    $content = Get-Content .\Deployment\backendservicebus.yaml
    $content = $content.Replace('$QUEUENAME', $QueueName)
    $content = $content.Replace('$BASE64CONNECTIONSTRING', $ListenerQueueConnectionString)
    $content = $content.Replace('$APPINSIGHTSKEY', $appInsightsKey)
    Set-Content -Path ".\backendservicebus.yaml" -Value $content
    kubectl apply -f ".\backendservicebus.yaml" --namespace $namespace
    if ($LastExitCode -ne 0) {
        throw "An error has occured. Unable to deploy service bus keda scaler."
    }
}

if ($QueueType -eq "Storage") {
    $content = Get-Content .\Deployment\backendstorage.yaml
    $content = $content.Replace('$QUEUENAME', $QueueName)
    $content = $content.Replace('$BASE64CONNECTIONSTRING', $SenderQueueConnectionString)
    $content = $content.Replace('$STORAGEACCOUNTNAME', $BackendStorageName)
    $content = $content.Replace('$APPINSIGHTSKEY', $appInsightsKey)
    Set-Content -Path ".\backendstorage.yaml" -Value $content
    kubectl apply -f ".\backendstorage.yaml" --namespace $namespace
    if ($LastExitCode -ne 0) {
        throw "An error has occured. Unable to deploy storage keda scaler."
    }
}

# Setup ingress now that all services are deployed.
if ($EnableApplicationGateway -eq "true") {
    Write-Host "Using application gateway ingress controller yaml."
    $content = Get-Content .\Deployment\external-ingress-agw.yaml
}
else {
    Write-Host "Using ingress controller yaml."
    $content = Get-Content .\Deployment\external-ingress.yaml
}

$content = $content.Replace('$NAMESPACE', $namespace)
$content = $content.Replace('$CUSTOMER_SERVICE_DOMAIN', $customerServiceDomain)
$content = $content.Replace('$API_DOMAIN', $apiDomain)
$content = $content.Replace('$MEMBER_PORTAL_DOMAIN', $memberPortalDomain)

# Note: Interestingly, we need to set namespace in the yaml file although we have setup the namespace here in apply.
$content = $content.Replace('$NAMESPACE', $namespace)
Set-Content -Path ".\ingress.yaml" -Value $content
$rawOut = (kubectl apply -f .\ingress.yaml --namespace $namespace 2>&1)
if ($LastExitCode -ne 0) {
    $errorMsg = $rawOut -Join '`n'
    if ($errorMsg.Contains("failed calling webhook") -and $errorMsg.Contains("validate.nginx.ingress.kubernetes.io")) {
        Write-Host "Attempting to recover from 'failed calling webhook' error."

        # See: https://pet2cattle.com/2021/02/service-ingress-nginx-controller-admission-not-found
        kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission
        kubectl apply -f .\ingress.yaml --namespace $namespace
        if ($LastExitCode -ne 0) {
            throw "An error has occured. Unable to deploy external ingress."
        }
    }
    else {
        throw "An error has occured. Unable to deploy external ingress. $errorMsg "
    }    
}
else {
    Write-Host "Applied ingress config."    
}

if ($EnableApplicationGateway -ne "true") {
    # Step 12: Output ip address
    $serviceip = kubectl get svc ingress-nginx-controller -n $namespace -o jsonpath='{.status.loadBalancer.ingress[*].ip}'
    Write-Host "::set-output name=serviceip::$serviceip"
}