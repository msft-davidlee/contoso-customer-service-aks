param([Parameter(Mandatory = $true)][string]$StackNameTag)
$stackRes = (az resource list --tag stack-name=$StackNameTag | ConvertFrom-Json)
$devRes = $stackRes | Where-Object { $_.tags.'stack-environment' -eq 'dev' }
if ($devRes -and $devRes.Length -gt 0) {
    az resource delete --id $devRes.id
}