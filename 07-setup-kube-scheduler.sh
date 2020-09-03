#!/bin/bash
source ./00environment.sh

#########################################################################
#                创建 kube-scheduler 证书和私钥
#########################################################################
# 创建证书签名请求：
cert_scheduler(){
cd /opt/k8s/work
cat > kube-scheduler-csr.json <<EOF
{
    "CN": "system:kube-scheduler",
    "hosts": [
      "127.0.0.1",
    ],
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
      {
        "C": "CN",
        "ST": "BeiJing",
        "L": "BeiJing",
        "O": "system:kube-scheduler",
        "OU": "zhuanche"
      }
    ]
}
EOF

# 将IP添加到证书的hosts字段中
for (( i=0; i < "${#MASTER_IPS[@]}"; i++ ))
do
  if [ "${i}" -eq 0 ]; then
    sed -i '4a'"\      \"${MASTER_IPS[i]}\""'' kube-scheduler-csr.json
  else
    sed -i '4a'"\      \"${MASTER_IPS[i]}\","'' kube-scheduler-csr.json
  fi
done   

# 生成证书和私钥：
gecho ">>> 生成证书和私钥..."
cfssl gencert -ca=/opt/k8s/work/ca.pem \
  -ca-key=/opt/k8s/work/ca-key.pem \
  -config=/opt/k8s/work/ca-config.json \
  -profile=kubernetes kube-scheduler-csr.json | cfssljson -bare kube-scheduler

if [ $? -eq 0 ]; then
  gecho ">>> 证书生成成功!"
else
  recho ">>> 证书生成失败！请检查原因"
  exit 1
fi

# 将生成的证书和私钥分发到所有 master 节点：
for node_ip in ${MASTER_IPS[@]}
  do
    echo ">>> ${node_ip}"
    scp kube-scheduler*.pem root@${node_ip}:/opt/k8s/cert/
  done
}

############################################################
#              创建和分发 kubeconfig 文件
############################################################
# kube-scheduler 使用 kubeconfig 文件访问 apiserver，该文件提供了 apiserver 地址、嵌入的 CA 证书和 kube-scheduler 证书：
kubeconfig_scheduler(){
gecho ">>> 创建kubeconfig文件..."
kubectl config set-cluster kubernetes \
  --certificate-authority=/opt/k8s/work/ca.pem \
  --embed-certs=true \
  --server="https://##NODE_IP##:6443" \
  --kubeconfig=kube-scheduler.kubeconfig
kubectl config set-credentials system:kube-scheduler \
  --client-certificate=kube-scheduler.pem \
  --client-key=kube-scheduler-key.pem \
  --embed-certs=true \
  --kubeconfig=kube-scheduler.kubeconfig
kubectl config set-context system:kube-scheduler \
  --cluster=kubernetes \
  --user=system:kube-scheduler \
  --kubeconfig=kube-scheduler.kubeconfig
kubectl config use-context system:kube-scheduler --kubeconfig=kube-scheduler.kubeconfig

# 分发 kubeconfig 到所有 master 节点：
for node_ip in ${MASTER_IPS[@]}; do
    gecho ">>> 分发 kubeconfig 到 master 节点: ${node_ip}"
    sed -e "s/##NODE_IP##/${node_ip}/" kube-scheduler.kubeconfig > kube-scheduler-${node_ip}.kubeconfig
    scp kube-scheduler-${node_ip}.kubeconfig root@${node_ip}:/opt/k8s/conf/kube-scheduler.kubeconfig
  done
}

##############################################################
#          创建 kube-scheduler 配置文件
##############################################################
config_scheduler(){
gecho "创建 kube-scheduler 配置文件..."
cat >kube-scheduler.yaml.template <<EOF
apiVersion: kubescheduler.config.k8s.io/v1alpha2
kind: KubeSchedulerConfiguration
bindTimeoutSeconds: 600
clientConnection:
  burst: 200
  kubeconfig: "/opt/k8s/conf/kube-scheduler.kubeconfig"
  qps: 100
enableContentionProfiling: false
enableProfiling: true
leaderElection:
  leaderElect: true
EOF

# 替换模板文件中的变量：
for (( i=0; i < ${#MASTER_IPS[@]}; i++ ));  do
    gecho ">>> 修改模板文件中的变量 for ${MASTER_IPS[i]} "
    sed -e "s/##NODE_NAME##/${MASTER_NAMES[i]}/" -e "s/##NODE_IP##/${MASTER_IPS[i]}/" kube-scheduler.yaml.template > kube-scheduler-${MASTER_IPS[i]}.yaml
  done

# 分发 kube-scheduler 配置文件到所有 master 节点：
for node_ip in ${MASTER_IPS[@]}
  do
    gecho ">>> 分发 kube-scheduler 配置文件到 master 节点 ${node_ip}"
    scp kube-scheduler-${node_ip}.yaml root@${node_ip}:/opt/k8s/conf/kube-scheduler.yaml
  done
}

###################################################################
#             创建 kube-scheduler systemd unit 模板文件
###################################################################
systemd_scheduler(){
cat > kube-scheduler.service.template <<EOF
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/GoogleCloudPlatform/kubernetes
[Service]
WorkingDirectory=${K8S_DIR}/kube-scheduler
ExecStart=/opt/k8s/bin/kube-scheduler \\
  --config=/opt/k8s/conf/kube-scheduler.yaml \\
  --bind-address=##NODE_IP## \\
  --secure-port=10259 \\
#  --port=0 \\
  --tls-cert-file=/opt/k8s/cert/kube-scheduler.pem \\
  --tls-private-key-file=/opt/k8s/cert/kube-scheduler-key.pem \\
  --authentication-kubeconfig=/opt/k8s/conf/kube-scheduler.kubeconfig \\
  --client-ca-file=/opt/k8s/cert/ca.pem \\
  --requestheader-allowed-names= \\
  --requestheader-client-ca-file=/opt/k8s/cert/ca.pem \\
  --requestheader-extra-headers-prefix="X-Remote-Extra-" \\
  --requestheader-group-headers=X-Remote-Group \\
  --requestheader-username-headers=X-Remote-User \\
  --authorization-kubeconfig=/opt/k8s/conf/kube-scheduler.kubeconfig \\
  --logtostderr=true \\
  --v=2
Restart=always
RestartSec=5
StartLimitInterval=0
[Install]
WantedBy=multi-user.target
EOF

# 为各节点创建和分发 kube-scheduler systemd unit 文件
# 替换模板文件中的变量，为各节点创建 systemd unit 文件：
for (( i=0; i < ${#MASTER_IPS[@]}; i++ )); do
    gecho ">>> 替换模板文件中的变量 for ${MASTER_IPS[i]}"
    sed -e "s/##NODE_NAME##/${MASTER_NAMES[i]}/" -e "s/##NODE_IP##/${MASTER_IPS[i]}/" kube-scheduler.service.template > kube-scheduler-${MASTER_IPS[i]}.service 
  done

# 分发|启动|检查 systemd unit 在所有 master 节点：
for node_ip in ${MASTER_IPS[@]}; do
    gecho ">>> 分发 systemd unit 文件到 master 节点 ${node_ip}"
    scp kube-scheduler-${node_ip}.service root@${node_ip}:/etc/systemd/system/kube-scheduler.service

    gecho ">>> 启动 kube-scheduler 服务 ${node_ip}"
    ssh root@${node_ip} "mkdir -p ${K8S_DIR}/kube-scheduler"
    ssh root@${node_ip} "systemctl daemon-reload && systemctl enable kube-scheduler && systemctl restart kube-scheduler"
	sleep 5
	
    gecho ">>> 检查服务运行状态 ${node_ip}"
    ssh root@${node_ip} "systemctl status kube-scheduler|grep Active"
  done
}

cert_scheduler
kubeconfig_scheduler
config_scheduler
systemd_scheduler
