#!/bin/bash

# this script can be executed on  on any environment where you can access VCenter and Supervisor Cluster VM Network.
# This script is used to add an insecure registry
# to a vSphere with Kubernetes Tanzu Kubernetes 
# cluster by executing the 'tkg-add-ca.sh' from Supervisor Master VM.
# the 'tkg-add-ca.sh' will restart the Docker daemon in every node, after adding the registry CA
#
# USAGE: tkg-insecure-registry.sh $name-cluster $namespace $url-registry
# original code from https://github.com/josemzr/vsphere-k8s-scripts
# Author: José Manzaneque (jmanzaneque@vmware.com)
# Dependencies: curl, jq, sshpass
# modified by kminseok
##############################################################################
################## Help message #############################################
##############################################################################
usage()
{
    echo "Usage: [FILE]... [Interactive] 

Mandatory arguments 
        --vc_ip          
        --vc_root_password
        --vc_admin_passowrd
        --vc_admin_user
        --sv_ip
        -c, --tkg_cluster_name            guest_cluster_name
        -n, --tkg_cluster_namespace       guest_cluster_namespace 
	    --ca_file_path  (required)
        -h, --help                        show help.
        
        Example:
        ${BASH_SOURCE[0]}  --vc_ip \${vc_ip} --vc_admin_passowrd \${admin_pass} --vc_admin_user \${admin_user} --vc_root_password \${root_pass} -c \${cluster_name} -n \${namespace} --ca_file_path \${ca_file_path}"
        ${BASH_SOURCE[0]} --vc_ip pacific-vcsa.haas-455.pez.vmware.com --vc_admin_passowrd secret --vc_admin_user administrator@vsphere.local --vc_root_password secret  \
                          --sv_ip wcp.haas-455.pez.vmware.com -c ns1-tkg1 -n  ns1  --ca_file_path ../harbor-root-ca.crt


}

VC_IP='' #URL for the vCenter
VC_ADMIN_USER='' #'administrator@vsphere.local' #User for the Supervisor Cluster
VC_ADMIN_PASSWORD="" #'VMware1!' #Password for the Supervisor Cluster user
VC_ROOT_PASSWORD=""
SV_IP=""  #'192.168.40.129' #VIP for the Supervisor Cluster
TKG_CLUSTER_NAME="" # Name of the TKG cluster
TKG_CLUSTER_NAMESPACE="" # Namespace where the TKG cluster is deployed
CA_FILE_PATH="" # required. put the file path

# Check if parameter value is empty.
check_if_value_exist()
{
    current_param=$1
    if [ "$current_param" = "" ]
        then 
        echo "parameter cannot be empty"
        exit 1
    fi
}


check_if_any_argument_supplied()
{
    if [ "$#" -eq 0 ]
        then
        usage
        exit 1
    fi
}


print_current_arg()
{
      echo "Debug $1: $2"
}

define_arguments()
{
    check_if_any_argument_supplied $@   

    while [ "$#" -gt 0 ]; do
    # while [ "x$1" != "x" ]; do
    # while [ "$1" != "" ]; do
        case $1 in
            --vc_ip ) shift 
                check_if_value_exist $1 
                VC_IP=$1
                print_current_arg "VC_IP" $1
                ;;

            --vc_admin_passowrd ) shift 
                check_if_value_exist $1 
                VC_ADMIN_PASSWORD=$1
                ;;
            --vc_root_password ) shift 
                check_if_value_exist $1 
                VC_ROOT_PASSWORD=$1
                ;;
            --vc_admin_user ) shift 
                check_if_value_exist $1 
                VC_ADMIN_USER=$1
                print_current_arg "VC_ADMIN_USER" $1
                ;;
            --sv_ip ) shift 
                check_if_value_exist $1 
                SV_IP=$1
                print_current_arg "SV_IP" $1
                ;;
            -c | --tkg_cluster_name ) shift
                check_if_value_exist $1
                TKG_CLUSTER_NAME=$1
                print_current_arg "TKG_CLUSTER_NAME" $1
                ;;
            -n | --tkg_cluster_namespace ) shift 
                check_if_value_exist $1 
                TKG_CLUSTER_NAMESPACE=$1
                print_current_arg "TKG_CLUSTER_NAMESPACE" $1
                ;;
            --ca_file_path ) shift 
                check_if_value_exist $1 
                CA_FILE_PATH=$1
                print_current_arg "CA_FILE_PATH" $1
                ;;
            -h | --help )        
                usage
                exit
                ;;
            * ) 
                usage
                exit 1
                ;;
        esac
        shift
    done

#     check_if_argument_exist
}


##############################################################################
##############################################################################
##############################################################################

define_arguments $@

# Logging function that will redirect to stderr with timestamp:
logerr() { echo "$(date) ERROR: $@" 1>&2; }
# Logging function that will redirect to stdout with timestamp
loginfo() { echo "$(date) INFO: $@" ;}

# Verify if required arguments are met

if [[ -z "$1" || -z "$2" || -z "$3" ]]
  then
    logerr "Invalid arguments. Exiting..."
    exit 2
fi

if [[ ! -f "$CA_FILE_PATH" ]]; then 
  logerr "File Not Found $CA_FILE_PATH";
  exit 1;
fi



#SSH into vCenter to get credentials for the supervisor cluster master VMs
sshpass -p "${VC_ROOT_PASSWORD}" ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -q root@"${VC_IP}" com.vmware.shell /usr/lib/vmware-wcp/decryptK8Pwd.py > ./sv-cluster-creds 2>&1
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
rm -rf ./sv-cluster-creds
export SSHPASS="${SV_MASTER_PASSWORD}"


loginfo "" 
loginfo "Copying tkg-add-ca.sh, CA file to Supervisor Master VM ..."
_CA_FILE=$(basename $CA_FILE_PATH)
sshpass -p "${SV_MASTER_PASSWORD}" scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $CA_FILE_PATH root@"${SV_MASTER_IP}":/tmp/$_CA_FILE
sshpass -p "${SV_MASTER_PASSWORD}" scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ./tkg-add-ca.sh root@"${SV_MASTER_IP}":/tmp/tkg-add-ca.sh

loginfo "Executing /tmp/tkg-add-ca.sh on Supervisor cluster VM ..."
sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q -t root@"${SV_MASTER_IP}" chmod +x /tmp/tkg-add-ca.sh 
sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q -t root@"${SV_MASTER_IP}" /tmp/tkg-add-ca.sh "$SV_IP" "$VC_ADMIN_USER" "$VC_ADMIN_PASSWORD" "$VC_ROOT_PASSWORD" "$TKG_CLUSTER_NAME" "$TKG_CLUSTER_NAMESPACE" "/tmp/$_CA_FILE"

if [ $? -eq 0 ] ;
then
  loginfo "Executing /tmp/tkg-add-ca.sh on Supervisor cluster VM successful !"
else
  logerr "There was an error Executing /tmp/tkg-add-ca.sh on Supervisor cluster VM. Exiting..."
  exit 2
fi
