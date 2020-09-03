#!/bin/bash
source ./00environment.sh

#########################################################################
# 分发kubectl、创建证书、创建和分发cubeconfig文件
########################################################################
cd /opt/k8s/work
set_kubectl(){
becho ">>> 下载和分发 kubectl 二进制文件"
echo -n "下载和分发 kubectl 二进制文件..."
if [ ! -e ${CUBERNETES_SERVER} ]; then
  if wget -N ${GET_CUBERNETES_SERVER}; then
    if tar -xf ${CUBERNETES_SERVER}; then
      gecho "成功！"
    else
      recho "失败！"
	  exit 1
    fi
  else
    recho "失败！"
	exit 1
  fi
else
  if tar -xf ${CUBERNETES_SERVER}; then
    gecho "成功！"
  else
    recho "失败！"
	exit 1
  fi
fi

# 创建 admin 证书和私钥
becho ">>> 生成证书和私钥"
cat > admin-csr.json <<EOF
{
  "CN": "admin",
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
      "O": "system:masters",
      "OU": "${CSR_OU}"
    }
  ]
}
EOF

for node_ip in ${MASTER_IPS[@]}; do
    gecho "复制以下文件到 ${node_ip}"
    scp kubernetes/server/bin/kubectl root@${node_ip}:/opt/k8s/bin/
    ssh root@${node_ip} "chmod +x /opt/k8s/bin/kubectl"
  done

echo -n "生成证书和私钥..."
cfssl gencert -ca=/opt/k8s/work/ca.pem \
  -ca-key=/opt/k8s/work/ca-key.pem \
  -config=/opt/k8s/work/ca-config.json \
  -profile=kubernetes admin-csr.json | cfssljson -bare admin
[ $? -eq 0 ] && gecho "成功!" || recho "失败！请检查原因"

becho ">>> 创建 kubeconfig 文件"
## 设置集群参数
echo -n "创建 kubeconfig 文件..."
kubectl config set-cluster kubernetes \
  --certificate-authority=/opt/k8s/work/ca.pem \
  --embed-certs=true \
  --server=${KUBE_APISERVER} \
  --kubeconfig=kubectl.kubeconfig
## 设置客户端认证参数
kubectl config set-credentials admin \
  --client-certificate=/opt/k8s/work/admin.pem \
  --client-key=/opt/k8s/work/admin-key.pem \
  --embed-certs=true \
  --kubeconfig=kubectl.kubeconfig
## 设置上下文参数
kubectl config set-context kubernetes \
  --cluster=kubernetes \
  --user=admin \
  --kubeconfig=kubectl.kubeconfig
## 设置默认上下文
kubectl config use-context kubernetes --kubeconfig=kubectl.kubeconfig
if [ $? -eq 0 ]; then
  gecho "配置文件生成成功!"
else 
  recho "配置生成失败！请检查原因."
fi

becho ">>> 分发 kubeconfig 文件"
for node_ip in ${MASTER_IPS[@]}; do
    gecho "复制以下文件到 ${node_ip}"
    ssh root@${node_ip} "mkdir -p ~/.kube"
    scp kubectl.kubeconfig root@${node_ip}:~/.kube/config
  done
}
set_kubectl
