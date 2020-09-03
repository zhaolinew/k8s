#!/bin/bash
source ./00environment.sh

###########################################
# 创建 kube-controller-manager 证书和私钥
###########################################
# 创建证书签名请求：
cert_controller(){
cd /opt/k8s/work
cat > kube-controller-manager-csr.json <<EOF
{
    "CN": "system:kube-controller-manager",
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "hosts": [
      "127.0.0.1",
    ],
    "names": [
      {
        "C": "CN",
        "ST": "BeiJing",
        "L": "BeiJing",
        "O": "system:kube-controller-manager",
        "OU": "${CSR_OU}"
      }
    ]
}
EOF

# 将IP添加到证书的hosts字段中
for (( i=0; i < "${#MASTER_IPS[@]}"; i++ ))
do
  if [ "${i}" -eq 0 ]; then
    sed -i '8a'"\      \"${MASTER_IPS[i]}\""'' kube-controller-manager-csr.json
  else
    sed -i '8a'"\      \"${MASTER_IPS[i]}\","'' kube-controller-manager-csr.json
  fi
done
       
# 生成证书和私钥：
gecho ">>> 生成证书和私钥..."
cfssl gencert -ca=/opt/k8s/work/ca.pem \
  -ca-key=/opt/k8s/work/ca-key.pem \
  -config=/opt/k8s/work/ca-config.json \
  -profile=kubernetes kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager

if [ $? -eq 0 ]; then
  gecho ">>> 证书生成成功!"
else
  recho ">>> 证书生成失败！请检查原因"
  exit 1
fi

# 将生成的证书和私钥分发到所有 master 节点：
for node_ip in ${MASTER_IPS[@]}; do
    gecho ">>> 将生成的证书和私钥分发到 master 节点${node_ip}"
    scp kube-controller-manager*.pem root@${node_ip}:/opt/k8s/cert/
done
}

#############################################
# 创建和分发 kubeconfig 文件
#############################################
# kube-controller-manager 使用 kubeconfig 文件访问 apiserver，该文件提供了 apiserver 地址、嵌入的 CA 证书和 kube-controller-manager 证书等信息：
kubeconfig_controller(){
gecho ">>> 创建kubeconfig文件..."
cd /opt/k8s/work
kubectl config set-cluster kubernetes \
  --certificate-authority=/opt/k8s/work/ca.pem \
  --embed-certs=true \
  --server="https://##NODE_IP##:6443" \
  --kubeconfig=kube-controller-manager.kubeconfig
kubectl config set-credentials system:kube-controller-manager \
  --client-certificate=kube-controller-manager.pem \
  --client-key=kube-controller-manager-key.pem \
  --embed-certs=true \
  --kubeconfig=kube-controller-manager.kubeconfig
kubectl config set-context system:kube-controller-manager \
  --cluster=kubernetes \
  --user=system:kube-controller-manager \
  --kubeconfig=kube-controller-manager.kubeconfig
kubectl config use-context system:kube-controller-manager --kubeconfig=kube-controller-manager.kubeconfig

# 分发 kubeconfig 到所有 master 节点：
for node_ip in ${MASTER_IPS[@]}
  do
    gecho ">>> 分发 kubeconfig 到 master 节点: ${node_ip}"
    sed -e "s/##NODE_IP##/${node_ip}/" kube-controller-manager.kubeconfig > kube-controller-manager-${node_ip}.kubeconfig
    scp kube-controller-manager-${node_ip}.kubeconfig root@${node_ip}:/opt/k8s/conf/kube-controller-manager.kubeconfig
  done
}

#######################################################
#创建 kube-controller-manager systemd unit 模板文件
#######################################################
systemd_controller(){
cd /opt/k8s/work
cat > kube-controller-manager.service.template <<EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/GoogleCloudPlatform/kubernetes
[Service]
WorkingDirectory=${K8S_DIR}/kube-controller-manager
ExecStart=/opt/k8s/bin/kube-controller-manager \\
  --profiling \\
  --cluster-name=kubernetes \\
  --controllers=*,bootstrapsigner,tokencleaner \\
  --kube-api-qps=1000 \\
  --kube-api-burst=2000 \\
  --leader-elect \\
  --use-service-account-credentials\\
  --concurrent-service-syncs=2 \\
  --bind-address=##NODE_IP## \\
  --secure-port=10257 \\
  --tls-cert-file=/opt/k8s/cert/kube-controller-manager.pem \\
  --tls-private-key-file=/opt/k8s/cert/kube-controller-manager-key.pem \\
  --authentication-kubeconfig=/opt/k8s/conf/kube-controller-manager.kubeconfig \\
  --client-ca-file=/opt/k8s/cert/ca.pem \\
  --requestheader-allowed-names="aggregator" \\
  --requestheader-client-ca-file=/opt/k8s/cert/ca.pem \\
  --requestheader-extra-headers-prefix="X-Remote-Extra-" \\
  --requestheader-group-headers=X-Remote-Group \\
  --requestheader-username-headers=X-Remote-User \\
  --authorization-kubeconfig=/opt/k8s/conf/kube-controller-manager.kubeconfig \\
  --cluster-signing-cert-file=/opt/k8s/cert/ca.pem \\
  --cluster-signing-key-file=/opt/k8s/cert/ca-key.pem \\
  --experimental-cluster-signing-duration=876000h \\
  --horizontal-pod-autoscaler-sync-period=10s \\
  --concurrent-deployment-syncs=10 \\
  --concurrent-gc-syncs=30 \\
  --node-cidr-mask-size=24 \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --pod-eviction-timeout=6m \\
  --terminated-pod-gc-threshold=10000 \\
  --root-ca-file=/opt/k8s/cert/ca.pem \\
  --service-account-private-key-file=/opt/k8s/cert/ca-key.pem \\
  --kubeconfig=/opt/k8s/conf/kube-controller-manager.kubeconfig \\
  --logtostderr=true \\
  --v=2
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

# 为各节点创建和分发 kube-controller-mananger systemd unit 文件
# 替换模板文件中的变量，为各节点创建 systemd unit 文件：
for (( i=0; i < ${#MASTER_IPS[@]}; i++ ))
  do
    gecho ">>> 替换模板文件中的变量，为节点 ${MASTER_IPS[i]} 创建 systemd unit 文件"
    sed -e "s/##NODE_NAME##/${MASTER_NAMES[i]}/" -e "s/##NODE_IP##/${MASTER_IPS[i]}/" kube-controller-manager.service.template > kube-controller-manager-${MASTER_IPS[i]}.service 
  done

# 分发|启动|检查 kube-controller-manager 服务：
for node_ip in ${MASTER_IPS[@]}
  do
    gecho ">>> 分发到 master 节点 ${node_ip}"
    scp kube-controller-manager-${node_ip}.service root@${node_ip}:/etc/systemd/system/kube-controller-manager.service

    gecho ">>> 启动 kube-controller-manager 服务 ${node_ip} ..."
    ssh root@${node_ip} "mkdir -p ${K8S_DIR}/kube-controller-manager"
    ssh root@${node_ip} "systemctl daemon-reload && systemctl enable kube-controller-manager && systemctl restart kube-controller-manager"
	sleep 5
	
    gecho ">>> 检查服务运行状态 ${node_ip}"
    ssh root@${node_ip} "systemctl status kube-controller-manager|grep Active"
  done
}

cert_controller
kubeconfig_controller
systemd_controller

