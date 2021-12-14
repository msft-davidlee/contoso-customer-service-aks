param(
    [string]$AKS_RESOURCE_GROUP,
    [string]$AKS_NAME,
    [string]$NETWORKING_PREFIX,
    [string]$BUILD_ENV,
    [string]$AppCode,
    [string]$DbName,
    [string]$SqlServer,
    [string]$SqlUsername,
    [string]$SqlPassword)

$ErrorActionPreference = "Stop"
# Prerequsites: 
# * We have already assigned the managed identity with a role in Container Registry with AcrPull role.

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

# Add the ingress-nginx repository
if (!$foundHelmIngressRepo ) {
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
}
else {
    Write-Host "Skip adding ingress-nginx repo with helm as it already exist."
}

helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx --create-namespace --namespace $namespace
kubectl apply -f .\Deployment\external-ingress.yaml --namespace $namespace

# Step 5: Setup configuration for resources
$dbConnectionString = "Server=tcp:$SqlServer.database.windows.net,1433;Initial Catalog=appdb;Persist Security Info=False;User ID=$SqlUsername;Password=$SqlPassword;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
# See: https://kubernetes.io/docs/concepts/configuration/secret/#use-case-dotfiles-in-a-secret-volume
$base64DbConnectionString = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($dbConnectionString))

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

# Step 6: Deploy customer service app.
$content = Get-Content .\Deployment\customerservice.yaml
$content = $content.Replace('$BASE64CONNECTIONSTRING', $base64DbConnectionString)
$content = $content.Replace('$ACRNAME', $acrName)
$content = $content.Replace('$NAMESPACE', $namespace)

Set-Content -Path ".\customerservice.yaml" -Value $content
kubectl apply -f ".\customerservice.yaml" --namespace $namespace