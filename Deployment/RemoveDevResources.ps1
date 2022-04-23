param(
    [Parameter(Mandatory = $true)][string]$StackNameTag)

$BUILD_ENV = "dev"
$groups = az group list --tag stack-environment=$BUILD_ENV | ConvertFrom-Json
$resourceGroupName = ($groups | Where-Object { $_.tags.'stack-name' -eq 'aks' -and $_.tags.'stack-environment' -eq $BUILD_ENV }).name

$count = 0
$stackRes = (az resource list --tag stack-name=$StackNameTag | ConvertFrom-Json)
$devRes = $stackRes | Where-Object { $_.tags.'stack-environment' -eq 'dev' }
if ($devRes -and $devRes.Length -gt 0) {
    $devRes | ForEach-Object {
        if ($_.resourceGroup -eq $resourceGroupName) {
            $id = $_.id
            Write-Host "Removing $id"
            az resource delete --id $_.id
            $count += 1
        }    
    }
}

Write-Host "Number of resource deleted: $count"