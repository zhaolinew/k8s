#!/bin/bash
source ./00environment.sh

#########################################################
#下载master的文件并分发到master上
#########################################################
cd /opt/k8s/work
get_kubernetes(){
# 下载和分发 master 二进制文件
gecho ">>> 下载和分发二进制文件..."
if [ -e "${CUBERNETES_SERVER}" ]; then
	gecho ">>> 文件已经存在..."
else
  wget -N ${GET_CUBERNETES_SERVER}
  #wget https://dl.k8s.io/v1.18.5/kubernetes-server-linux-amd64.tar.gz 
fi

if [ ! $? -eq 0 ]; then
  recho ">>> 下载${CUBERNETES_SERVER}失败，请检查链接或网络!"
  exit 1
fi

if [ ! -e kubernetes/server/bin/kube-apiserver ]; then
  gecho ">>> 正在解压二进制文件..."
  tar -xf  ${CUBERNETES_SERVER}
fi

# 将二进制文件拷贝到所有 master 节点：
cd /opt/k8s/work
for node_ip in ${MASTER_IPS[@]}; do
  gecho ">>> 将二进制文件拷贝到 master 节点${node_ip}"
  scp kubernetes/server/bin/{apiextensions-apiserver,kube-apiserver,kube-controller-manager,kube-scheduler} root@${node_ip}:/opt/k8s/bin/
  ssh root@${node_ip} "chmod +x /opt/k8s/bin/*"
done
}


#######################################################
#创建 kubernetes-master 证书和私钥
######################################################
cert_api(){
cat > kubernetes-csr.json <<EOF
{
  "CN": "kubernetes-master",
  "hosts": [
    "127.0.0.1",
    "${CLUSTER_KUBERNETES_SVC_IP}",
    "kubernetes",
    "kubernetes.default",
    "kubernetes.default.svc",
    "kubernetes.default.svc.cluster",
    "kubernetes.default.svc.cluster.local.",
    "kubernetes.default.svc.${CLUSTER_DNS_DOMAIN}.",
    "${KUBE_APISERVER_DNS_NAME}"
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
      "O": "k8s",
      "OU": "${CSR_OU}"
    }
  ]
}
EOF

# 将IP地址插入到证书文件中的hosts
for (( i=0; i < "${#MASTER_IPS[@]}"; i++ ))
do
    sed -i '4a'"\    \"${MASTER_IPS[i]}\","'' kubernetes-csr.json
done                      

# 生成证书和私钥：
gecho ">>> 生成证书和私钥..."
cfssl gencert -ca=/opt/k8s/work/ca.pem \
  -ca-key=/opt/k8s/work/ca-key.pem \
  -config=/opt/k8s/work/ca-config.json \
  -profile=kubernetes kubernetes-csr.json | cfssljson -bare kubernetes

if [ $? -eq 0 ]; then
  gecho ">>> 证书生成成功!"
else
  recho ">>> 证书生成失败！请检查原因"
  exit 1
fi

# 将生成的证书和私钥文件拷贝到所有 master 节点：
cd /opt/k8s/work
for node_ip in ${MASTER_IPS[@]}
  do
    gecho ">>> 分发生成的证书和私钥到到 ${node_ip}"
    ssh root@${node_ip} "mkdir -p /opt/k8s/cert"
    scp kubernetes*.pem root@${node_ip}:/opt/k8s/cert/
  done
}


##################################################
#创建加密配置文件
###############################################
encry_api(){
cd /opt/k8s/work
cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
# 将加密配置文件拷贝到 master 节点的 /opt/k8s 目录下：
cd /opt/k8s/work
for node_ip in ${MASTER_IPS[@]}
  do
    gecho ">>> 将加密配置文件拷贝到 master 节点的 ${node_ip} /opt/k8s/conf 目录下"
    scp encryption-config.yaml root@${node_ip}:/opt/k8s/conf
  done
}

#################################################################
#创建审计策略文件
#################################################################
audit_api(){
cd /opt/k8s/work
# 注：此审计文件版本不同可能接受参数不同，所以要查官方文档，参考文档：
# https://kubernetes.io/zh/docs/tasks/debug-application-cluster/audit/
# GCE 使用的审计配置文件
# https://github.com/kubernetes/kubernetes/blob/master/cluster/gce/gci/configure-helper.sh#L735

cat <<EOF >audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # The following requests were manually identified as high-volume and low-risk,
  # so drop them.
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: "" # core
        resources: ["endpoints", "services", "services/status"]
  - level: None
    # Ingress controller reads 'configmaps/ingress-uid' through the unsecured port.
    # TODO(#46983): Change this to the ingress controller service account.
    users: ["system:unsecured"]
    namespaces: ["kube-system"]
    verbs: ["get"]
    resources:
      - group: "" # core
        resources: ["configmaps"]
  - level: None
    users: ["kubelet"] # legacy kubelet identity
    verbs: ["get"]
    resources:
      - group: "" # core
        resources: ["nodes", "nodes/status"]
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get"]
    resources:
      - group: "" # core
        resources: ["nodes", "nodes/status"]
  - level: None
    users:
      - system:kube-controller-manager
      - system:kube-scheduler
      - system:serviceaccount:kube-system:endpoint-controller
    verbs: ["get", "update"]
    namespaces: ["kube-system"]
    resources:
      - group: "" # core
        resources: ["endpoints"]
  - level: None
    users: ["system:apiserver"]
    verbs: ["get"]
    resources:
      - group: "" # core
        resources: ["namespaces", "namespaces/status", "namespaces/finalize"]
  - level: None
    users: ["cluster-autoscaler"]
    verbs: ["get", "update"]
    namespaces: ["kube-system"]
    resources:
      - group: "" # core
        resources: ["configmaps", "endpoints"]
  # Don't log HPA fetching metrics.
  - level: None
    users:
      - system:kube-controller-manager
    verbs: ["get", "list"]
    resources:
      - group: "metrics.k8s.io"
  # Don't log these read-only URLs.
  - level: None
    nonResourceURLs:
      - /healthz*
      - /version
      - /swagger*
  # Don't log events requests.
  - level: None
    resources:
      - group: "" # core
        resources: ["events"]
  # node and pod status calls from nodes are high-volume and can be large, don't log responses for expected updates from nodes
  - level: Request
    users: ["kubelet", "system:node-problem-detector", "system:serviceaccount:kube-system:node-problem-detector"]
    verbs: ["update","patch"]
    resources:
      - group: "" # core
        resources: ["nodes/status", "pods/status"]
    omitStages:
      - "RequestReceived"
  - level: Request
    userGroups: ["system:nodes"]
    verbs: ["update","patch"]
    resources:
      - group: "" # core
        resources: ["nodes/status", "pods/status"]
    omitStages:
      - "RequestReceived"
  # deletecollection calls can be large, don't log responses for expected namespace deletions
  - level: Request
    users: ["system:serviceaccount:kube-system:namespace-controller"]
    verbs: ["deletecollection"]
    omitStages:
      - "RequestReceived"
  # Secrets, ConfigMaps, and TokenReviews can contain sensitive & binary data,
  # so only log at the Metadata level.
  - level: Metadata
    resources:
      - group: "" # core
        resources: ["secrets", "configmaps"]
      - group: authentication.k8s.io
        resources: ["tokenreviews"]
    omitStages:
      - "RequestReceived"
  # Get repsonses can be large; skip them.
  - level: Request
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
      - group: "admissionregistration.k8s.io"
      - group: "apiextensions.k8s.io"
      - group: "apiregistration.k8s.io"
      - group: "apps"
      - group: "authentication.k8s.io"
      - group: "authorization.k8s.io"
      - group: "autoscaling"
      - group: "batch"
      - group: "certificates.k8s.io"
      - group: "extensions"
      - group: "metrics.k8s.io"
      - group: "networking.k8s.io"
      - group: "node.k8s.io"
      - group: "policy"
      - group: "rbac.authorization.k8s.io"
      - group: "scheduling.k8s.io"
      - group: "settings.k8s.io"
      - group: "storage.k8s.io"
    omitStages:
      - "RequestReceived"
  # Default level for known APIs
  - level: RequestResponse
    resources: 
      - group: "" 
      - group: "admissionregistration.k8s.io"
      - group: "apiextensions.k8s.io"
      - group: "apiregistration.k8s.io"
      - group: "apps"
      - group: "authentication.k8s.io"
      - group: "authorization.k8s.io"
      - group: "autoscaling"
      - group: "batch"
      - group: "certificates.k8s.io"
      - group: "extensions"
      - group: "metrics.k8s.io"
      - group: "networking.k8s.io"
      - group: "node.k8s.io"
      - group: "policy"
      - group: "rbac.authorization.k8s.io"
      - group: "scheduling.k8s.io"
      - group: "settings.k8s.io"
      - group: "storage.k8s.io"
    omitStages:
      - "RequestReceived"
  # Default level for all other requests.
  - level: Metadata
    omitStages:
      - "RequestReceived"
EOF

# 分发审计策略文件：
cd /opt/k8s/work
for node_ip in ${MASTER_IPS[@]};  do
    gecho ">>> 分发审计策略文件到 ${node_ip}"
    scp audit-policy.yaml root@${node_ip}:/opt/k8s/conf/audit-policy.yaml
done
}


##################################################################
# 创建后续访问 metrics-server 或 kube-prometheus 使用的证书
####################################################################
# 创建证书签名请求:
proxy_cert_api(){
cd /opt/k8s/work
cat > proxy-client-csr.json <<EOF
{
  "CN": "aggregator",
  "hosts": [],
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

# 生成证书和私钥：
gecho ">>> 创建后续访问 metrics-server 或 kube-prometheus 使用的证书..."
cfssl gencert -ca=/opt/k8s/cert/ca.pem \
  -ca-key=/opt/k8s/cert/ca-key.pem  \
  -config=/opt/k8s/cert/ca-config.json  \
  -profile=kubernetes proxy-client-csr.json | cfssljson -bare proxy-client

if [ $? -eq 0 ]; then
  gecho ">>> 证书生成成功!"
else
  recho ">>> 证书生成失败！请检查原因"
  exit 1
fi

# 将生成的 proxy 证书和私钥文件拷贝到所有 master 节点：
for node_ip in ${MASTER_IPS[@]}; do
    gecho ">>> 将生成的 proxy 证书和私钥文件拷贝到 master 节点 ${node_ip}"
    scp proxy-client*.pem root@${node_ip}:/opt/k8s/cert/
done
}

#########################################################################################
#创建和分发 kube-apiserver systemd unit 模板文件
########################################################################################
systemd_api(){
cd /opt/k8s/work
cat > kube-apiserver.service.template <<EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/GoogleCloudPlatform/kubernetes
After=network.target
[Service]
WorkingDirectory=${K8S_DIR}/kube-apiserver
ExecStart=/opt/k8s/bin/kube-apiserver \\
  --advertise-address=##NODE_IP## \\
  --default-not-ready-toleration-seconds=360 \\
  --default-unreachable-toleration-seconds=360 \\
  --feature-gates=DynamicAuditing=true \\
  --max-mutating-requests-inflight=2000 \\
  --max-requests-inflight=4000 \\
  --default-watch-cache-size=200 \\
  --delete-collection-workers=2 \\
  --encryption-provider-config=/opt/k8s/conf/encryption-config.yaml \\
  --etcd-cafile=/opt/k8s/cert/ca.pem \\
  --etcd-certfile=/opt/k8s/cert/kubernetes.pem \\
  --etcd-keyfile=/opt/k8s/cert/kubernetes-key.pem \\
  --etcd-servers=${ETCD_ENDPOINTS} \\
  --bind-address=##NODE_IP## \\
  --secure-port=6443 \\
  --tls-cert-file=/opt/k8s/cert/kubernetes.pem \\
  --tls-private-key-file=/opt/k8s/cert/kubernetes-key.pem \\
  --insecure-port=0 \\
  --audit-dynamic-configuration \\
  --audit-log-maxage=15 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-truncate-enabled \\
  --audit-log-path=${K8S_DIR}/kube-apiserver/audit.log \\
  --audit-policy-file=/opt/k8s/conf/audit-policy.yaml \\
  --profiling \\
  --anonymous-auth=false \\
  --client-ca-file=/opt/k8s/cert/ca.pem \\
  --enable-bootstrap-token-auth \\
  --requestheader-allowed-names="aggregator" \\
  --requestheader-client-ca-file=/opt/k8s/cert/ca.pem \\
  --requestheader-extra-headers-prefix="X-Remote-Extra-" \\
  --requestheader-group-headers=X-Remote-Group \\
  --requestheader-username-headers=X-Remote-User \\
  --service-account-key-file=/opt/k8s/cert/ca.pem \\
  --authorization-mode=Node,RBAC \\
  --runtime-config=api/all=true \\
  --enable-admission-plugins=NodeRestriction \\
  --allow-privileged=true \\
  --apiserver-count=2 \\
  --event-ttl=168h \\
  --kubelet-certificate-authority=/opt/k8s/cert/ca.pem \\
  --kubelet-client-certificate=/opt/k8s/cert/kubernetes.pem \\
  --kubelet-client-key=/opt/k8s/cert/kubernetes-key.pem \\
  --kubelet-https=true \\
  --kubelet-timeout=10s \\
  --proxy-client-cert-file=/opt/k8s/cert/proxy-client.pem \\
  --proxy-client-key-file=/opt/k8s/cert/proxy-client-key.pem \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --service-node-port-range=${NODE_PORT_RANGE} \\
  --logtostderr=true \\
  --v=2
Restart=on-failure
RestartSec=10
Type=notify
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF

#为各节点创建和分发 kube-apiserver systemd unit 文件
#替换模板文件中的变量，为各节点生成 systemd unit 文件：
cd /opt/k8s/work
for (( i=0; i < "${#MASTER_IPS[@]}"; i++ )); do
    gecho ">>> 替换模板文件中的变量，为 ${MASTER_IPS[i]} 节点生成 systemd unit 文件..."
    sed -e "s/##NODE_NAME##/${MASTER_NAMES[i]}/" -e "s/##NODE_IP##/${MASTER_IPS[i]}/" kube-apiserver.service.template > kube-apiserver-${MASTER_IPS[i]}.service 
done
	
# 分发|启动|检查生成的 systemd unit 文件：
cd /opt/k8s/work
for node_ip in ${MASTER_IPS[@]}; do
    gecho ">>> 分发生成的 systemd unit 文件 ${node_ip}"
    scp kube-apiserver-${node_ip}.service root@${node_ip}:/etc/systemd/system/kube-apiserver.service

    gecho ">>> 启动 kube-apiserver 服务 ${node_ip}"
    ssh root@${node_ip} "mkdir -p ${K8S_DIR}/kube-apiserver"
    ssh root@${node_ip} "systemctl daemon-reload && systemctl enable kube-apiserver && systemctl restart kube-apiserver"
	sleep 5
	
    gecho ">>> 检查 kube-apiserver 运行状态 ${node_ip}"
    ssh root@${node_ip} "systemctl status kube-apiserver |grep 'Active:'"
done
}

get_kubernetes
cert_api
encry_api
audit_api
proxy_cert_api
systemd_api
