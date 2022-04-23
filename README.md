# Disclaimer
The information contained in this README.md file and any accompanying materials (including, but not limited to, scripts, sample codes, etc.) are provided "AS-IS" and "WITH ALL FAULTS." Any estimated pricing information is provided solely for demonstration purposes and does not represent final pricing and Microsoft assumes no liability arising from your use of the information. Microsoft makes NO GUARANTEES OR WARRANTIES OF ANY KIND, WHETHER EXPRESSED OR IMPLIED, in providing this information, including any pricing information.

# Introduction
This project implements the Contoso Customer Service Rewards Lookup & Consumption Application with Azure Kubernetes Service (AKS). For more information about this workload, checkout: https://github.com/msft-davidlee/contoso-customer-service-app#readme. 

# Get Started
To create this, you will need to follow the steps below.

1. Fork this git repo. See: https://docs.github.com/en/get-started/quickstart/fork-a-repo
2. Follow the steps in https://github.com/msft-davidlee/contoso-governance to create the necessary resources via Azure Blueprint.
3. Create the following secret(s) in your github per environment. Be sure to populate with your desired values. The values below are all suggestions.
4. Create required certificates for your solution either using openssl or using your owned domain names with Let's Encrypt. Make sure to name the key file cert.key and cert cert.cer.

The following is an example of using openssl to generate a self-signed cert.
``` 
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -out cert.cer -keyout cert.key -subj "/CN=*.contoso.com/O=aks-ingress-tls"
```

You will also need to specify the domain names in App Configuration with the key as contoso-customer-service-aks/cert-domain-names and the value as the following. The contoso.com would be replaced with a real domain name you own.
```
{
	"ingress": {
		"customerservice": "contosocustomerservice.contoso.com", 
		"api": "contosoapi.contoso.com",
		"memberportal": "contosomember.contoso.com"
	},
	"applicationgateway": {
		"customerservice": "contoso-agw-customer-service.contoso.com", 
		"api": "contoso-agw-api.contoso.com",
		"memberportal": "contoso-agw-member.contoso.com"
	}
}
```
5. Next, upload the outputs to a container named certs in your storage account.
6. Execute the GitHub action workflow. You will notice an error in the "Deploy Apps" step that will require you to run the CompleteSetup.ps1 script manually.
7. Next, you will need to launch CloudShell or Azure CLI on your local machine. If you are using CloudShell, you can clone this repo there and CD into this folder. If you are on your local machine, be sure to do ``` az login ``` before executing the script.
8. You will need to run the CompleteSetup.ps1 script manually. Be sure to pass in BUILD_ENV parameter which can be either dev or prod.
9. To check if everything is setup successfully, review the script output for any errors.
10. Once this is completed, you can now choose to run ONLY the steps that failed i.e. "Deploy Apps" step to save time. It should be successful this time.
11. Update your local host file to point to the public ip.

## Why do we need to run CompleteSetup.ps1 script?
We need to associate access between AKS and ACR and that requires a higher level of privilege than a Contributor role. We are using a Service Principal to run GitHub Action which means we now have to assign a role assignment permission to this GitHub Service Principal which is not a good practice. I prefer this step to be manually executed by a real person, i.e. DevOps engineer for any form of role assignments. This is because this is really a one-time only assignment in most cases and if we deploy new code, this is not necessary anymore.

In addition, if we are adding an Application Gateway Ingress Controller, there are additional role assignments we need to do, which again, we should have a real DevOps engineer perform instead of giving a SP more permissions. 

## Secrets
| Name | Comments |
| --- | --- |
| MS_AZURE_CREDENTIALS | <pre>{<br/>&nbsp;&nbsp;&nbsp;&nbsp;"clientId": "",<br/>&nbsp;&nbsp;&nbsp;&nbsp;"clientSecret": "", <br/>&nbsp;&nbsp;&nbsp;&nbsp;"subscriptionId": "",<br/>&nbsp;&nbsp;&nbsp;&nbsp;"tenantId": "" <br/>}</pre> |
| PREFIX | mytodos - or whatever name you would like for all your resources |

## Deploying Frontdoor
If you are deploying Frontdoor. Frontdoor by already has its domain name with SSL cert and that's what we will be using. 

After that, in the App Configuration, you will need to configure the follow to enable Frontdoor.

| Name | Comments |
| --- | --- |
| Key | contoso-customer-service-app-service/deployment-flags/enable-frontdoor |
| Label | dev or prod |
| Value | true or false |

## Deploying Application Gateway
If you are deploying Application Gateway, you should note that we will be using the Application Gateway Ingress Controller (AGIC)in this demo. To enable this configuration, you will need to follow the steps below to enable Application Gateway.

| Name | Comments |
| --- | --- |
| Key | contoso-customer-service-app-service/deployment-flags/enable-app-gateway |
| Label | dev or prod |
| Value | true or false |

# Performance Testing
1. For running a performance test, you can craft a payload against the Order endpoint https://api.contoso.com/partner/order with the following body using the HTTP POST verb. I suggest using postman.
```
{
    "productId": "FFF01",
    "memberId": "8549494944"
}
```
1. Run the following command to get the pods that are running: ``` kubectl get pods -n myapps ```
2. To watch for running pods, run the following command ``` kubectl get pods -o=name --field-selector=status.phase=Running -n myapps --watch ```
3. To observe the HPA in action, run ``` kubectl describe hpa -n myapps ``` For a simple version, run ``` kubectl get hpa -n myapps ```
4. You can also review the insights view of your AKS cluster as well as Storage insights for how the "db" is handling your load.
5. When you navigate to https://demo.contoso.com, you will be able to redirect to Prometheus to view the requests. Try the following command to see the load: ``` nginx_ingress_controller_requests ```
6. Next try the following to look at request per service such as customer service. ``` sum(rate(nginx_ingress_controller_requests{service='customerservice'}[1m])) ```

# Troubleshooting
1. NSG applied on your AKS Subnet may be impacting access to the site. Be sure to open both ports 80 and 443.
3. You may have notice the following configuration in external-ingress.yaml

```
    nginx.ingress.kubernetes.io/proxy-buffering: "on"
    nginx.ingress.kubernetes.io/proxy-buffer-size: "128k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "4" 
```

This is related to the authentication redirect back from AAD to Ngix and it does not by default handle a large header content. For more information, see: https://stackoverflow.com/questions/48964429/net-core-behind-nginx-returns-502-bad-gateway-after-authentication-by-identitys.

4. You may have notice the following configuration applied on the container environment of Customer Service, ASPNETCORE_FORWARDEDHEADERS_ENABLED. This is related to ensuring that the https protocol can be applied by ASP.NET core authentication middleware. By default, without this, the uri_redirect will be http instead of https because the container is listening on port 80 and it means it will not work properly. To fix this, we apply the ASPNETCORE_FORWARDEDHEADERS_ENABLED configuration. For more information, see: https://docs.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer?view=aspnetcore-6.0#forward-the-scheme-for-linux-and-non-iis-reverse-proxies.

5. If you are encountering an error similar to the following: nginx ingress controller - failed calling webhook, try running the following command.

```
kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission
```

More information on the issue can be found here: https://pet2cattle.com/2021/02/service-ingress-nginx-controller-admission-not-found

6. There is an issue with the Application Gateway Ingress Controller setup which is using the Add-On approach. The routes are not configured correctly for some reason and you will get a 502 error when you try to browse to the site. We will need to execute the FixApplicationGatewayRoute.ps1 script to fix the issue.

## Have an issue?
You are welcome to create an issue if you need help but please note that there is no timeline to answer or resolve any issues you have with the contents of this project. Use the contents of this project at your own risk! If you are interested to volunteer to maintain this, please feel free to reach out to be added as a contributor and send Pull Requests (PR).