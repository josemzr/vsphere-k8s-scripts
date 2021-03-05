#!/bin/bash
# This script is used to add a CA to the Docker daemon
# in a vSphere with Tanzu Tanzu Kubernetes 
# cluster. After adding the CA, it will restart
# the Docker daemon in every node.
#
# USAGE: tkg-add-ca.sh $name-cluster $vsphere-namespace $cafile
# EXAMPLE: ./tkg-add-ca.sh tkg-cluster-1 test-namespace /home/vmware/ca.crt
# 
# Author: José Manzaneque (jmanzaneque@vmware.com)
# Dependencies: curl, jq

SV_IP="$1"  #VIP for the Supervisor Cluster
VC_ADMIN_USER="$2" #'administrator@vsphere.local' #User for the Supervisor Cluster
VC_ADMIN_PASSWORD="$3" #Password for the Supervisor Cluster user
VC_ROOT_PASSWORD="$4" #Password for the root VCSA user

TKG_CLUSTER_NAME="$5" # Name of the TKG cluster
TKG_CLUSTER_NAMESPACE="$6" # Namespace where the TKG cluster is deployed
CA_FILE="$7" # Path for the CA file to be transferred

# Logging function that will redirect to stderr with timestamp:
logerr() { echo "$(date) ERROR: $@" 1>&2; }
# Logging function that will redirect to stdout with timestamp
loginfo() { echo "$(date) INFO: $@" ;}


loginfo "SV_IP:$SV_IP"
loginfo "VC_ADMIN_USER:$VC_ADMIN_USER"
loginfo "VC_ADMIN_PASSWORD:$VC_ADMIN_PASSWORD"
loginfo "VC_ROOT_PASSWORD:$VC_ROOT_PASSWORD"
loginfo "TKG_CLUSTER_NAME:$TKG_CLUSTER_NAME"
loginfo "TKG_CLUSTER_NAMESPACE:$TKG_CLUSTER_NAMESPACE"
loginfo "CA_FILE:$CA_FILE"


# Verify if required arguments are met

if [[ -z "$1" || -z "$2" || -z "$3" ]]
  then
    logerr "Invalid arguments. Exiting..."
    exit 2
fi

# Exit the script if the supervisor cluster is not up
if [ $(curl -m 15 -k -s -o /dev/null -w "%{http_code}" https://"${SV_IP}") -ne "200" ]; then
    logerr "Supervisor cluster not ready. Exiting..."
    exit 2
fi

# If the supervisor cluster is ready, get the token for TKG cluster
loginfo "Supervisor cluster is ready!"
loginfo "Getting TKC Kubernetes API token..."

# Get the TKG Kubernetes API token by login into the Supervisor Cluster
TKC_API=$(curl -XPOST -s -u "${VC_ADMIN_USER}":"${VC_ADMIN_PASSWORD}" https://"${SV_IP}":443/wcp/login -k -d '{"guest_cluster_name":"'"${TKG_CLUSTER_NAME}"'", "guest_cluster_namespace":"'"${TKG_CLUSTER_NAMESPACE}"'"}' -H "Content-Type: application/json" | jq -r '.guest_cluster_server')
TOKEN=$(curl -XPOST -s -u "${VC_ADMIN_USER}":"${VC_ADMIN_PASSWORD}" https://"${SV_IP}":443/wcp/login -k -d '{"guest_cluster_name":"'"${TKG_CLUSTER_NAME}"'", "guest_cluster_namespace":"'"${TKG_CLUSTER_NAMESPACE}"'"}' -H "Content-Type: application/json" | jq -r '.session_id')
# I'm sure there is a better way to store the JSON in two variables in a single pipe execution. But I can't be bothered to search on StackOverflow right now.



##################################################################################################################################
# Verify if the token is valid
if [ $(curl -k -s -o /dev/null -w "%{http_code}" https://"${TKC_API}":6443/ --header "Authorization: Bearer "${TOKEN}"") -ne "200" ]
then
      logerr "TKC Kubernetes API token is not valid. Exiting..."
      exit 2
else
      loginfo "TKC Kubernetes API token is valid!"
fi

#Get the list of nodes in the cluster
curl -XGET -k --fail -s https://"${TKC_API}":6443/api/v1/nodes --header 'Content-Type: application/json' --header "Authorization: Bearer "${TOKEN}"" >> /dev/null
if [ $? -eq 0 ] ;
then      
      loginfo "Getting the IPs of the nodes in the cluster..."
      curl -XGET -k --fail -s https://"${TKC_API}":6443/api/v1/nodes --header 'Content-Type: application/json' --header "Authorization: Bearer "${TOKEN}"" | jq -r '.items[].status.addresses[] | select(.type=="InternalIP").address' > ./ip-nodes-tkg
      loginfo "The nodes IPs are: "$(column ./ip-nodes-tkg | sed 's/\t/,/g')""
else
      logerr "There was an error processing the IPs of the nodes. Exiting..."
      exit 2
fi


#Get Supervisor Cluster token to get the TKC nodes SSH Private Key
loginfo "Getting Supervisor Cluster Kubernetes API token..."
SV_TOKEN=$(curl -XPOST -s --fail -u "${VC_ADMIN_USER}":"${VC_ADMIN_PASSWORD}" https://"${SV_IP}":443/wcp/login -k -H "Content-Type: application/json" | jq -r '.session_id')

# Verify if the Supervisor Cluster token is valid
# Health check in /api/v1 (Supervisor Cluster forbids accessing / directly (TKC cluster allows it))
if [ $(curl -k -s -o /dev/null -w "%{http_code}" https://"${SV_IP}":6443/api/v1 --header "Authorization: Bearer "${SV_TOKEN}"") -ne "200" ]
then
      logerr "Supervisor Cluster Kubernetes API token is not valid. Exiting..."
      exit 2
else
      loginfo "Supervisor Cluster Kubernetes API token is valid!"
fi

# Get the TKC nodes SSH private key from the Supervisor Cluster
curl -XGET -k --fail -s https://"${SV_IP}":6443/api/v1/namespaces/"${TKG_CLUSTER_NAMESPACE}"/secrets/"${TKG_CLUSTER_NAME}"-ssh --header 'Content-Type: application/json' --header "Authorization: Bearer "${SV_TOKEN}"" >> /dev/null 
if [ $? -eq 0 ] ;
then      
      loginfo "Getting the TKC nodes SSH private key from the supervisor cluster..."
      curl -XGET -k --fail -s https://"${SV_IP}":6443/api/v1/namespaces/"${TKG_CLUSTER_NAMESPACE}"/secrets/"${TKG_CLUSTER_NAME}"-ssh --header 'Content-Type: application/json' --header "Authorization: Bearer "${SV_TOKEN}"" | jq -r '.data."ssh-privatekey"' | base64 -d > ./tkc-ssh-privatekey
      #Set correct permissions for TKC SSH private key
      chmod 400 ./tkc-ssh-privatekey
      loginfo "TKC SSH private key retrieved successfully!"
else
      logerr "There was an error getting the TKC nodes SSH private key. Exiting..."
      exit 2
fi

########################################################################################################
# SSH to every node and transfer the CA

while read -r IPS_NODES_READ;
do
loginfo "Adding CA to the node '"${IPS_NODES_READ}"'..."
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./tkc-ssh-privatekey "${CA_FILE}" vmware-system-user@"${IPS_NODES_READ}":/home/vmware-system-user/registry_ca.crt
ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./tkc-ssh-privatekey vmware-system-user@"${IPS_NODES_READ}" << EOF
sudo bash -c "cat /home/vmware-system-user/registry_ca.crt >> /etc/pki/tls/certs/ca-bundle.crt"
EOF
if [ $? -eq 0 ] ;
then  
      loginfo "CA added successfully!"
else
      logerr "There was an error transferring the CA to the TKC node. Exiting..."
      exit 2
fi
done < "./ip-nodes-tkg"

# Restart the Docker daemon
while read -r IPS_NODES_READ;
do
loginfo "Restarting Docker on node '"${IPS_NODES_READ}"'..."
ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./tkc-ssh-privatekey vmware-system-user@"${IPS_NODES_READ}" << EOF
sudo systemctl restart docker.service 
EOF
if [ $? -eq 0 ] ;
then  
      loginfo "Docker daemon restarted successfully!"
else
      logerr "There was an error restarting the Docker daemon. Exiting..."
      exit 2
fi
done < "./ip-nodes-tkg"

# Cleaning up
loginfo "Cleaning up temporary files..."
rm -rf ./tkc-ssh-privatekey
rm -rf ./sv-cluster-creds
rm -rf ./ip-nodes-tkg
