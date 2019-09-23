#!/bin/bash -x

MAX_RETRY_COUNT="36"
RETRY_INTERVAL_SECS="5"
KUBE_SYSTEM_PODS_OF_INTEREST="kube-apiserver kube-controller-manager kube-scheduler"
FLANNEL_PODS_OF_INTEREST="kube-flannel"
ADMIN_KUBECONFIG="/etc/kubernetes/admin.conf"

# Check if a Pod is ready.
function __is_pod_ready() {
  [[ "$(sudo KUBECONFIG=${ADMIN_KUBECONFIG} kubectl get pods "$1" -n "$2" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}')" == 'True' ]]
}

# This methods waits for requested pods to get to Ready state.
# The method waits (MAX_RETRY_COUNT * RETRY_INTERVAL_SECS) secs for each pod.
# If a pod does not get to ready state by this time, the method returns with
# non-zero return status.
function __wait_for_pods() {
  local period i pods pod_name pod_ready namespace pod_list

  [[ "$#" != 2 ]] && return 1

  namespace="$1"
  pod_list="$2"

  for pod_name in ${pod_list}; do
      for ((i=0; i<${MAX_RETRY_COUNT}; i+=1));
      do
          pods=$(sudo KUBECONFIG=${ADMIN_KUBECONFIG} kubectl get pods -n ${namespace} --no-headers=true | cut -f 1 -d ' '| grep ${pod_name} | sed 'N;s/\n/ /')
          if [[ ! -z ${pods} ]]; then
            break
          fi
          echo "Waiting for pods to be started...(try ${i})..."
          sleep "${RETRY_INTERVAL_SECS}"
      done

      if [[ -z ${pods} ]]; then
          return 1
      fi

      IFS=' ' read -r -a array <<< "${pods}"
      for pod in "${array[@]}";
      do
          pod_ready=false
          for ((i=0; i<${MAX_RETRY_COUNT}; i+=1));
          do
              if __is_pod_ready ${pod} ${namespace}; then
                  pod_ready=true
                  break
              fi

              echo "Waiting for pods to be ready...(try ${i})..."
              sleep "${RETRY_INTERVAL_SECS}"
          done

          if ! ${pod_ready}; then
              period=$( expr "${MAX_RETRY_COUNT}" * "${RETRY_INTERVAL_SECS}" )
              echo "Waited for ${period} seconds, but all pods are not ready yet."
              return 1
          fi
      done
  done

  # All requested pods are ready.
  return 0
}

# This method destroys a K8s cluster.
function __k8s_cluster_destroy() {
    # Reset any pre-existing K8s cluster.
    sudo kubeadm reset -f

    # Clean up cni files.
    rm -rf /var/lib/cni/flannel/*
    rm -rf /var/lib/cni/networks/cbr0/*

    # Clean up old certs.
    rm -rf /etc/kubernetes

    # Clean up old etcd state.
    rm -rf /var/lib/etcd

    # Clean up cni devices.
    sudo ip link delete cni0
    sudo ip link delete flannel.1
}

# This method sets up a full fledged K8s cluster with CNI networking enabled..
function __k8s_cluster_setup() {

    # Reset IPTables rules relevant to k8s cluster.
    iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X

    # Disable swap memory.
    sudo swapoff -a

    # Create a K8s cluster.
    sudo kubeadm init phase certs all -v 9

    # Cert init is added again so as to guarantee the certs will be valid by the time
    # kubeconfig phase is invoked. This is to workaround a race condition in kubeadm.
    sudo kubeadm init phase certs all -v 9

    sudo kubeadm init phase kubeconfig all
    sudo kubeadm init phase control-plane all --pod-network-cidr 10.244.0.0/16
    sudo sed -i '/.*- --service-cluster-ip-range/a\    - --service-node-port-range=15000-32767' /etc/kubernetes/manifests/kube-apiserver.yaml
    sudo systemctl restart kubelet
    sudo kubeadm init --skip-phases=certs,kubeconfig,control-plane --ignore-preflight-errors=all --pod-network-cidr 10.244.0.0/16 --apiserver-advertise-address=0.0.0.0

    # Copy over credentials for cluster access.
    sudo mkdir -p /root/.kube
    sudo cp -rf /etc/kubernetes/admin.conf /root/.kube/config
    sudo chown $(id -u):$(id -g) /root/.kube/config

    # Wait for kubernetes controller pods.
    __wait_for_pods "kube-system" "${KUBE_SYSTEM_PODS_OF_INTEREST}"
    if [ $? -ne 0 ]; then
        echo "Wait for kubernetes controller pods to come up, failed"
        exit 1
    fi

    # Remove taint on the master, so we can run kavach pods on it.
    sudo KUBECONFIG=${ADMIN_KUBECONFIG} kubectl taint nodes --all node-role.kubernetes.io/master-
    if [ $? -ne 0 ]; then
        echo "Untaint of master node, failed"
        exit 1
    fi

    echo "Setup flannel cni."
    sudo cat /proc/sys/net/bridge/bridge-nf-call-iptables
    sudo KUBECONFIG=${ADMIN_KUBECONFIG} kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/a70459be0084506e4ec919aa1c114638878db11b/Documentation/kube-flannel.yml

    # Wait for flanner CNI pods to get running.
    __wait_for_pods "kube-system" "${FLANNEL_PODS_OF_INTEREST}"
    if [ $? -ne 0 ]; then
        echo "Wait for flannel pods to come up, failed"
        exit 1
    fi
}
