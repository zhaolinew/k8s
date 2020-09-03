#!/bin/bash
source ./00environment.sh

# for unique IPs
if [ -n "$2" -a -n "$3" ]; then
  NODE_IPS=($2)
  NODE_NAMES=($3)
elif [ -z "$2" -a -z "$3" ]; then
  NODE_IPS=(${NEW_NODE_IPS[*]})
  NODE_NAMES=(${NEW_NODE_NAMES[*]})
elif [ -z "$2" -o -z "$3" ]; then
	echo "please run ./01-init-prepare.sh first for new nodes"
  echo "useage $0 <containerd|docker> [node_ip] [node_name]"
  exit 1
fi

############################################
# 复制CA文件到 node
############################################
set_ca(){
for node_ip in ${NODE_IPS[@]}; do
    gecho ">>> 复制以下文件到${node_ip}"
    ssh root@${node_ip} "mkdir -p /opt/k8s/cert"
    scp ca.pem root@${node_ip}:/opt/k8s/cert
done
}

############################################
# 创建和分发 containerd 配置文件
############################################
# 分发二进制文件到所有 worker 节点：
set_containerd(){
for node_ip in ${NODE_IPS[@]}; do
    gecho ">>> 分发 containerd 二进制文件到 worker 节点 ${node_ip}"
    scp containerd/bin/* crictl runc root@${node_ip}:/opt/k8s/bin
#    scp cni-plugins/* root@${node_ip}:/opt/cni/bin
    ssh root@${node_ip} "chmod a+x /opt/k8s/bin/* && mkdir -p /etc/cni/net.d"

# 分发 containerd 配置文件
    gecho ">>> 分发 containerd 配置文件 ${node_ip}"
    ssh root@${node_ip} "mkdir -p /etc/containerd ${CONTAINERD_DIR}/{root,state}"
    scp containerd-config.toml root@${node_ip}:/etc/containerd/config.toml

# 分发 systemd unit 文件，启动 containerd 服务
    gecho ">>> 分发 systemd unit 文件，启动 containerd 服务 ${node_ip}"
    scp containerd.service root@${node_ip}:/etc/systemd/system
	
	gecho ">>> 启动 containerd 服务 ${node_ip}"
    ssh root@${node_ip} "systemctl enable containerd && systemctl restart containerd"
	sleep 5
	
	gecho ">>> 检查 containerd 服务运行状态 ${node_ip}"
    ssh root@${node_ip} "systemctl status containerd | grep Active"
	
# 创建和分发 crictl 配置文件	
    gecho ">>> 分发 crictl.yaml 到 worker 节点 ${node_ip}"
    scp crictl.yaml root@${node_ip}:/etc/crictl.yaml
  done
}

#############################################################
# 创建和分发 Docker 文件
#############################################################
# 分发|启动|检查 docker 配置文件到所有 worker 节点：
set_docker(){
for node_ip in ${NODE_IPS[@]}
  do
    ssh root@${node_ip} "mkdir /etc/cni/net.d -p"
    gecho ">>> 分发 docker 二进制文件到 ${node_ip}"
    scp docker/*  root@${node_ip}:/opt/k8s/bin/
    ssh root@${node_ip} "chmod +x /opt/k8s/bin/*"
  done

for node_ip in ${NODE_IPS[@]}
  do
    sed -i -e "s|##DOCKER_DIR##|${DOCKER_DIR}|" docker.service
    gecho ">>> 分发 docker systemd 文件到 ${node_ip}"
    scp docker.service root@${node_ip}:/etc/systemd/system/
  done

for node_ip in ${NODE_IPS[@]}
  do
    gecho ">>> 分发 docker 配置文件到 ${node_ip}"
    ssh root@${node_ip} "mkdir -p  /etc/docker/ ${DOCKER_DIR}/{data,exec}"
    scp docker-daemon.json root@${node_ip}:/etc/docker/daemon.json
  done

for node_ip in ${NODE_IPS[@]}
  do
    gecho ">>> 启动 docker 服务 ${node_ip}"
    ssh root@${node_ip} "systemctl daemon-reload && systemctl enable docker && systemctl restart docker"
    sleep 5
  done

for node_ip in ${NODE_IPS[@]}
  do
    gecho ">>> 检查 docker 服务运行状态 ${node_ip}"
    ssh root@${node_ip} "systemctl status docker|grep Active"
  done
}

##############################################################
# 分发 kubelet 二进制文件
##############################################################
set_kubelet(){
for node_ip in ${NODE_IPS[@]}; do
    gecho ">>> 分发 kubelet 二进制文件 ${node_ip}"
    scp kubernetes/server/bin/{kube-proxy,kubelet,mounter} root@${node_ip}:/opt/k8s/bin/
    ssh root@${node_ip} "chmod +x /opt/k8s/bin/*"
done

if [ ! $? -eq 0 ]; then
  recho ">>> 分发文件失败，请检查文件是否存在!"
  exit 1
fi

###############################################################
# 创建 kubelet bootstrap kubeconfig 文件
###############################################################
for node_name in ${NODE_NAMES[@]}; do
    gecho ">>> 创建 kubelet bootstrap kubeconfig 文件${node_name}"
# 创建 token
    export BOOTSTRAP_TOKEN=$(kubeadm token create \
      --description kubelet-bootstrap-token \
      --groups system:bootstrappers:${node_name} \
      --kubeconfig ~/.kube/config)
# 设置集群参数
    kubectl config set-cluster kubernetes \
      --certificate-authority=/opt/k8s/cert/ca.pem \
      --embed-certs=true \
      --server=${KUBE_APISERVER} \
      --kubeconfig=kubelet-bootstrap-${node_name}.kubeconfig
# 设置客户端认证参数
    kubectl config set-credentials kubelet-bootstrap \
      --token=${BOOTSTRAP_TOKEN} \
      --kubeconfig=kubelet-bootstrap-${node_name}.kubeconfig
# 设置上下文参数
    kubectl config set-context default \
      --cluster=kubernetes \
      --user=kubelet-bootstrap \
      --kubeconfig=kubelet-bootstrap-${node_name}.kubeconfig
# 设置默认上下文
    kubectl config use-context default --kubeconfig=kubelet-bootstrap-${node_name}.kubeconfig
  done
	
# 分发 bootstrap kubeconfig 文件到所有 worker 节点
for (( i=0; i < "${#NODE_IPS[@]}"; i++ )); do
    gecho ">>> 分发 bootstrap kubeconfig 文件到 worker 节点 ${NODE_NAMES[i]}"
    scp kubelet-bootstrap-${NODE_NAMES[i]}.kubeconfig root@${NODE_IPS[i]}:/opt/k8s/conf/kubelet-bootstrap.kubeconfig
  done

################################################################
# 分发 kubelet 参数配置文件
################################################################
# 分发 kubelet 配置文件：
for node_ip in ${NODE_IPS[@]}; do 
    gecho ">>> 为各节点创建和分发 kubelet 配置文件 ${node_ip}"
    sed -e "s/##NODE_IP##/${node_ip}/" kubelet-config.yaml.template > kubelet-config-${node_ip}.yaml.template
    scp kubelet-config-${node_ip}.yaml.template root@${node_ip}:/opt/k8s/conf/kubelet-config.yaml
  done

####################################################################
# 创建和分发 kubelet systemd unit 文件 
####################################################################
# 为各节点创建和分发 kubelet systemd unit 文件：
cd /opt/k8s/work
for (( i=0; i < "${#NODE_IPS[@]}"; i++ )); do
    gecho ">>> 为各节点创建和分发 kubelet systemd unit 文件 ${NODE_NAMES[i]}"
    sed -e "s/##NODE_NAME##/${NODE_NAMES[i]}/" kubelet.service.template > kubelet-${NODE_NAMES[i]}.service
    scp kubelet-${NODE_NAMES[i]}.service root@${NODE_IPS[i]}:/etc/systemd/system/kubelet.service
  done

# 启动 kubelet 服务
for node_ip in ${NODE_IPS[@]}; do
    gecho ">>> 启动 kubelet 服务 ${node_ip}"
    ssh root@${node_ip} "mkdir -p ${K8S_DIR}/kubelet/kubelet-plugins/volume/exec/"
    ssh root@${node_ip} "/usr/sbin/swapoff -a"
    ssh root@${node_ip} "systemctl daemon-reload && systemctl enable kubelet && systemctl restart kubelet"
	sleep 5
	
	gecho ">>> 检查服务运行状态 ${node_ip}"
    ssh root@${node_ip} "systemctl status kubelet | grep Active"
  done
}

####################################
# 创建和分发 kube-proxy 的 kubeconfig 文件
####################################
set_kube-proxy(){
for (( i=0; i < "${#NODE_IPS[@]}"; i++ )); do
    gecho ">>> 分发 kubeconfig 文件到 ${NODE_NAMES[i]}"
    scp kube-proxy.kubeconfig root@${NODE_IPS[i]}:/opt/k8s/conf
  done

############################################
# 创建 kube-proxy 配置文件
############################################
# 为各节点创建和分发 kube-proxy 配置文件：
cd /opt/k8s/work
for (( i=0; i < "${#NODE_IPS[@]}"; i++ )); do
    gecho ">>> 为各节点创建和分发 kube-proxy 配置文件：${NODE_NAMES[i]}"
    sed -e "s/##NODE_NAME##/${NODE_NAMES[i]}/" -e "s/##NODE_IP##/${NODE_IPS[i]}/" kube-proxy-config.yaml.template > kube-proxy-config-${NODE_NAMES[i]}.yaml.template
    scp kube-proxy-config-${NODE_NAMES[i]}.yaml.template root@${NODE_IPS[i]}:/opt/k8s/conf/kube-proxy-config.yaml
  done
###################################################
# 创建和分发 kube-proxy systemd unit 文件
###################################################
# 分发 kube-proxy systemd unit 文件：
for (( i=0; i < "${#NODE_IPS[@]}"; i++ )); do
    gecho ">>> 分发 kube-proxy systemd unit 文件 ${NODE_NAME[i]}"
    scp kube-proxy.service root@${NODE_IPS[i]}:/etc/systemd/system/
  done

# 启动 kube-proxy 服务
for node_ip in ${NODE_IPS[@]}; do
    gecho ">>> 启动 kube-proxy 服务 ${node_ip}"
    ssh root@${node_ip} "mkdir -p ${K8S_DIR}/kube-proxy"
    ssh root@${node_ip} "modprobe ip_vs_rr"
    ssh root@${node_ip} "systemctl daemon-reload && systemctl enable kube-proxy && systemctl restart kube-proxy"

# 检查启动结果
    gecho ">>> 检查启动结果 ${node_ip}"
    ssh root@${node_ip} "systemctl status kube-proxy|grep Active"
  done
}

set_calicoctl(){
for node_ip in ${NODE_IPS[@]}; do
    gecho ">>> 为各节点创建和分发 calicoctl 文件 ${node_ip}"
    scp calicoctl root@${node_ip}:/opt/k8s/bin
    ssh root@${node_ip} "grep 'export DATASTORE_TYPE=kubernetes' /etc/profile || echo 'export DATASTORE_TYPE=kubernetes' >> /etc/profile"
    ssh root@${node_ip} "grep 'export KUBECONFIG=~/.kube/config' /etc/profile || echo 'export KUBECONFIG=~/.kube/config' >> /etc/profile"
    ssh root@${node_ip} "source /etc/profile"
  done
}


set_registry(){
for node_ip in ${NODE_IPS[@]}; do
  gecho ">>> 设置 docker registry for ${node_ip}"
  wget http://192.168.10.102/K8s/certs/harbor-ca.crt http://192.168.10.102/K8s/certs/config.json -N
  ssh root@${node_ip} "mkdir -p /etc/docker/certs.d/registry.zhuanche.com /root/.docker"
  scp harbor-ca.crt root@${node_ip}:/etc/docker/certs.d/registry.zhuanche.com
  scp config.json root@${node_ip}:/root/.docker
done
}

case $1 in
containerd)
  set_ca
  set_containerd
  set_kubelet
  set_kube-proxy
	set_calicoctl
  ;;
docker)
  set_ca
  set_docker
  set_kubelet
  set_kube-proxy
	set_calicoctl
	set_registry
	;;
*)
	echo "please run ./01-init-prepare.sh first for new nodes"
  echo "Usage $0 <containerd|docker> [node_ip node_name]"
;;
esac
