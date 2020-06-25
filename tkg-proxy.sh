#!/bin/bash
# This script is used to add a proxy to the Docker daemon
# in a vSphere with Kubernetes Tanzu Kubernetes 
# cluster. After adding the proxy, it will restart
# the Docker daemon in every node.
#
# USAGE: tkg-proxy.sh $name-cluster $namespace
# 
# Author: José Manzaneque (jmanzaneque@vmware.com)
# Dependencies: curl, jq, sshpass

SV_IP='192.168.50.128' #VIP for the Supervisor Cluster
VC_IP='vcsa.corp.local' #URL for the vCenter
VC_ADMIN_USER='administrator@vsphere.local' #User for the Supervisor Cluster
VC_ADMIN_PASSWORD='VMware1!' #Password for the Supervisor Cluster user
VC_ROOT_PASSWORD='VMware1!' #Password for the root VCSA user

TKG_CLUSTER_NAME=$1 # Name of the TKG cluster
TKG_CLUSTER_NAMESPACE=$2 # Namespace where the TKG cluster is deployed

# Logging function that will redirect to stderr with timestamp:
logerr() { echo "$(date) ERROR: $@" 1>&2; }
# Logging function that will redirect to stdout with timestamp
loginfo() { echo "$(date) INFO: $@" ;}

# Verify if required arguments are met

if [[ -z "$1" || -z "$2" ]]
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

#SSH into vCenter to get credentials for the supervisor cluster master VMs
sshpass -p "${VC_ROOT_PASSWORD}" ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q root@"${VC_IP}" com.vmware.shell /usr/lib/vmware-wcp/decryptK8Pwd.py > ./sv-cluster-creds 2>&1
if [ $? -eq 0 ] ;
then      
      loginfo "Connecting to the vCenter to get the supervisor cluster VM credentials..."
      SV_MASTER_IP=$(cat ./sv-cluster-creds | sed -n -e 's/^.*IP: //p')
      SV_MASTER_PASSWORD=$(cat ./sv-cluster-creds | sed -n -e 's/^.*PWD: //p')
      loginfo "Supervisor cluster master IP is: "${SV_MASTER_IP}""
else
      logerr "There was an error logging into the vCenter. Exiting..."
      exit 2
fi

#Get Supervisor Cluster token to get the TKC nodes SSH Password
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
      chmod 600 ./tkc-ssh-privatekey
      loginfo "TKC SSH private key retrieved successfully!"
else
      logerr "There was an error getting the TKC nodes SSH private key. Exiting..."
      exit 2
fi

# Transfer the TKC nodes SSH private key to the Supervisor Cluster Master VM
loginfo "Transferring the TKC nodes SSH private key to the supervisor cluster VM..."
sshpass -p "${SV_MASTER_PASSWORD}" scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ./tkc-ssh-privatekey root@"${SV_MASTER_IP}":./tkc-ssh-privatekey >> /dev/null
if [ $? -eq 0 ] ;
then      
      loginfo "TKC SSH private key transferred successfully!"
else
      logerr "There was an error transferring the TKC nodes SSH private key. Exiting..."
      exit 2
fi

# SSH to every node and verify if the registry does not exist in /etc/docker/daemon.json. If it does not exist, add it
export SSHPASS="${SV_MASTER_PASSWORD}"

while read -r IPS_NODES_READ;
do
loginfo "Adding proxy to the node '"${IPS_NODES_READ}"'..."
sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q -t root@"${SV_MASTER_IP}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./tkc-ssh-privatekey -t -q vmware-system-user@"${IPS_NODES_READ}" << EOF
sudo -i
mkdir -p /etc/systemd/system/docker.service.d
rm -rf /etc/systemd/system/docker.service.d/http-proxy.conf
cat <<EOF1 > /etc/systemd/system/docker.service.d/http-proxy.conf.new
[Service]
Environment="HTTP_PROXY=ADD PROXY HERE"
Environment="HTTPS_PROXY=ADD PROXY HERE"
Environment="NO_PROXY=ADD NOPROXY HOSTS HERE"
EOF1
#Verify that the change was added successfully. If it was, replace daemon.json. If not, exit without copying.
if [[ -s /etc/systemd/system/docker.service.d/http-proxy.conf.new ]]; then mv /etc/systemd/system/docker.service.d/http-proxy.conf.new /etc/systemd/system/docker.service.d/http-proxy.conf ; else exit 2; fi
EOF
if [ $? -eq 0 ] ;
then  
      loginfo "Proxy added successfully!"
else
      logerr "There was an error writing the proxy to /etc/systemd/system/docker.service.d. Exiting..."
      exit 2
fi
done < "./ip-nodes-tkg"

# Restart the Docker daemon
while read -r IPS_NODES_READ;
do
loginfo "Restarting Docker on node '"${IPS_NODES_READ}"'..."
sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q -t root@"${SV_MASTER_IP}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./tkc-ssh-privatekey -t -q vmware-system-user@"${IPS_NODES_READ}" << EOF
sudo -i
systemctl daemon-reload
systemctl stop docker
systemctl start docker
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
