# Setup mtls between Client and AppGw 
The following example show cases how to setup mtls with agic.  

In general the following points 
* Ingress rules reference ssl-profiles to enable mutual tls. this is done using the 'ssl-profile' annotation 
  *  `appgw.ingress.kubernetes.io/appgw-ssl-profile: sasd`
* Ingress deifnition in AKS needs to provide a certificate either via an annotation reference or via tls.secretname section. 
  * ingress front end cert should include full chain
* Adding rewrite rules performed via the the CRD `AzureApplicationGatewayRewrite`

## To deploy. 
To create an unique deployment the `deploy.sh` can be used to setup an all in one deployment.  Modifiy the following variables. Modfiy these. 
```bash
PREFIX='agic'
SUFFIX='6'
```
Execute
```bash 
 . /deploy.sh 
```

### Deploy
To Deploy and appgw with a k8s cluster. use the following ```bash ./deploy script. ```


## setup Steps
The deploy scripts created everything in one script. The follow section outlines the detailed process to setup manually

### Create Root CA, Server cert and client cert 
```bash

    echo "Creating the CA"
    openssl req -x509 -sha256 -newkey rsa:4096 -keyout mTLS/ca.key -out mTLS/ca.crt -days 3650 -nodes -subj "/CN=My Cert Authority"

    # Generate the Server Key, and Certificate and Sign with the CA Certificate
    echo "Creating the Server and Client Certs"
    openssl req -out mTLS/server_dev.csr -newkey rsa:4096 -nodes -keyout mTLS/server_dev.key -config server_dev.cnf
    openssl x509 -req -sha256 -days 3650 -in mTLS/server_dev.csr -CA mTLS/ca.crt -CAkey mTLS/ca.key -set_serial 01 -out mTLS/server_dev.crt

    # Generate the Client Key, and Certificate and Sign with the CA Certificate
    echo "Creating the Client Certs"
    openssl req -out mTLS/client_dev.csr -newkey rsa:4096 -nodes -keyout mTLS/client_dev.key -config client_dev.cnf
    openssl x509 -req -sha256 -days 3650 -in mTLS/client_dev.csr -CA mTLS/ca.crt -CAkey mTLS/ca.key -set_serial 02 -out mTLS/client_dev.crt

    # to verify CSR and show SAN
    echo "Verifying the CSR"
    openssl req -text -in mTLS/server_dev.csr -noout -verify
    openssl req -text -in mTLS/client_dev.csr -noout -verify
```
### Create tls cert for the frontend. 
This cert is set as k8s secret for demo purposes but can also reference a keyvault. The  frontend cert exposes the fully cert chain. 
```bash

    cat server_dev.crt ca.crt >> frontend.cer
    kubectl create secret tls frontend-tls --key="server_dev.key" --cert="frontend.cer"
```

The sercet is referenced by the ingress defintions with spec.tls.secretName 
```yaml
spec:
  ingressClassName: azure-application-gateway
  tls:
    - secretName: frontend-tls
      hosts:
        - dev.aksingress.com

  rules:
  - host: dev.aksingress.com
```

The above ingress definition will automatically associated the tls front cert with the listener 
### Creating the SSL profile 
To enable mutual auth we need to create an ssl profile. This will create a ssl profiles and upload the rootca certification(or cert chain if there is a intermediate cert). Any client certs issued from this chain will be authorized.   The following script requires the following parameter.
```bash

APPGWNAME="agic3gw"
APPGWRESOURCEGROUP="agic-k8s-3-rg-managed"
APPGWLOCATION="westeurope"
clientcertname="myclientcertname"
clientcertprofile="myclientcertprofile"
```

The following script will 
 * upload the root ca to appgw `az network application-gateway client-cert add ` under the name **$clientcertname**
 * create a ssl profile referencing the cert  `az network application-gateway ssl-profile add ` under the name **$clientcertprofile**

**important**:  The name of $clientcertprofile is referenced by the ingress defintion under the annotation  `appgw.ingress.kubernetes.io/appgw-ssl-profile: myclientcertprofile`

### Add App GW ssl-profile 
This adds the the client cert root cert that issued the client cert and create the ssl-profile that references 
```bash
echo "Renaming the root cert to .cer"
cp mTLS/ca.crt mTLS/ca.cer
## upload to app GW 
echo "Uploading the root cert to App Gateway variable $APPGWNAME and $APPGWRESOURCEGROUP and $APPGWLOCATION and $clientcert"
az network application-gateway client-cert add --gateway-name  $APPGWNAME  -g  $APPGWRESOURCEGROUP --name $clientcertname --data mTLS/ca.cer
## Create ssl profile referencing the cert
echo "Creating the SSL Profile for the client cert with variable $clientcertprofile and $clientcertname and $AGFC_NAME and $APPGWRESOURCEGROUP"
az network application-gateway ssl-profile add --gateway-name $APPGWNAME --resource-group $APPGWRESOURCEGROUP --name $clientcertprofile --trusted-client-cert $clientcertname --policy-name AppGwSslPolicy20220101S --policy-type Predefined --client-auth-config true
```

### Deploy App + Ingress + Rewrite rule
The httpbin.yaml deploys 
* Deployment with httpbin application
* Service
* Ingress based on AGIC ingress class 
* AzureApplicationGatewayRewrite. Which adds the client cert information into headers to be processed by back end.  Its also does this for redirects (this is for demo purposes and is not recommended )
  
The httpbin application responds with the headers it receives from the appgw. See https://httpbin.org/#/
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  labels:
    app: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
    spec:
      containers:
      - image: "kennethreitz/httpbin"
#      - image: "mendhak/http-https-echo"
        name: httpbin-image
        ports:
        - containerPort: 80
          protocol: TCP
---

apiVersion: v1
kind: Service
metadata:
  name: httpbin
spec:
  selector:
    app: httpbin
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: httpbin
  annotations:
   # kubernetes.io/ingress.class: azure/application-gateway
    appgw.ingress.kubernetes.io/appgw-ssl-profile: "myclientcertprofile"
    appgw.ingress.kubernetes.io/override-frontend-port: "443"
    appgw.ingress.kubernetes.io/rewrite-rule-set-custom-resource: my-rewrite-rule-set-custom-resource
spec:
  ingressClassName: azure-application-gateway
  tls:
    - secretName: frontend-tls
      hosts:
        - dev.aksingress.com
  rules:
  - host: dev.aksingress.com
    http:
      paths:
      - path: /
        backend:
          service:
            name: httpbin
            port:
              number: 80
        pathType: Exact
---
apiVersion: appgw.ingress.azure.io/v1beta1
kind: AzureApplicationGatewayRewrite
metadata:
  name: my-rewrite-rule-set-custom-resource
spec:
  rewriteRules:
  - name: rule1
    ruleSequence: 21

    conditions:
    - ignoreCase: false
      negate: false
      variable: http_req_Host
      pattern: dev.aksingress.com

    actions:
      requestHeaderConfigurations:
      - actionType: set
        headerName: client-certificate
        headerValue: "{var_client_certificate}"

      - actionType: set
        headerName: client-certificate-end-date
        headerValue: "{var_client_certificate_end_date}"

      - actionType: set
        headerName: client-certificate-fingerprint
        headerValue: "{var_client_certificate_fingerprint}"

      - actionType: set
        headerName: client-certificate-issuer
        headerValue: "{var_client_certificate_issuer}"

      - actionType: set
        headerName: client-certificate-serial
        headerValue: "{var_client_certificate_serial}"

      - actionType: set
        headerName: client-certificate-start-date
        headerValue: "{var_client_certificate_start_date}"

      - actionType: set
        headerName: client-certificate-verification
        headerValue: "{var_client_certificate_verification}"


  - name: rule2
    ruleSequence: 22

    conditions:
    - ignoreCase: true
      negate: false
      variable: var_http_status
      pattern: "302"

    actions:
      responseHeaderConfigurations:
      - actionType: set
        headerName: client-certificate
        headerValue: "{var_client_certificate}"

      - actionType: set
        headerName: client-certificate-end-date
        headerValue: "{var_client_certificate_end_date}"

      - actionType: set
        headerName: client-certificate-fingerprint
        headerValue: "{var_client_certificate_fingerprint}"

      - actionType: set
        headerName: client-certificate-issuer
        headerValue: "{var_client_certificate_issuer}"

      - actionType: set
        headerName: client-certificate-serial
        headerValue: "{var_client_certificate_serial}"

      - actionType: set
        headerName: client-certificate-start-date
        headerValue: "{var_client_certificate_start_date}"

      - actionType: set
        headerName: client-certificate-verification
        headerValue: "{var_client_certificate_verification}"

```





## Testing 
performed under the mtls folder. Where the ip address is the public ip of the app gw 
### To test if the cert works and responds with headers 
* ```bash
  curl  -H "Host: dev.aksingress.com" --resolve dev.aksingress.com:443:135.236.42.132     --cert client_dev.crt --key client_dev.key --cacert ca.crt https://dev.aksingress.com/headers```
  
### To test of it works with a redirect
* ```bash
   curl  -H "Host: dev.aksingress.com" --resolve dev.aksingress.com:443:135.236.42.132   --cert client_dev.crt --key client_dev.key "https://dev.aksingress.com/redirect-to?url=/headers&status_code=302" --cacert ca.crt   -v```

### Negative test to verify mtls fails without client cert, removing client cert
* ```bash
   curl  -H "Host: dev.aksingress.com" --resolve dev.aksingress.com:443:135.236.42.132   "https://dev.aksingress.com/redirect-to?url=/headers&status_code=302" --cacert ca.crt   -v```


### Test with open ssl 
* ```bash
  openssl s_client -connect 135.236.42.132:443 -servername dev.aksingress.com  -cert client_dev.cer  -key client_dev.key -CAfile ca.crt
  ## Copy past the following 
  GET /headers HTTP/1.1 
  Host: dev.aksingress.com
     ```
## Notes on challenges 
  * Client root/chain cannot reference KV certs for ssl profiles 
  * Format restricted to .cer
  * in shared environment, restricting how users create or modify/created a ssl profile would required advanced RBAC roles  
## Links 
 
* Client Headers https://learn.microsoft.com/en-us/azure/application-gateway/rewrite-http-headers-url#mutual-authentication-server-variables
* Ingress controller docs  https://azure.github.io/application-gateway-kubernetes-ingress/
* ssl-profile :https://azure.github.io/application-gateway-kubernetes-ingress/annotations/#appgw-ssl-profile
*  https://techcommunity.microsoft.com/t5/azure-paas-blog/mtls-between-aks-and-api-management/ba-p/1813887
* https://azure.microsoft.com/en-us/blog/secure-your-application-traffic-with-application-gateway-mtls/?msockid=2ebdcb848ea567b7010fdf6a8f0f66ad
  