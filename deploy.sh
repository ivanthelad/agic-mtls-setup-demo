


#!/bin/bash
VM_SIZE=Standard_D4s_v3


PREFIX='agic'
SUFFIX='6'

RGNAME="${PREFIX}-k8s-${SUFFIX}-rg"
RESOURCE_GROUP=$RGNAME
LOCATION='westeurope'
REGION=$LOCATION
AKSCLUSTERNAME="${PREFIX}${SUFFIX}aks"
APPGWNAME="${PREFIX}${SUFFIX}gw"

ACRNAME="${PREFIX}${SUFFIX}acr"
VERSION="1.30.3"
GRAFANA_NAME="${PREFIX}${SUFFIX}grafana"
AZMON_NAME="${PREFIX}${SUFFIX}azmon"
AKS_IDENTITY_NAME="${PREFIX}${SUFFIX}aksidentity"
AKS_KUBELET_IDENTITY_NAME="${PREFIX}${SUFFIX}kubletidentity"
vnetName="k8svnet"
KVNAME="${PREFIX}${SUFFIX}kv"
dnszone="azuredemoapps.com"
dnszone="${PREFIX}${SUFFIX}zone.com"
certifcatename="aks-ingress-tls"
IDENTITY_RESOURCE_NAME="azure-gw-identity"
AGFC_NAME="${PREFIX}${SUFFIX}agfc"
FRONTEND_NAME='test-frontend'

MAX_NODE_COUNT=3
MIN_NODE_COUNT=1
clientcertname="myclientcertname"
clientcertprofile="myclientcertprofile"
az group create --name $RGNAME --location $LOCATION

 az identity create -n  $AKS_IDENTITY_NAME -g $RGNAME -l $LOCATION 
     AKS_IDENTITY_ID="$(az identity show -n  $AKS_IDENTITY_NAME -g $RGNAME --query id -o tsv )"
      echo "created USER managed identity with id $AKS_IDENTITY_ID" 

az identity create -n  $AKS_KUBELET_IDENTITY_NAME -g $RESOURCE_GROUP -l $LOCATION  
AKS_KUBELET_IDENTITY_ID="$(az identity show -n  $AKS_KUBELET_IDENTITY_NAME -g $RGNAME --query id -o tsv )"
      echo "created USER managed identity with id $AKS_KUBELET_IDENTITY_ID" 

echo "Creating identity $IDENTITY_RESOURCE_NAME in resource group $RESOURCE_GROUP"
az identity create --resource-group $RESOURCE_GROUP --name $IDENTITY_RESOURCE_NAME
sleep 30
principalId="$(az identity show -g $RESOURCE_GROUP -n $IDENTITY_RESOURCE_NAME --query principalId -otsv)"



    ## Az mon 
    echo "Creating az virtual network"
    az network vnet create -g $RESOURCE_GROUP --location $REGION --name $vnetName --address-prefixes "196.0.0.0/8" 
    echo "Creating az virtual network subnets"
    az network vnet subnet create -g $RESOURCE_GROUP --vnet-name $vnetName --name nodesubnet --address-prefixes "196.240.0.0/16"  
     az network vnet subnet create -g $RESOURCE_GROUP --vnet-name $vnetName --name gwsubnet --address-prefixes "196.10.0.0/24"    



    NODE_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $vnetName --name nodesubnet --query id -o tsv)
    GW_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $vnetName --name gwsubnet --query id -o tsv)
    VNET_ID=$(az network vnet show -g $RESOURCE_GROUP --name $vnetName --query id -o tsv)
echo "Node subnet id $NODE_SUBNET_ID"
echo "GW subnet id $GW_SUBNET_ID"
echo "VNET id $VNET_ID"


az resource create \
--resource-group $RESOURCE_GROUP \
--namespace microsoft.monitor \
--resource-type accounts \
--name $AZMON_NAME \
--location $REGION \
--properties '{}' 
## keyvault 
echo "Creating keyvault $KVNAME" 
az keyvault create -g $RGNAME -l $LOCATION -n $KVNAME
sleep 30
#az keyvault certificate import --vault-name $KVNAME -n $certifcatename -f aks-ingress-tls.pfx
echo "Creating DNS zone $dnszone" 
az network dns zone create -g $RGNAME -n $dnszone

resourceGroupId=$(az group show --name $RESOURCE_GROUP --query id -otsv)


## --service-principal $SP_ID \
## --client-secret $SP_PASS \
sleep 40
echo managed identity $AKS_IDENTITY_ID
USER_ASSIGNED_IDENTITY_CLIENTID="$(  az identity show  --ids $AKS_IDENTITY_ID --query clientId -o tsv)"

echo creating kublet managed identity $
USER_ASSIGNED_IDENTITY_CLIENTID="$(  az identity show  --ids $AKS_IDENTITY_ID --query clientId -o tsv)"
AKS_VNET_RG=$(echo $SUBNET_ID|cut -d'/' -f 5) 
AKS_VNET=$(echo $SUBNET_ID| cut -d'/' -f 9)
echo $AKS_VNET_RG ..... $AKS_VNET .... $USER_ASSIGNED_IDENTITY_CLIENTID
echo  "Performing role assignments"
az role assignment create --assignee $USER_ASSIGNED_IDENTITY_CLIENTID --role "Contributor" --scope $VNET_ID
az role assignment create --assignee $USER_ASSIGNED_IDENTITY_CLIENTID --role "Network Contributor" --scope $VNET_ID




zonid=$(az network dns zone show  --name $dnszone -g $RGNAME --query id -o tsv)


echo "creating aks cluster"
az aks create -g $RGNAME -n $AKSCLUSTERNAME  --enable-managed-identity --node-count 3 --enable-addons monitoring --generate-ssh-keys \
 --enable-addons monitoring,azure-keyvault-secrets-provider,ingress-appgw \
 --nodepool-name="basepool" \
 --node-count 3 \
 --zones 1 2 3 \
 --node-resource-group $RGNAME-managed \
 --enable-managed-identity \
 --assign-identity $AKS_IDENTITY_ID \
 --assign-kubelet-identity $AKS_KUBELET_IDENTITY_ID \
 --network-plugin azure  \
 --auto-upgrade-channel stable \
 --vnet-subnet-id $NODE_SUBNET_ID \
 --kubernetes-version $VERSION \
 --node-vm-size=$VM_SIZE \
 --node-os-upgrade-channel SecurityPatch \
 --enable-cluster-autoscaler \
 --min-count $MIN_NODE_COUNT \
 --max-count $MAX_NODE_COUNT \
 --enable-advanced-network-observability  --enable-oidc-issuer --enable-workload-identity --enable-secret-rotation \
 --appgw-name $APPGWNAME --appgw-subnet-id $GW_SUBNET_ID  --generate-ssh-keys    
az aks get-credentials --resource-group $RGNAME --name $AKSCLUSTERNAME
# az aks mesh enable-ingress-gateway --resource-group $RGNAME --name $AKSCLUSTERNAME --ingress-gateway-type external


mcResourceGroupId=$(az group show --name $RGNAME-managed  --query id -o tsv)

echo "Waiting 60 seconds to allow for replication of the identity..."
sleep 60


echo "Set up federation with AKS OIDC issuer"
AKS_OIDC_ISSUER="$(az aks show -n "$AKSCLUSTERNAME" -g "$RESOURCE_GROUP" --query "oidcIssuerProfile.issuerUrl" -o tsv)"
echo "AKS OIDC issuer: $AKS_OIDC_ISSUER"
az identity federated-credential create --name "azure-gw-identity" \
    --identity-name "$IDENTITY_RESOURCE_NAME" \
    --resource-group $RESOURCE_GROUP \
    --issuer "$AKS_OIDC_ISSUER" \
    --subject "system:serviceaccount:azure-alb-system:alb-controller-sa"


## Grafana 
az grafana create \
--name $GRAFANA_NAME \
--resource-group $RESOURCE_GROUP

MANAGEDIDENTITY_OBJECTID=$(az aks show -g ${RESOURCE_GROUP} -n ${AKSCLUSTERNAME} --query ingressProfile.webAppRouting.identity.objectId -o tsv)

export AZMON_RESOURCE_ID=$(az resource show --resource-group $RESOURCE_GROUP --name $AZMON_NAME --resource-type "Microsoft.Monitor/accounts" --query id -o tsv)
export GRAFANA_RESOURCE_ID=$(az resource show --resource-group $RESOURCE_GROUP --name $GRAFANA_NAME --resource-type "microsoft.dashboard/grafana" --query id -o tsv)
## link az mon
echo "enabling monitoring"
az aks update --enable-azure-monitor-metrics \
-n $AKSCLUSTERNAME \
-g $RESOURCE_GROUP \
--azure-monitor-workspace-resource-id $AZMON_RESOURCE_ID \
--grafana-resource-id  $GRAFANA_RESOURCE_ID


### assign agic identity to subnet
# Get application gateway id from AKS addon profile
appGatewayId=$(az aks show -n $AKSCLUSTERNAME -g $RESOURCE_GROUP -o tsv --query "addonProfiles.ingressApplicationGateway.config.effectiveApplicationGatewayId")

# Get Application Gateway subnet id
appGatewaySubnetId=$(az network application-gateway show --ids $appGatewayId -o tsv --query "gatewayIPConfigurations[0].subnet.id")

# Get AGIC addon identity
agicAddonIdentity=$(az aks show -n $AKSCLUSTERNAME -g $RESOURCE_GROUP -o tsv --query "addonProfiles.ingressApplicationGateway.identity.clientId")

# Assign network contributor role to AGIC addon identity to subnet that contains the Application Gateway
az role assignment create --assignee $agicAddonIdentity --scope $appGatewaySubnetId --role "Network Contributor"

#### Now lets setup mtls  
echo "Setting up mTLS"
# Create CA
### https://techcommunity.microsoft.com/t5/azure-paas-blog/mtls-between-aks-and-api-management/ba-p/1813887
## https://azure.microsoft.com/en-us/blog/secure-your-application-traffic-with-application-gateway-mtls/?msockid=2ebdcb848ea567b7010fdf6a8f0f66ad
echo "Creating the CA and mTLS folder"
## certs stored here 
mkdir mTLS
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
echo "Uploading the root cert to App Gateway variable $APPGWNAME and $APPGWRESOURCEGROUP and $LOCATION and $clientcert"
az network application-gateway client-cert add --gateway-name  $APPGWNAME  -g  $RGNAME-managed --name $clientcertname --data mTLS/ca.cer
echo "Creating the SSL Policy"
az network application-gateway ssl-policy set --gateway-name $APPGWNAME  --resource-group $RGNAME-managed --name AppGwSslPolicy20220101S

echo "Creating the SSL Profile for the client cert with variable $clientcertprofile and $clientcertname and $AGFC_NAME and $APPGWRESOURCEGROUP"
az network application-gateway ssl-profile add --gateway-name $APPGWNAME --resource-group $RGNAME-managed --name $clientcertprofile --trusted-client-cert $clientcertname --policy-name AppGwSslPolicy20220101S --policy-type Predefined --client-auth-config true 
# Front end 
cd mTLS
echo "Creating the front end cert"
kubectl delete secret frontend-tls
echo "Creating the front end cert"
cat server_dev.crt ca.crt >> frontend.cer
echo "Creating the front end cert in k8s"
kubectl create secret tls frontend-tls --key="server_dev.key" --cert="server_dev.crt"
cd ..
echo "Creating the app end cert in k8s"
kubectl apply -f httpbin.yaml
exit 0
 


