param(
    [Parameter(Mandatory = $true)][string]$BUILD_ENV, 
    [Parameter(Mandatory = $true)][string]$APP_VERSION, 
    [Parameter(Mandatory = $true)][string]$StackNameTag,
    [Parameter(Mandatory = $true)][string]$TEMPDIR)

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
        throw "Unable to find resource $stackName by environment!"
    }
        
    return $res
}
$ErrorActionPreference = "Stop"

$all = GetResource -stackName $StackNameTag -stackEnvironment $BUILD_ENV
$sql = $all | Where-Object { $_.type -eq 'Microsoft.Sql/servers' }
$sqlSv = az sql server show --name $sql.name -g $sql.resourceGroup | ConvertFrom-Json
$SqlServer = $sqlSv.fullyQualifiedDomainName
$SqlUsername = $sqlSv.administratorLogin

$db = $all | Where-Object { $_.type -eq 'Microsoft.Sql/servers/databases' }
$dbNameParts = $db.name.Split('/')
$DbName = $dbNameParts[1]

$kv = GetResource -stackName shared-key-vault -stackEnvironment prod
$kvName = $kv.name

$sqlPassword = (az keyvault secret show -n contoso-customer-service-sql-password --vault-name $kvName --query value | ConvertFrom-Json)
$sqlConnectionString = "Server=$SqlServer;Initial Catalog=$DbName; User Id=$SqlUsername;Password=$sqlPassword"
Write-Host "::set-output name=sqlConnectionString::$sqlConnectionString"

# Deploy specfic version of SQL script
$strs = GetResource -stackName shared-storage -stackEnvironment prod
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