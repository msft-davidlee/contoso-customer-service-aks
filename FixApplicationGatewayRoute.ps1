# The routing rules configured in Application Gateway are incorrect. This is a temp workaround to
# address this issue for a working demo.

param([Parameter(Mandatory = $true)][string]$ArdEnvironment)

$ArdSolutionId = "aks-demo"

$groups = az group list --tag ard-environment=$ArdEnvironment | ConvertFrom-Json
$resourceGroupName = ($groups | Where-Object { $_.tags.'ard-solution-id' -eq $ArdSolutionId -and !$_.tags.'aks-managed-cluster-rg' }).name

$appGw = (az resource list -g $resourceGroupName --resource-type "Microsoft.Network/applicationGateways" | ConvertFrom-Json)[0]
if ($appGw) {

    $rules = (az network application-gateway rule list --gateway-name $appGw.name -g $resourceGroupName) | ConvertFrom-Json
    $rules | ForEach-Object {                
        $pathRule = az network application-gateway url-path-map show --ids $_.urlPathMap.id | ConvertFrom-Json
        if (!$_.backendAddressPool) {      
            
            az network application-gateway url-path-map update --ids $pathRule.id `
                --default-address-pool $pathRule.pathRules.backendAddressPool.id `
                --default-http-settings $pathRule.pathRules.backendHttpSettings.id
        } else {
            Write-Host "No updates."
        }
    }
}