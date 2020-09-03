#!/bin/bash
source ./00environment.sh

#############################
#   创建 kube-proxy 证书
#############################
# 创建证书签名请求：
cert_kube-proxy(){
cd /opt/k8s/work
cat > kube-proxy-csr.json <<EOF
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "BeiJing",
      "L": "BeiJing",
      "O": "k8s",
      "OU": "${CSR_OU}"
    }
  ]
}
EOF
	
gecho ">>> 生成证书和私钥..."
cd /opt/k8s/work
cfssl gencert -ca=/opt/k8s/work/ca.pem \
  -ca-key=/opt/k8s/work/ca-key.pem \
  -config=/opt/k8s/work/ca-config.json \
  -profile=kubernetes  kube-proxy-csr.json | cfssljson -bare kube-proxy
}

####################################
# 创建和分发 kubeconfig 文件
####################################
gecho ">>> 创建kubeconfig文件..."
kubeconfig_kube-proxy(){
cd /opt/k8s/work
kubectl config set-cluster kubernetes \
  --certificate-authority=/opt/k8s/work/ca.pem \
  --embed-certs=true \
  --server=${KUBE_APISERVER} \
  --kubeconfig=kube-proxy.kubeconfig
kubectl config set-credentials kube-proxy \
  --client-certificate=kube-proxy.pem \
  --client-key=kube-proxy-key.pem \
  --embed-certs=true \
  --kubeconfig=kube-proxy.kubeconfig
kubectl config set-context default \
  --cluster=kubernetes \
  --user=kube-proxy \
  --kubeconfig=kube-proxy.kubeconfig
kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig

# 分发 kubeconfig 文件：
cd /opt/k8s/work
#for node_name in ${NODE_NAMES[@]} ${MASTER_NAMES[@]}; do
#    gecho ">>> 分发 kubeconfig 文件到 ${node_name}"
#    scp kube-proxy.kubeconfig root@${node_name}:/opt/k8s/conf
#  done

for (( i=0; i < "${#NODE_IPS[@]}"; i++ )); do
    gecho ">>> 分发 kubeconfig 文件到 ${NODE_NAMES[i]}"
    scp kube-proxy.kubeconfig root@${NODE_IPS[i]}:/opt/k8s/conf
  done

for (( i=0; i < "${#MASTER_IPS[@]}"; i++ )); do     
    gecho ">>> 分发 kubeconfig 文件到 ${MASTER_NAMES[i]}"
    scp kube-proxy.kubeconfig root@${MASTER_IPS[i]}:/opt/k8s/conf
  done

}

############################################
# 创建 kube-proxy 配置文件
############################################
# 从 v1.10 开始，kube-proxy 部分参数可以配置文件中配置。可以使用 --write-config-to 选项生成该配置文件，或者参考 源代码的注释。
# 创建 kube-proxy config 文件模板：

config_kube-proxy(){
cd /opt/k8s/work
cat > kube-proxy-config.yaml.template <<EOF
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  burst: 200
  kubeconfig: "/opt/k8s/conf/kube-proxy.kubeconfig"
  qps: 100
bindAddress: ##NODE_IP##
healthzBindAddress: ##NODE_IP##:10256
metricsBindAddress: ##NODE_IP##:10249
enableProfiling: true
clusterCIDR: ${CLUSTER_CIDR}
hostnameOverride: ##NODE_NAME##
mode: "ipvs"
portRange: ""
iptables:
  masqueradeAll: false
ipvs:
  scheduler: rr
  excludeCIDRs: []
EOF

# 为各节点创建和分发 kube-proxy 配置文件：
cd /opt/k8s/work
for (( i=0; i < "${#NODE_IPS[@]}"; i++ )); do
    gecho ">>> 为各节点创建和分发 kube-proxy 配置文件：${NODE_NAMES[i]}"
    sed -e "s/##NODE_NAME##/${NODE_NAMES[i]}/" -e "s/##NODE_IP##/${NODE_IPS[i]}/" kube-proxy-config.yaml.template > kube-proxy-config-${NODE_NAMES[i]}.yaml.template
    scp kube-proxy-config-${NODE_NAMES[i]}.yaml.template root@${NODE_IPS[i]}:/opt/k8s/conf/kube-proxy-config.yaml
  done

for (( i=0; i < "${#MASTER_IPS[@]}"; i++ )); do
    gecho ">>> 为各节点创建和分发 kube-proxy 配置文件：${MASTER_NAMES[i]}"
    sed -e "s/##NODE_NAME##/${MASTER_NAMES[i]}/" -e "s/##NODE_IP##/${MASTER_IPS[i]}/" kube-proxy-config.yaml.template > kube-proxy-config-${MASTER_NAMES[i]}.yaml.template
    scp kube-proxy-config-${MASTER_NAMES[i]}.yaml.template root@${MASTER_IPS[i]}:/opt/k8s/conf/kube-proxy-config.yaml
  done

}

###################################################
# 创建和分发 kube-proxy systemd unit 文件
###################################################

systemd_kube-proxy(){
cd /opt/k8s/work
cat > kube-proxy.service <<EOF
[Unit]
Description=Kubernetes Kube-Proxy Server
Documentation=https://github.com/GoogleCloudPlatform/kubernetes
After=network.target
[Service]
WorkingDirectory=${K8S_DIR}/kube-proxy
ExecStart=/opt/k8s/bin/kube-proxy \\
  --config=/opt/k8s/conf/kube-proxy-config.yaml \\
  --logtostderr=true \\
  --v=2
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF

# 分发 kube-proxy systemd unit 文件：
cd /opt/k8s/work
#for node_name in ${NODE_NAMES[@]} ${MASTER_NAMES[@]}; do 
#    gecho ">>> 分发 kube-proxy systemd unit 文件 ${node_name}"
#    scp kube-proxy.service root@${node_name}:/etc/systemd/system/
#done

for (( i=0; i < "${#NODE_IPS[@]}"; i++ )); do
    gecho ">>> 分发 kube-proxy systemd unit 文件 ${NODE_NAMES[i]}"
    scp kube-proxy.service root@${NODE_IPS[i]}:/etc/systemd/system/
  done

for (( i=0; i < "${#MASTER_IPS[@]}"; i++ )); do
    gecho ">>> 分发 kube-proxy systemd unit 文件 ${MASTER_NAMES[i]}"
    scp kube-proxy.service root@${MASTER_IPS[i]}:/etc/systemd/system/
  done

# 启动 kube-proxy 服务
cd /opt/k8s/work
for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do
    gecho ">>> 启动 kube-proxy 服务 ${node_ip}"
    ssh root@${node_ip} "mkdir -p ${K8S_DIR}/kube-proxy"
    ssh root@${node_ip} "modprobe ip_vs_rr"
    ssh root@${node_ip} "systemctl daemon-reload && systemctl enable kube-proxy && systemctl restart kube-proxy"
done
sleep 5

for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do	
    gecho ">>> 检查启动结果 ${node_ip}"
    ssh root@${node_ip} "systemctl status kube-proxy|grep Active"
done
}

cert_kube-proxy
kubeconfig_kube-proxy
config_kube-proxy
systemd_kube-proxy

