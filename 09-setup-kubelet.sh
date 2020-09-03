#!/bin/bash
source ./00environment.sh
cd /opt/k8s/work
##############################################################
# 下载和分发 kubelet 二进制文件
##############################################################
set_kubelet(){
for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do
    gecho ">>> 分发 kubelet 二进制文件 ${node_ip}"
    scp kubernetes/server/bin/{kube-proxy,kubeadm,kubelet,mounter} root@${node_ip}:/opt/k8s/bin/
    ssh root@${node_ip} "chmod +x /opt/k8s/bin/*"
done

if [ ! $? -eq 0 ]; then
  recho "分发文件失败，请检查文件是否存在!"
  exit 
fi
}

###############################################################
# 创建 kubelet bootstrap kubeconfig 文件
###############################################################
kubeconfig_kubelet(){
cd /opt/k8s/work
for node_name in ${NODE_NAMES[@]} ${MASTER_NAMES[@]}; do
    gecho ">>> 创建 kubelet bootstrap kubeconfig 文件 ${node_name}"
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

for (( i=0; i < "${#MASTER_IPS[@]}"; i++ )); do
    gecho ">>> 分发 bootstrap kubeconfig 文件到 worker 节点 ${MASTER_NAMES[i]}"
    scp kubelet-bootstrap-${MASTER_NAMES[i]}.kubeconfig root@${MASTER_IPS[i]}:/opt/k8s/conf/kubelet-bootstrap.kubeconfig
  done
}

#################################################################################################
#                             创建和分发 kubelet 参数配置文件
################################################################################################
# 从 v1.10 开始，部分 kubelet 参数需在配置文件中配置，kubelet --help 会提示：
# DEPRECATED: This parameter should be set via the config file specified by the Kubelet's --config flag
# 创建 kubelet 参数配置文件模板（可配置项参考代码中注释）：
config_kubelet(){
cd /opt/k8s/work
cat > kubelet-config.yaml.template <<EOF
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
address: "##NODE_IP##"
staticPodPath: ""
syncFrequency: 1m
fileCheckFrequency: 20s
httpCheckFrequency: 20s
staticPodURL: ""
port: 10250
readOnlyPort: 0
rotateCertificates: true
serverTLSBootstrap: true
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/opt/k8s/cert/ca.pem"
authorization:
  mode: Webhook
registryPullQPS: 0
registryBurst: 20
eventRecordQPS: 0
eventBurst: 20
enableDebuggingHandlers: true
enableContentionProfiling: true
healthzPort: 10248
healthzBindAddress: "##NODE_IP##"
clusterDomain: "${CLUSTER_DNS_DOMAIN}"
clusterDNS:
  - "${CLUSTER_DNS_SVC_IP}"
nodeStatusUpdateFrequency: 10s
nodeStatusReportFrequency: 1m
imageMinimumGCAge: 2m
imageGCHighThresholdPercent: 85
imageGCLowThresholdPercent: 80
volumeStatsAggPeriod: 1m
kubeletCgroups: ""
systemCgroups: ""
cgroupRoot: ""
cgroupsPerQOS: true
cgroupDriver: cgroupfs
runtimeRequestTimeout: 10m
hairpinMode: promiscuous-bridge
maxPods: 220
podCIDR: "${CLUSTER_CIDR}"
podPidsLimit: -1
resolvConf: /etc/resolv.conf
maxOpenFiles: 1000000
kubeAPIQPS: 1000
kubeAPIBurst: 2000
serializeImagePulls: false
evictionHard:
  memory.available:  "100Mi"
  nodefs.available:  "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"
evictionSoft: {}
enableControllerAttachDetach: true
failSwapOn: true
containerLogMaxSize: 20Mi
containerLogMaxFiles: 10
systemReserved: {}
kubeReserved: {}
systemReservedCgroup: ""
kubeReservedCgroup: ""
enforceNodeAllocatable: ["pods"]
EOF

# 为各节点创建和分发 kubelet 配置文件：
cd /opt/k8s/work
for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do 
    gecho ">>> 为各节点创建和分发 kubelet 配置文件 ${node_ip}"
    sed -e "s/##NODE_IP##/${node_ip}/" kubelet-config.yaml.template > kubelet-config-${node_ip}.yaml.template
    scp kubelet-config-${node_ip}.yaml.template root@${node_ip}:/opt/k8s/conf/kubelet-config.yaml
  done
}

####################################################################
#       创建和分发 kubelet systemd unit 文件 for containerd        #
####################################################################
# 创建 kubelet systemd unit 文件模板：
systemd_kubelet_containerd(){
cd /opt/k8s/work
cat > kubelet.service.template <<EOF
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/GoogleCloudPlatform/kubernetes
After=containerd.service
Requires=containerd.service
[Service]
WorkingDirectory=${K8S_DIR}/kubelet
ExecStart=/opt/k8s/bin/kubelet \\
  --bootstrap-kubeconfig=/opt/k8s/conf/kubelet-bootstrap.kubeconfig \\
  --cert-dir=/opt/k8s/cert \\
  --network-plugin=cni \\
  --cni-conf-dir=/etc/cni/net.d \\
  --container-runtime=remote \\
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\
  --root-dir=${K8S_DIR}/kubelet \\
  --kubeconfig=/opt/k8s/conf/kubelet.kubeconfig \\
  --config=/opt/k8s/conf/kubelet-config.yaml \\
  --hostname-override=##NODE_NAME## \\
  --image-pull-progress-deadline=15m \\
  --volume-plugin-dir=${K8S_DIR}/kubelet/kubelet-plugins/volume/exec/ \\
  --logtostderr=true \\
  --v=2
Restart=always
RestartSec=5
StartLimitInterval=0
[Install]
WantedBy=multi-user.target
EOF

# 为各节点创建和分发 kubelet systemd unit 文件：
cd /opt/k8s/work
for (( i=0; i < "${#NODE_IPS[@]}"; i++ )); do
    gecho ">>> 为各节点创建和分发 kubelet systemd unit 文件 ${node_name}"
    sed -e "s/##NODE_NAME##/${NODE_NAMES[i]}/" kubelet.service.template > kubelet-${NODE_NAMES[i]}.service
    scp kubelet-${NODE_NAMES[i]}.service root@${NODE_IPS[i]}:/etc/systemd/system/kubelet.service
  done

for (( i=0; i < "${#MASTER_IPS[@]}"; i++ )); do
    gecho ">>> 为各节点创建和分发 kubelet systemd unit 文件 ${node_name}"
    sed -e "s/##NODE_NAME##/${MASTER_NAMES[i]}/" kubelet.service.template > kubelet-${MASTER_NAMES[i]}.service
    scp kubelet-${MASTER_NAMES[i]}.service root@${MASTER_IPS[i]}:/etc/systemd/system/kubelet.service
  done 
 
# 启动 kubelet 服务
for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do
    gecho ">>> 启动 kubelet 服务 ${node_ip}"
    ssh root@${node_ip} "mkdir -p ${K8S_DIR}/kubelet/kubelet-plugins/volume/exec/"
    ssh root@${node_ip} "/usr/sbin/swapoff -a"
    ssh root@${node_ip} "systemctl daemon-reload && systemctl enable kubelet && systemctl restart kubelet"
	sleep 5
	
	gecho ">>> 检查服务运行状态 ${node_ip}"
    ssh root@${node_ip} "systemctl status kubelet | grep Active"
  done
}

###########################################################
# 授予 kube-apiserver 访问 kubelet API 的权限
###########################################################
csr_kubelet(){
gecho ">>> 授予 kube-apiserver 访问 kubelet API 的权限..."
kubectl create clusterrolebinding kube-apiserver:kubelet-apis --clusterrole=system:kubelet-api-admin --user kubernetes-master
gecho ">>> 绑定 group system:bootstrappers 和 clusterrole system:node-bootstrapper..."
kubectl create clusterrolebinding kubelet-bootstrap --clusterrole=system:node-bootstrapper --group=system:bootstrappers

# 自动 approve CSR 请求，生成 kubelet client 证书
gecho ">>> 自动 approve CSR 请求，生成 kubelet client 证书..."
cat > csr-crb.yaml <<EOF
 # Approve all CSRs for the group "system:bootstrappers"
 kind: ClusterRoleBinding
 apiVersion: rbac.authorization.k8s.io/v1
 metadata:
   name: auto-approve-csrs-for-group
 subjects:
 - kind: Group
   name: system:bootstrappers
   apiGroup: rbac.authorization.k8s.io
 roleRef:
   kind: ClusterRole
   name: system:certificates.k8s.io:certificatesigningrequests:nodeclient
   apiGroup: rbac.authorization.k8s.io
---
 # To let a node of the group "system:nodes" renew its own credentials
 kind: ClusterRoleBinding
 apiVersion: rbac.authorization.k8s.io/v1
 metadata:
   name: node-client-cert-renewal
 subjects:
 - kind: Group
   name: system:nodes
   apiGroup: rbac.authorization.k8s.io
 roleRef:
   kind: ClusterRole
   name: system:certificates.k8s.io:certificatesigningrequests:selfnodeclient
   apiGroup: rbac.authorization.k8s.io
---
# A ClusterRole which instructs the CSR approver to approve a node requesting a
# serving cert matching its client cert.
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: approve-node-server-renewal-csr
rules:
- apiGroups: ["certificates.k8s.io"]
  resources: ["certificatesigningrequests/selfnodeserver"]
  verbs: ["create"]
---
 # To let a node of the group "system:nodes" renew its own server credentials
 kind: ClusterRoleBinding
 apiVersion: rbac.authorization.k8s.io/v1
 metadata:
   name: node-server-cert-renewal
 subjects:
 - kind: Group
   name: system:nodes
   apiGroup: rbac.authorization.k8s.io
 roleRef:
   kind: ClusterRole
   name: approve-node-server-renewal-csr
   apiGroup: rbac.authorization.k8s.io
EOF

if kubectl apply -f csr-crb.yaml; then
	gecho ">>> 自动 approve CSR 成功..."
else
	recho "自动 approve CSR 失败！"
	exit 1
fi
}

####################################################################
#              创建和分发 kubelet systemd unit 文件 for docker     #
####################################################################
# 创建 kubelet systemd unit 文件模板：
#  --runtime-cgroups=/systemd/system.slice \\
#  --kubelet-cgroups=/systemd/system.slice \\
systemd_kubelet_docker(){
cd /opt/k8s/work
cat > kubelet.service.template <<EOF
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/GoogleCloudPlatform/kubernetes
After=docker.service
Requires=docker.service
[Service]
WorkingDirectory=${K8S_DIR}/kubelet
ExecStart=/opt/k8s/bin/kubelet \\
  --bootstrap-kubeconfig=/opt/k8s/conf/kubelet-bootstrap.kubeconfig \\
  --cert-dir=/opt/k8s/cert \\
  --root-dir=${K8S_DIR}/kubelet \\
  --kubeconfig=/opt/k8s/conf/kubelet.kubeconfig \\
  --config=/opt/k8s/conf/kubelet-config.yaml \\
  --hostname-override=##NODE_NAME## \\
  --network-plugin=cni \\
  --cni-conf-dir=/etc/cni/net.d \\
  --pod-infra-container-image=zhaoqinchang/pause:3.2 \\
  --image-pull-progress-deadline=15m \\
  --volume-plugin-dir=${K8S_DIR}/kubelet/kubelet-plugins/volume/exec/ \\
  --logtostderr=true \\
  --v=2
Restart=always
RestartSec=5
StartLimitInterval=0
[Install]
WantedBy=multi-user.target
EOF

# 为各节点创建和分发 kubelet systemd unit 文件：
cd /opt/k8s/work                                                                                                                                          
for (( i=0; i < "${#NODE_IPS[@]}"; i++ )); do
    gecho ">>> 为各节点创建和分发 kubelet systemd unit 文件 ${NODE_NAMES[i]}"
    sed -e "s/##NODE_NAME##/${NODE_NAMES[i]}/" kubelet.service.template > kubelet-${NODE_NAMES[i]}.service
    scp kubelet-${NODE_NAMES[i]}.service root@${NODE_IPS[i]}:/etc/systemd/system/kubelet.service
  done

for (( i=0; i < "${#MASTER_IPS[@]}"; i++ )); do
    gecho ">>> 为各节点创建和分发 kubelet systemd unit 文件 ${MASTER_NAMES[i]}"
    sed -e "s/##NODE_NAME##/${MASTER_NAMES[i]}/" kubelet.service.template > kubelet-${MASTER_NAMES[i]}.service
    scp kubelet-${MASTER_NAMES[i]}.service root@${MASTER_IPS[i]}:/etc/systemd/system/kubelet.service
  done
  
# 启动 kubelet 服务
for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do
    gecho ">>> 启动 kubelet 服务 ${node_ip}"
    ssh root@${node_ip} "mkdir -p ${K8S_DIR}/kubelet/kubelet-plugins/volume/exec/"
    ssh root@${node_ip} "/usr/sbin/swapoff -a"
    ssh root@${node_ip} "systemctl daemon-reload && systemctl enable kubelet && systemctl restart kubelet"
  sleep 5
  
  gecho ">>> 检查服务运行状态 ${node_ip}"
    ssh root@${node_ip} "systemctl status kubelet | grep Active"
  done
}

# 手动 approve server cert csr
# kubectl get csr | grep Pending | awk '{print $1}' | xargs kubectl certificate approve

case $1 in
containerd)
	set_kubelet
  kubeconfig_kubelet
  config_kubelet
  systemd_kubelet_containerd
  csr_kubelet
	;;
docker)
  set_kubelet
  kubeconfig_kubelet
  config_kubelet
  systemd_kubelet_docker
  csr_kubelet
	;;
*)
	echo "Usage $0 <containerd|docker>"
  ;;
esac

 
