# Scripts for vSphere 7 with Kubernetes

These are the scripts that I use for vSphere with Kubernetes.

# TKG-insecure-registry.sh

This is a script to add an insecure registry to all the nodes in a Tanzu Kubernetes cluster deployed by the Tanzu Kubernetes Grid service in vSphere 7 (formerly known as guest cluster). This script does:

1. Get a Kubernetes API token for the Tanzu Kubernetes cluster
2. Get the list of the nodes in the cluster
3. SSH into vCenter to get credentials for the Supervisor Cluster master VMs
4. Get a Supervisor Cluster Kubernetes API token to get the TKC nodes SSH Password 
5. Get the TKC nodes SSH private key from the Supervisor Cluster (it is stored as a secret in the Supervisor Cluster)
6. SSH to every node and verify if the registry does not exist in /etc/docker/daemon.json. If it does not exist, it adds it
7. Restarts the Docker daemon in every node

The dependencies for this script are curl, jq and sshpass. Usage is as follows:

`tkg-insecure-registry.sh $name-cluster $namespace $url-registry`

# TKG-proxy.sh

This is a script to add a HTTP/HTTPS proxy to the Docker daemon of all the nodes in a Tanzu Kubernetes cluster deployed by the Tanzu Kubernetes Grid service in vSphere 7 (formerly known as guest cluster). To add your proxy server, change the lines HTTP_PROXY, HTTPS_PROXY and NO_PROXY in the script. This script does:

1. Get a Kubernetes API token for the Tanzu Kubernetes cluster
2. Get the list of the nodes in the cluster
3. SSH into vCenter to get credentials for the Supervisor Cluster master VMs
4. Get a Supervisor Cluster Kubernetes API token to get the TKC nodes SSH Password
5. Get the TKC nodes SSH private key from the Supervisor Cluster (it is stored as a secret in the Supervisor Cluster)
6. SSH to every node and add the proxy server to /etc/systemd/system/docker.service.d/http-proxy.conf.
7. Reloads the systemd Docker daemon and restarts it in every node

The dependencies for this script are curl, jq and sshpass. Usage is as follows:

`tkg-proxy.sh $name-cluster $namespace`

**These scripts are not meant for production use and changes will be overwritten with any Day-2 operation that involves node replacements**
