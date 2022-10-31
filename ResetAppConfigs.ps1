param(
    [Parameter(Mandatory = $true)][string]$DeploymentPrefix,
    [Switch]$EnableApplicationGateway,
    [Switch]$EnableIngress,
    [Switch]$EnableFrontdoor)

$ErrorActionPreference = "Stop"

$ArdSolutionId = "aks-demo"

if ($EnableApplicationGateway -and $EnableFrontdoor) {
    throw "Only one can be enabled!"
}

if ($EnableIngress) {
    $EnableFrontdoorValue = "false"
    $EnableApplicationGatewayValue = "false"
}
else {
    if ($EnableApplicationGateway) {
        $EnableFrontdoorValue = "false"
        $EnableApplicationGatewayValue = "true"
    }
 
    if ($EnableFrontdoor) {
        $EnableFrontdoorValue = "true"
        $EnableApplicationGatewayValue = "false"
    }
}

$strs = (az resource list --tag ard-resource-id=shared-storage | ConvertFrom-Json)
if (!$strs) {
    throw "Unable to find eligible platform storage account!"
}
$BuildAccountName = $strs.name

$temp = $env:TEMP
$tempDir = "$temp\" + (New-Guid).ToString()
New-Item -Path $tempDir -Force -ItemType Directory

Write-Host "Temp directory: $tempDir"

az storage blob download-batch -d $tempDir -s certs --account-name $BuildAccountName
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to download from certs folder."
}

if ($EnableIngress -or $EnableApplicationGateway) {
    $certFile = "cert.cer"
}

if ($EnableFrontdoor) {
    $certFile = "fdcert.cer"
}

$CRT = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
$CRT.Import("$tempDir\$certFile")

$CustomerServiceDomainName = "customer-service.contoso.com"
$ApiDomainName = "api.contoso.com"
$MemberPortalDomainName = "member.contoso.com"

$CRT.DnsNameList | ForEach-Object {
    $dns = $_.Punycode

    if ($dns.Contains("-api")) {
        $ApiDomainName = $dns
        Write-Host "API = $dns"
    }

    if ($dns.Contains("-customer-service")) {
        $CustomerServiceDomainName = $dns
        Write-Host "Customer Service = $dns"
    }

    if ($dns.Contains("-member")) {
        $MemberPortalDomainName = $dns
        Write-Host "Member Portal = $dns"
    }
}

Remove-Item -Path $tempDir -Force -Recurse


$config = (az resource list --tag ard-resource-id=shared-app-configuration | ConvertFrom-Json)
if (!$config) {
    throw "Unable to find App Config resource!"
}
$configName = $config.name

az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-prefix" --label dev --auth-mode login --value $DeploymentPrefix --yes
az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-prefix" --label prod --auth-mode login --value $DeploymentPrefix --yes

az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-flags/enable-frontdoor" --label dev --auth-mode login --value $EnableFrontdoorValue --yes
az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-flags/enable-frontdoor" --label prod --auth-mode login --value $EnableFrontdoorValue --yes

az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-flags/enable-app-gateway" --label dev --auth-mode login --value $EnableApplicationGatewayValue --yes
az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-flags/enable-app-gateway" --label prod --auth-mode login --value $EnableApplicationGatewayValue --yes

az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-flags/queue-type" --label dev --auth-mode login --value Storage --yes
az appconfig kv set -n $configName --key "$ArdSolutionId/deployment-flags/queue-type" --label prod --auth-mode login --value Storage --yes

if ($EnableFrontdoor) {
    az appconfig kv set -n $configName --key "$ArdSolutionId/cert-domain-names/frontdoor/customer-service" --auth-mode login --value $CustomerServiceDomainName --yes    
    az appconfig kv set -n $configName --key "$ArdSolutionId/cert-domain-names/frontdoor/api" --auth-mode login --value $ApiDomainName --yes    
    az appconfig kv set -n $configName --key "$ArdSolutionId/cert-domain-names/frontdoor/member-portal" --auth-mode login --value $MemberPortalDomainName --yes
}

if ($EnableApplicationGateway -or $EnableIngress) {
    az appconfig kv set -n $configName --key "$ArdSolutionId/cert-domain-names/ingress/customer-service" --auth-mode login --value $CustomerServiceDomainName --yes    
    az appconfig kv set -n $configName --key "$ArdSolutionId/cert-domain-names/ingress/api" --auth-mode login --value $ApiDomainName --yes    
    az appconfig kv set -n $configName --key "$ArdSolutionId/cert-domain-names/ingress/member-portal" --auth-mode login --value $MemberPortalDomainName --yes
}
