#!/bin/bash -x


#source kavach_k8s_helpers.sh

# Install packages needed by Kavach.
sudo apt-get update
#sudo apt install -y jq docker.io apt-transport-https curl
sudo snap install helm --classic
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
sudo bash -c "cat >/etc/apt/sources.list.d/kubernetes.list" <<'EOF'
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
sudo apt-get update
sudo apt-get install --allow-downgrades -y kubelet=1.14.3-00 kubeadm=1.14.3-00 kubectl=1.14.3-00

# Destroy any pre-existing K8s cluster.
__k8s_cluster_destroy

# Create a new K8s cluster.
__k8s_cluster_setup
