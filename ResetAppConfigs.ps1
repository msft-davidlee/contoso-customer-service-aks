param(
    [Parameter(Mandatory = $true)][string]$CustomerServiceDomainName, 
    [Parameter(Mandatory = $true)][string]$ApiDomainName, 
    [Parameter(Mandatory = $true)][string]$MemberPortalDomainName,
    [Parameter(Mandatory = $true)][string]$DeploymentPrefix)

$ArdSolutionId = "aks-demo"
$config = (az resource list --tag ard-resource-id=shared-app-configuration | ConvertFrom-Json)
if (!$config) {
    throw "Unable to find App Config resource!"
}
$configName = $config.name

az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-prefix" --label dev --auth-mode login --value $DeploymentPrefix --yes
az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-prefix" --label prod --auth-mode login --value $DeploymentPrefix --yes

az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-flags/enable-frontdoor" --label dev --auth-mode login --value false --yes
az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-flags/enable-frontdoor" --label prod --auth-mode login --value false --yes

az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-flags/enable-app-gateway" --label dev --auth-mode login --value false --yes
az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-flags/enable-app-gateway" --label prod --auth-mode login --value false --yes

az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-flags/queue-type" --label dev --auth-mode login --value Storage --yes
az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-flags/queue-type" --label prod --auth-mode login --value Storage --yes

az appconfig kv set -n $configName --key "$ArdSolutionId/cert-domain-names/app-gateway/customer-service" --auth-mode login --value $CustomerServiceDomainName --yes
az appconfig kv set -n $configName --key "$ArdSolutionId/cert-domain-names/app-gateway/api" --auth-mode login --value $ApiDomainName --yes
az appconfig kv set -n $configName --key "$ArdSolutionId/cert-domain-names/app-gateway/member-portal" --auth-mode login --value $MemberPortalDomainName --yes

az appconfig kv set -n $configName --key "$ArdSolutionId/cert-domain-names/ingress/customer-service" --auth-mode login --value $CustomerServiceDomainName --yes
az appconfig kv set -n $configName --key "$ArdSolutionId/cert-domain-names/ingress/api" --auth-mode login --value $ApiDomainName --yes
az appconfig kv set -n $configName --key "$ArdSolutionId/cert-domain-names/ingress/member-portal" --auth-mode login --value $MemberPortalDomainName --yes