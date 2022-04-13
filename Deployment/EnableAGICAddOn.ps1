param(
    [Parameter(Mandatory = $true)][string]$AKSName,
    [Parameter(Mandatory = $true)][string]$AKResourceGroupSName,
    [Parameter(Mandatory = $true)][string]$ApplicationGatewayResourceId)

az aks enable-addons -n $AKSName -g $AKResourceGroupSName -a ingress-appgw --appgw-id $ApplicationGatewayResourceId
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to enable add-ons for $AKSName and $ApplicationGatewayResourceId."
}