# Disclaimer
The information contained in this README.md file and any accompanying materials (including, but not limited to, scripts, sample codes, etc.) are provided "AS-IS" and "WITH ALL FAULTS." Any estimated pricing information is provided solely for demonstration purposes and does not represent final pricing and Microsoft assumes no liability arising from your use of the information. Microsoft makes NO GUARANTEES OR WARRANTIES OF ANY KIND, WHETHER EXPRESSED OR IMPLIED, in providing this information, including any pricing information.

# Introduction
This project implements the Contoso Customer Service Rewards Lookup & Consumption Application with Azure Kubernetes Service (AKS). For more information about this workload, checkout: https://github.com/msft-davidlee/contoso-customer-service-app#readme. 

# Get Started
To create this, you will need to follow build the application. Follow the guidance on https://github.com/msft-davidlee/contoso-customer-service-app. Next, use your Azure subscription and also a AAD instance that you control and follow the steps below.

1. Fork this git repo. See: https://docs.github.com/en/get-started/quickstart/fork-a-repo
2. Create two resource groups to represent two environments. Suffix each resource group name with either a -dev or -prod. An example could be todo-dev and todo-prod.
3. Next, you must create a service principal with Contributor roles assigned to the two resource groups.
4. In your github organization for your project, create two environments, and named them dev and prod respectively.
5. Create the following secrets in your github per environment. Be sure to populate with your desired values. The values below are all suggestions.
6. Note that the environment suffix of dev or prod will be appened to your resource group but you will have the option to define your own resource prefix.
7. Create App Registration include the appropriate Urls. See Secrets below.

## Secrets
| Name | Comments |
| --- | --- |
| MS_AZURE_CREDENTIALS | <pre>{<br/>&nbsp;&nbsp;&nbsp;&nbsp;"clientId": "",<br/>&nbsp;&nbsp;&nbsp;&nbsp;"clientSecret": "", <br/>&nbsp;&nbsp;&nbsp;&nbsp;"subscriptionId": "",<br/>&nbsp;&nbsp;&nbsp;&nbsp;"tenantId": "" <br/>}</pre> |
| PREFIX | mytodos - or whatever name you would like for all your resources |
| RESOURCE_GROUP | todo - or whatever name you give to the resource group |
| AAD_CLIENT_ID | Client Id |
| AAD_CLIENT_SECRET | Client Secret |
| AAD_DOMAIN | replace "something." with the correct domain something.onmicrosoft.com  |
| AAD_TENANT_ID | Tenant Id |
| SQLPASSWORD | SQL password that you want to use |
| NETWORKING_PREFIX | Network stack-name tag with the specific value |

8. Create certificate for your solution using the following ``` openssl req -x509 -nodes -days 365 -newkey rsa:2048 -out demo.contoso.com.crt -keyout demo.contoso.com.key -subj "/CN=demo.contoso.com/O=aks-ingress-tls" ```
9. Next, upload the outputs to a container named certs in your storage account.
10. Login via ``` az login ``` into Azure and then login to AKS with ``` az aks get-credentials -n <AKS_NAME> -g <AKS_GROUP_NAME> ```
11. There's a manual command you need to execute in order for AKS to connect successfully to ACR. ``` az aks update -n <AKS_NAME> -g aks-dev --attach-acr <ACR_NAME> ```
12. To check if everything is setup successfully, run the following command: ``` az aks check-acr -n <AKS_NAME> -g <AKS_GROUP_NAME> --acr <ACR_NAME>.azurecr.io ```
13. To verify the public IP of the ingress controller, run the following command: ``` kubectl get services -n myapps ```
14. Update your local host file to point to the public ip.

# Take Note
1. NSG applied on your AKS Subnet may be impacting access to the site.
2. Remember to add the URL of Frontdoor to your AAD app registration for redirect purposes.

## Have an issue?
You are welcome to create an issue if you need help but please note that there is no timeline to answer or resolve any issues you have with the contents of this project. Use the contents of this project at your own risk! If you are interested to volunteer to maintain this, please feel free to reach out to be added as a contributor and send Pull Requests (PR).