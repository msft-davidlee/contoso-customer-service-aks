param(
    [Parameter(Mandatory = $true)][string]$ArdEnvironment, 
    [Parameter(Mandatory = $true)][string]$APP_VERSION, 
    [Parameter(Mandatory = $true)][string]$ArdSolutionId,
    [Parameter(Mandatory = $true)][string]$TEMPDIR)

$ErrorActionPreference = "Stop"

$all = az resource list --tag ard-solution-id=$ArdSolutionId
$all = $all | Where-Object { $_.tags.'ard-environment' -eq $ArdEnvironment }
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
$kvName = $kv.name

$sqlPassword = (az keyvault secret show -n contoso-customer-service-sql-password --vault-name $kvName --query value | ConvertFrom-Json)
$sqlConnectionString = "Server=$SqlServer;Initial Catalog=$DbName; User Id=$SqlUsername;Password=$sqlPassword"
Write-Host "::set-output name=sqlConnectionString::$sqlConnectionString"

# Deploy specfic version of SQL script
$strs = (az resource list --tag ard-resource-id=shared-storage | ConvertFrom-Json)
if (!$strs) {
    throw "Unable to find eligible platform storage account!"
}
$BuildAccountName = $strs.name

$sqlFile = "Migrations-$APP_VERSION.sql"
$dacpac = "cch-$APP_VERSION.dacpac"
Write-Host "Downloading $sqlFile"
az storage blob download --file "$TEMPDIR\$sqlFile" --account-name $BuildAccountName --container-name apps --name $sqlFile
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to download sql file."
}
Write-Host "::set-output name=sqlFile::$TEMPDIR\$sqlFile"

#az storage blob download-batch --destination $TEMPDIR -s apps --account-name $BuildAccountName --pattern $dacpac
az storage blob download --file "$TEMPDIR\$dacpac" --account-name $BuildAccountName --container-name apps --name $dacpac
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to download dacpac file."
}
Write-Host "::set-output name=dacpac::$TEMPDIR\$dacpac"