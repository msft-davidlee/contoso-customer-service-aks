param(
    [string]$CustomerService, 
    [string]$AlternateId, 
    [string]$PartnerApi,
    [string]$Backend, 
    [string]$ResourceGroup, 
    [string]$BuildAccountName,
    [string]$AppCode,
    [string]$DbName,
    [string]$SqlServer,
    [string]$SqlUsername,
    [string]$SqlPassword)

$ErrorActionPreference = "Stop"

#Invoke-Sqlcmd -InputFile "$AppCode\Db\Migrations.sql" -ServerInstance $SqlServer -Database $DbName -Username $SqlUsername -Password $SqlPassword