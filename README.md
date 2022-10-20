# Contoso Customer Service Azure Kubernetes Service

This project implements the [Contoso Customer Service Rewards Lookup & Consumption Application](https://github.com/msft-davidlee/contoso-customer-service-app#readme) as a PaaS service using Azure Kubernetes Service (AKS).

## Disclaimer

The information contained in this README.md file and any accompanying materials (including, but not limited to, scripts, sample codes, etc.) are provided "AS-IS" and "WITH ALL FAULTS." Any estimated pricing information is provided solely for demonstration purposes and does not represent final pricing and Microsoft assumes no liability arising from your use of the information. Microsoft makes NO GUARANTEES OR WARRANTIES OF ANY KIND, WHETHER EXPRESSED OR IMPLIED, in providing this information, including any pricing information.

## Get Started

Please register the following resource providers in your subscription if you have not done so. An example: ``` az provider register --namespace Microsoft.OperationsManagement ```.

* Microsoft.Compute
* microsoft.containerservice
* microsoft.operationalinsights
* Microsoft.OperationsManagement

Follow the steps below to create this demo.

1. [Fork](https://docs.github.com/en/get-started/quickstart/fork-a-repo) this git repo.
2. Follow the [governance](https://github.com/msft-davidlee/contoso-governance) which will allow you to create a service principal and have the correct role assignment to the aks specified resource groups.
3. Follow the [networking](https://github.com/msft-davidlee/contoso-networking) steps to create the networks.
4. Follow the [application](https://github.com/msft-davidlee/contoso-customer-service-app) steps to create application artifacts.
5. Register a domain name.
6. Create sub-domain names for customer service app (ex: contoso-customer-service), api (ex: contoso-api) and member portal (ex: contoso-member).
7. Create a SSL certifcate for your sub-domain name. There is a free option using [Let’s Encrypt](https://letsencrypt.org/).
8. upload the outputs to a container named certs in your storage account.
9. Run the following to setup your deployment configurations. ``` .\ResetAppConfigs.ps1 -CustomerServiceDomainName contoso-customer-service.<your domain name>.com -ApiDomainName contoso-api.<your domain name>.com -MemberPortalDomainName contoso-member.<your domain name>.com ```
10. Ensure your AAD App Registration is configured with this sub-domain name. Be sure to append /signin-odic as part of the path.
11. Before running the GitHub workflow, you should review the options below.
12. Execute the GitHub action workflow. You will notice an error in the "Deploy Apps" step that will require you to run the CompleteSetup.ps1 script manually. Be sure to pass in BUILD_ENV parameter which can be either dev or prod.
13. Once this is completed, you can now choose to run ONLY the steps that failed i.e. "Deploy Apps" step to save time. It should be successful this time.
14. To teardown your solution, run ``` .\RemoveSolution.ps1 -ArdSolutionId app-service-demo -ArdEnvironment <either dev or prod> ```

## Why do we need to run CompleteSetup.ps1 script?

We need to associate access between AKS and ACR and that requires a higher level of privilege than a Contributor role. We are using a Service Principal to run GitHub Action which means we now have to assign a role assignment permission to this GitHub Service Principal which is not a good practice. I prefer this step to be manually executed by a real person, i.e. DevOps engineer for any form of role assignments. This is because this is really a one-time only assignment in most cases and if we deploy new code, this is not necessary anymore.

In addition, if we are adding an Application Gateway Ingress Controller, there are additional role assignments we need to do, which again, we should have a real DevOps engineer perform instead of giving a SP more permissions.

## Deploying with Default Nginx Ingress Controller

If you did not enable Frontdoor or Application Gateway, the deployment would default to use Nginx Ingress Controller.

### Deploying with Default Nginx Ingress Controller Issue(s)

1. There is an issue with the Ngix Ingress Controller where the Kubernetes Load Balancer's health check probes would NOT be configured correctly. The path is configured as just / but really needs to be /healthz. You would need to fix this manually.

![AKS Load Balancer Issue](/Docs/LoadBalancerIssue.png)

## Deploying Frontdoor

1. Enable Azure Front Door deployment option in your shared Azure App Configuration created as part of the [governance](https://github.com/msft-davidlee/contoso-governance) setup step. Use key ``` aks-demo/deployment-flags/enable-frontdoor ``` with 2 labels dev or prod and value of true to create or false to disable.

## Deploying Application Gateway

1. Enable Azure Application Gateway deployment option in your shared Azure App Configuration created as part of the [governance](https://github.com/msft-davidlee/contoso-governance) setup step. Use key ``` aks-demo/deployment-flags/enable-app-gateway ``` with 2 labels dev or prod and value of true to create or false to disable.

### Deploying Application Gateway Issue(s)

1. There is an issue with the Application Gateway Ingress Controller setup which is using the Add-On approach. The routes are not configured correctly for some reason and you will get a 502 error when you try to browse to the site. We will need to execute the FixApplicationGatewayRoute.ps1 script to fix the issue.

## Performance Testing

For running a performance test, you can craft a payload against the Order endpoint ``` https://<api sub domain name>/partner/order ``` with the following body using the HTTP POST verb. I suggest using postman.

```json
{
    "productId": "FFF01",
    "memberId": "8549494944"
}
```

1. Run the following command to get the pods that are running: ``` kubectl get pods -n myapps ```
2. To watch for running pods, run the following command ``` kubectl get pods -o=name --field-selector=status.phase=Running -n myapps --watch ```
3. To observe the HPA in action, run ``` kubectl describe hpa -n myapps ``` For a simple version, run ``` kubectl get hpa -n myapps ```
4. You can also review the insights view of your AKS cluster as well as Storage insights for how the "db" is handling your load.
5. When you navigate to customer service app sub-domain name, you will be able to redirect to Prometheus to view the requests. Try the following command to see the load: ``` nginx_ingress_controller_requests ```
6. Next try the following to look at request per service such as customer service. ``` sum(rate(nginx_ingress_controller_requests{service='customerservice'}[1m])) ```

## Troubleshooting

1. NSG applied on your AKS Subnet may be impacting access to the site. Be sure to open both ports 80 and 443.
2. You may have notice the following configuration in external-ingress.yaml. This is related to the authentication redirect back from AAD to Ngix and it does not by default handle a large header content. For more information, see [this](https://stackoverflow.com/questions/48964429/net-core-behind-nginx-returns-502-bad-gateway-after-authentication-by-identitys).

   ```yaml
   nginx.ingress.kubernetes.io/proxy-buffering: "on"
   nginx.ingress.kubernetes.io/proxy-buffer-size: "128k"
   nginx.ingress.kubernetes.io/proxy-buffers-number: "4" 
   ```

3. You may have notice the following configuration applied on the container environment of Customer Service, ASPNETCORE_FORWARDEDHEADERS_ENABLED. This is related to ensuring that the https protocol can be applied by ASP.NET core authentication middleware. By default, without this, the uri_redirect will be http instead of https because the container is listening on port 80 and it means it will not work properly. To fix this, we apply the ASPNETCORE_FORWARDEDHEADERS_ENABLED configuration. For more information, see [this](https://docs.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer?view=aspnetcore-6.0#forward-the-scheme-for-linux-and-non-iis-reverse-proxies).
4. If you are encountering an error similar to the following: nginx ingress controller - failed calling webhook, try running the following command.

```bash
kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission
```

More information on the issue can be found [here](https://pet2cattle.com/2021/02/service-ingress-nginx-controller-admission-not-found).

## Have an issue?

You are welcome to create an issue if you need help but please note that there is no timeline to answer or resolve any issues you have with the contents of this project. Use the contents of this project at your own risk! If you are interested to volunteer to maintain this, please feel free to reach out to be added as a contributor and send Pull Requests (PR).
