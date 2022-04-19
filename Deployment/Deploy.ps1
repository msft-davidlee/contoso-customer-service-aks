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

$sql = $all | Where-Object { $_.type -eq 'Microsoft.Sql/servers' }
$sqlSv = az sql server show --name $sql.name -g $sql.resourceGroup | ConvertFrom-Json
$SqlServer = $sqlSv.fullyQualifiedDomainName
$SqlUsername = $sqlSv.administratorLogin

$db = $all | Where-Object { $_.type -eq 'Microsoft.Sql/servers/databases' }
$dbNameParts = $db.name.Split('/')
$DbName = $dbNameParts[1]

$kv = GetResource -stackName shared-key-vault -stackEnvironment prod
$KeyVaultName = $kv.name

$AAD_INSTANCE = (az keyvault secret show -n contoso-customer-service-aad-instance --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_DOMAIN = (az keyvault secret show -n contoso-customer-service-aad-domain --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_TENANT_ID = (az keyvault secret show -n contoso-customer-service-aad-tenant-id --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_CLIENT_ID = (az keyvault secret show -n contoso-customer-service-aad-client-id --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_CLIENT_SECRET = (az keyvault secret show -n contoso-customer-service-aad-client-secret --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_AUDIENCE = (az keyvault secret show -n contoso-customer-service-aad-app-audience --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$AAD_SCOPES = (az keyvault secret show -n contoso-customer-service-aad-scope --vault-name $KeyVaultName --query value | ConvertFrom-Json)
$acr = GetResource -stackName shared-container-registry -stackEnvironment prod
$acrName = $acr.Name

$log = $all | Where-Object { $_.type -eq 'microsoft.insights/components' }
az extension add --name application-insights
$appInsightsKey = az monitor app-insights component show --app $log.name -g $log.resourceGroup --query "instrumentationKey" -o tsv
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable get app insights instrumentation key."
}

$config = GetResource -stackName shared-configuration -stackEnvironment prod
$configName = $config.name

$certDomainNamesJson = (az appconfig kv show -n $configName --key "$STACK_NAME_TAG/cert-domain-names" --auth-mode login | ConvertFrom-Json).value
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to get cert domain names from $configName."
}

$certDomainNames = $certDomainNamesJson | ConvertFrom-Json

$customerServiceDomain = $certDomainNames.ingress.customerservice
$apiDomain = $certDomainNames.ingress.api
$memberPortalDomain = $certDomainNames.ingress.memberPortal

if (!$customerServiceDomain) {
    throw "Unable to get Customer Service Domain"
}

if (!$apiDomain) {
    throw "Unable to get API Domain"
}

if (!$memberPortalDomain) {
    throw "Unable to get Member Portal Domain"
}

# Step 2: Login to AKS.
az aks get-credentials --resource-group $AKS_RESOURCE_GROUP --name $AKS_NAME
Write-Host "::set-output name=aksName::$AKS_NAME"
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

if ($EnableApplicationGateway -eq "true") {
    $foundHelmAppGwRepo = ($repoList | Where-Object { $_.name -eq "application-gateway-kubernetes-ingress" }).Count -eq 1

    if (!$foundHelmAppGwRepo) {        
        helm repo add application-gateway-kubernetes-ingress https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/
    }
    else {
        Write-Host "Skip adding application-gateway-kubernetes-ingress with helm as it already exist."
    }    
}
else {
    $foundHelmIngressRepo = ($repoList | Where-Object { $_.name -eq "ingress-nginx" }).Count -eq 1

    # Step 4a: Add the ingress-nginx repository
    if (!$foundHelmIngressRepo ) {
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx   
    }
    else {
        Write-Host "Skip adding ingress-nginx repo with helm as it already exist."
    }
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
$testSecret = (kubectl get secret aks-csv-tls -o json -n $namespace)
if (!$testSecret) {

    $strs = GetResource -stackName shared-storage -stackEnvironment prod
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

# Step 4c. Install ingress controller
# See: https://github.com/kubernetes/ingress-nginx/blob/main/docs/user-guide/monitoring.md

if ($EnableApplicationGateway -eq "true") {

    # https://docs.microsoft.com/en-us/azure/application-gateway/ingress-controller-install-new#install-aad-pod-identity
    # Install AAD Pod Identity to your cluster
    kubectl create -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment.yaml
    
    Write-Host "Configure ingress for app gateway."

    $identity = az identity list -g $AKS_RESOURCE_GROUP | ConvertFrom-Json
    $mid = $identity.id    
    $midClientId = $identity.clientId

    $subscriptionId = (az account show | ConvertFrom-Json).id

    $content = Get-Content .\Deployment\helm-config.yaml
    $content = $content.Replace('$SubscriptionId', $subscriptionId)
    $content = $content.Replace('$ResourceGroupName', $AKS_RESOURCE_GROUP)
    $content = $content.Replace('$ApplicationGatewayName', $AKS_NAME)
    $content = $content.Replace('$NAMESPACE', $namespace)
    $content = $content.Replace('$IdentityResourceId', $mid)
    $content = $content.Replace('$IdentityClientId', $midClientId)
    Set-Content -Path ".\helm-config.yaml" -Value $content

    helm install -f helm-config.yaml ingress-azure application-gateway-kubernetes-ingress/ingress-azure

    # helm install ingress-nginx ingress-nginx/ingress-nginx --namespace $namespace `
    #     --set controller.replicaCount=2 `
    #     --set controller.metrics.enabled=true `
    #     --set-string controller.podAnnotations."prometheus\.io/scrape"="true" `
    #     --set-string controller.podAnnotations."prometheus\.io/port"="10254"
}
else {
    # Public IP is assigned only for Prod which we will reuse.
    $pipRes = GetResource -stackName 'aks-public-ip' -stackEnvironment prod
    $pip = (az network public-ip show --ids $pipRes.id | ConvertFrom-Json)
    $ip = $pip.ipAddress    
    $ipFqdn = "contosocoffeehouseapps"
    $ipResGroup = $pipRes.resourceGroup

    Write-Host "Configure ingress with static IP: $ip $ipFqdn $ipResGroup"

    helm install ingress-nginx ingress-nginx/ingress-nginx --namespace $namespace `
        --set controller.replicaCount=2 `
        --set controller.service.loadBalancerIP=$ip `
        --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"=$ipFqdn `
        --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-resource-group"=$ipResGroup `
        --set controller.nodeSelector."kubernetes\.io/os"=linux `
        --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux `
        --set controller.metrics.enabled=true `
        --set-string controller.podAnnotations."prometheus\.io/scrape"="true" `
        --set-string controller.podAnnotations."prometheus\.io/port"="10254"
}

helm install keda kedacore/keda -n $namespace

# if ($EnableFrontdoor) {
#     $content = Get-Content .\Deployment\external-ingress-with-fd.yaml
# }
# else {

if ($EnableApplicationGateway -eq "true") {
    Write-Host "Using yaml for application gateway ingress controller."
    $content = Get-Content .\Deployment\external-ingress-agw.yaml
}
else {
    $content = Get-Content .\Deployment\external-ingress.yaml
}

$content = $content.Replace('$NAMESPACE', $namespace)
$content = $content.Replace('$CUSTOMER_SERVICE_DOMAIN', $customerServiceDomain)
$content = $content.Replace('$API_DOMAIN', $apiDomain)
$content = $content.Replace('$MEMBER_PORTAL_DOMAIN', $memberPortalDomain)
#}

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
        throw "An error has occured. Unable to deploy external ingress. $errorMsg "
    }    
}else {
    Write-Host "Applied ingress config for ingress controller."
}

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

if ($EnableApplicationGateway -ne "true") {
    # Step 12: Output ip address
    $serviceip = kubectl get svc ingress-nginx-controller -n $namespace -o jsonpath='{.status.loadBalancer.ingress[*].ip}'
    Write-Host "::set-output name=serviceip::$serviceip"
}

if ($EnableApplicationGateway -eq "true") {

    # $appGwId = (az network application-gateway show -n $AKS_NAME -g $AKS_RESOURCE_GROUP -o tsv --query "id")

    $allResources = GetResource -stackName platform -stackEnvironment $BUILD_ENV    
    $vnet = $allResources | Where-Object { $_.type -eq 'Microsoft.Network/virtualNetworks' -and (!$_.name.EndsWith('-nsg')) -and $_.name.Contains('-pri-') }            
    $vnetName = $vnet.name
    $vnetRg = $vnet.resourceGroup
    # $location = $vnet.location

    $subnets = (az network vnet subnet list -g $vnetRg --vnet-name $vnetName | ConvertFrom-Json)
    if (!$subnets) {
        throw "Unable to find eligible Subnets from Virtual Network $vnetName!"
    }
    $subnetId = ($subnets | Where-Object { $_.name -eq "appgw" }).id
    if (!$subnetId) {
        throw "Unable to find appgw Subnet resource!"
    }

    # if (!$appGwId) {

    #     # Public IP is assigned only for Prod which we will reuse.
    #     $pipRes = GetResource -stackName 'aks-public-ip' -stackEnvironment prod
    
    #     az network application-gateway create -n $AKS_NAME -l $Location -g $AKS_RESOURCE_GROUP --sku Standard_v2 `
    #         --public-ip-address $pipRes.id `
    #         --vnet-name $vnet.id `
    #         --subnet $subnetId

    #     if ($LastExitCode -ne 0) {
    #         throw "An error has occured. Unable to create Application gateway."
    #     }

    #     $appGwId = (az network application-gateway show -n $AKS_NAME -g $AKS_RESOURCE_GROUP -o tsv --query "id")
    #     if ($LastExitCode -ne 0) {
    #         throw "An error has occured. Unable to create Application gateway Id."
    #     }
    # }

    # $nodeResourceGroup = az aks show -n $AKS_NAME -g $AKS_RESOURCE_GROUP -o tsv --query "nodeResourceGroup"
    # $routeTableId = az network route-table list -g $nodeResourceGroup --query "[].id | [0]" -o tsv

    # https://azure.github.io/application-gateway-kubernetes-ingress/how-tos/networking/
    # az network vnet subnet update --ids $subnetId --route-table $routeTableId
    # if ($LastExitCode -ne 0) {
    #     throw "An error has occured. Unable to associate route table onto app gw subnet."
    # }

    # az extension add --name aks-preview

    # $isInstalled = az aks addon show --addon ingress-appgw -n $AKS_NAME -g $AKS_RESOURCE_GROUP

    # if (!$isInstalled) {
    #     az aks enable-addons -n $AKS_NAME -g $AKS_RESOURCE_GROUP -a ingress-appgw --appgw-id $appGwId
    #     if ($LastExitCode -ne 0) {
    #         throw "An error has occured. Unable to enable Application gateway add-on."
    #     }
    # }
}