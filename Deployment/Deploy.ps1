param(
    [string]$AKS_RESOURCE_GROUP,
    [string]$AKS_NAME,
    [string]$NETWORKING_PREFIX,
    [string]$AppCode,
    [string]$DbName,
    [string]$SqlServer,
    [string]$SqlUsername,
    [string]$SqlPassword)

$ErrorActionPreference = "Stop"

Write-Host "Stack-name tag value: $NETWORKING_PREFIX"

$platformRes = (az resource list --tag stack-name=$NETWORKING_PREFIX | ConvertFrom-Json)
if (!$platformRes) {
    throw "Unable to find eligible platform resources!"
}
if ($platformRes.Length -eq 0) {
    throw "Unable to find 'ANY' eligible platform resources!"
}

$acr = ($platformRes | Where-Object { $_.type -eq "Microsoft.ContainerRegistry/registries" -and $_.resourceGroup.EndsWith($BUILD_ENV) })
if (!$acr) {
    throw "Unable to find eligible platform container registry!"
}

$acrName = $acr.Name

Write-Host "ACR name: $acrName"

# Associate ACR with AKS
az aks get-credentials --resource-group $AKS_RESOURCE_GROUP --name $AKS_NAME

az aks update -n $AKS_NAME -g $AKS_RESOURCE_GROUP --attach-acr $acrName

Invoke-Sqlcmd -InputFile "$AppCode\Db\Migrations.sql" -ServerInstance $SqlServer -Database $DbName -Username $SqlUsername -Password $SqlPassword