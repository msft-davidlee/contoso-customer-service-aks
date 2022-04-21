param(
    [Parameter(Mandatory = $true)][string]$StackNameTag, 
    [Parameter(Mandatory = $true)][string]$BUILD_ENV)

$groups = az group list --tag stack-environment=$BUILD_ENV | ConvertFrom-Json
$resourceGroupName = ($groups | Where-Object { $_.tags.'stack-name' -eq 'aks' -and $_.tags.'stack-environment' -eq $BUILD_ENV }).name

$stackRes = (az resource list --tag stack-name=$StackNameTag | ConvertFrom-Json)
$devRes = $stackRes | Where-Object { $_.tags.'stack-environment' -eq 'dev' }
if ($devRes -and $devRes.Length -gt 0) {
    if ($devRes.resourceGroup -eq $resourceGroupName) {
        az resource delete --id $devRes.id
    }    
}