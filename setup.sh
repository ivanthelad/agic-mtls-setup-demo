### App GW stuff 
echo " Setting up App Gateway"
APPGWNAME="agic3gw"
APPGWRESOURCEGROUP="agic-k8s-3-rg-managed"
APPGWLOCATION="westeurope"
clientcertname="myclientcertname"
clientcertprofile="myclientcertprofile"
# Create CA
### https://techcommunity.microsoft.com/t5/azure-paas-blog/mtls-between-aks-and-api-management/ba-p/1813887
## https://azure.microsoft.com/en-us/blog/secure-your-application-traffic-with-application-gateway-mtls/?msockid=2ebdcb848ea567b7010fdf6a8f0f66ad
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



#openssl pkcs12 -export -out mTLS/ca.pfx -inkey mTLS/ca.key -in mTLS/ca.crt
#openssl pkcs12 -export -out mTLS/client_dev.pfx -inkey mTLS/client_dev.key -in mTLS/client_dev.crt
#openssl pkcs12 -export -out mTLS/server_dev.pfx -inkey mTLS/server_dev.key -in mTLS/server_dev.crt
## rename root to .cer 
echo "Renaming the root cert to .cer"
cp mTLS/ca.crt mTLS/ca.cer
## upload to app GW 
echo "Uploading the root cert to App Gateway variable $APPGWNAME and $APPGWRESOURCEGROUP and $APPGWLOCATION and $clientcert"
az network application-gateway client-cert add --gateway-name  $APPGWNAME  -g  $APPGWRESOURCEGROUP --name $clientcertname --data mTLS/ca.cer

echo "Creating the SSL Profile for the client cert with variable $clientcertprofile and $clientcertname and $AGFC_NAME and $APPGWRESOURCEGROUP"
az network application-gateway ssl-profile add --gateway-name $APPGWNAME --resource-group $APPGWRESOURCEGROUP --name $clientcertprofile --trusted-client-cert $clientcertname --policy-name AppGwSslPolicy20220101S --policy-type Predefined --client-auth-config true

# Front end 
cd mTLS
echo "Creating the front end cert"
kubectl delete secret frontend-tls
echo "Creating the front end cert"
cat server_dev.crt ca.crt >> frontend.cer
echo "Creating the front end cert in k8s"
kubectl create secret tls frontend-tls --key="server_dev.key" --cert="server_dev.crt"
cd ..

exit 
#To test 
# curl -k -H "Host: dev.aksingress.com"  https://135.236.42.132 --insecure
<html>
<head><title>400 No required SSL certificate was sent</title></head>
<body>
<center><h1>400 Bad Request</h1></center>
<center>No required SSL certificate was sent</center>
<hr><center>Microsoft-Azure-Application-Gateway/v2</center>
</body>
</html>
#  curl -k -H "Host: dev.aksingress.com"  https://135.236.42.132 --insecure --cert client_dev.crt  --key  client_dev.key


### Checking the DN 
└─> openssl x509 -in server_dev.crt -noout -subject
subject=CN=dev.aksingress.com, emailAddress=acp@microsoft.com, O=Microsoft, OU=CSE, L=Redmond, ST=WA, C=US#


## 
 curl s_client -connect  -k -H "Host: dev.aksingress.com"  https://135.236.42.132  --cert test2.cer --key client_dev.key --cacert server_dev.crt

 openssl s_client -connect 
 openssl s_client -connect 135.236.42.132:443 -servername dev.aksingress.com  -cert test2.cer  -key client_dev.key -CAfile server_dev.crt
## verify with openssl 
 └─>  openssl s_client -connect 135.236.42.132:443 -servername dev.aksingress.com  -cert test2.cer  -key client_dev.key -CAfile server_dev.crt


  to get this working. The front end cert needs to be the full chain 

  Call with openssl 

Step 1 
*  openssl s_client -connect 135.236.42.132:443 -servername dev.aksingress.com  -cert test2.cer  -key client_dev.key -CAfile ca.crt
Step 2   copy paste the following to acces  
GET / HTTP/1.1
Host: dev.aksingress.com

curl  -H "Host: dev.aksingress.com" --resolve dev.aksingress.com:443:135.236.42.132   https://dev.aksingress.com  --cert test2.cer --key client_dev.key --cacert ca.crt


Notes. Create the cert with the following