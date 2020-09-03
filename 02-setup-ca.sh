#!/bin/bash
source ./00environment.sh

#################################################################
# 下载生成的工具...
##################################################################

# 安装 cfssl 工具集
becho ">>> 下载和安装 cfssl 工具集"
echo -n "下载cfssl文件..."
get_cfssl(){
if [ ! -f ${CFSSL} ]; then
  wget ${GET_CFSSL} 
  #wget https://github.com/cloudflare/cfssl/releases/download/v1.4.1/cfssl_1.4.1_linux_amd64
fi

if [ $? -eq 0 ]; then
  gecho "成功！"
  mv ${CFSSL} /opt/k8s/bin/cfssl
  chmod +x /opt/k8s/bin/cfssl
else
  recho "下载cfssl失败，请检查链接或网络!"
  exit 1
fi

echo -n "下载cfssljson文件..."
if [ ! -f  ${CFSSLJSON} ]; then
  wget ${GET_CFSSLJSON}
  #wget https://github.com/cloudflare/cfssl/releases/download/v1.4.1/cfssljson_1.4.1_linux_amd64
fi
if [ $? -eq 0 ]; then
  gecho "成功！"
  mv ${CFSSLJSON} /opt/k8s/bin/cfssljson
  chmod +x /opt/k8s/bin/cfssljson
else
  recho "下载cfssljson失败，请检查链接或网络!"
  exit 1
fi

echo -n "下载cfssl_certinfo文件..."
if [ ! -f ${CFSSL_CERTINFO} ]; then
  wget ${GET_CFSSL_CERTINFO}
  #wget https://github.com/cloudflare/cfssl/releases/download/v1.4.1/cfssl-certinfo_1.4.1_linux_amd64
fi
if [ $? -eq 0 ]; then
  gecho "成功！"
  mv ${CFSSL_CERTINFO} /opt/k8s/bin/cfssl-certinfo
  chmod +x /opt/k8s/bin/cfssl-certinfo
else
  recho "下载失败，请检查链接或网络!"
  exit 1
fi
}

# 创建证书的配置文件
set_ca(){
cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "87600h"
    },
    "profiles": {
      "kubernetes": {
        "usages": [
            "signing",
            "key encipherment",
            "server auth",
            "client auth"
        ],
        "expiry": "876000h"
      }
    }
  }
}
EOF

# 创建 CA 证书请求文件
cat > ca-csr.json <<EOF
{
  "CN": "kubernetes-ca",
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
  ],
  "ca": {
    "expiry": "876000h"
 }
}
EOF
becho ">>> 生成 CA 证书和私钥"
echo -n "生成证书..."
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
[ $? -eq 0 ] && gecho "证书生成成功!" || recho "证书生成失败！请检查原因"
# 分发 CA 证书文件
for node_ip in ${MASTER_IPS[@]}; do
    gecho ">>> 复制以下文件到${node_ip}"
    ssh root@${node_ip} "mkdir -p /opt/k8s/cert"
    scp ca*.pem ca-config.json root@${node_ip}:/opt/k8s/cert
done
for node_ip in ${NODE_IPS[@]} ${ETCD_IPS[@]}; do
    gecho ">>> 复制以下文件到${node_ip}"
    ssh root@${node_ip} "mkdir -p /opt/k8s/cert"
    scp ca.pem root@${node_ip}:/opt/k8s/cert
done


}
get_cfssl
set_ca
