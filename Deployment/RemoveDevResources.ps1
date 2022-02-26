$stackRes = (az resource list --tag stack-name=contoso-customer-service-aks | ConvertFrom-Json)
$devRes = $stackRes | Where-Object { $_.tags.'stack-environment' -eq 'dev' }
az resource delete --id $devRes.id