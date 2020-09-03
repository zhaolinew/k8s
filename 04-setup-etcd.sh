#!/bin/bash
source ./00environment.sh

##############################################################################
# 部署 etcd 集群
##############################################################################

get_etcd(){
# 下载和分发 etcd 二进制文件
gecho ">>> 下载和分发二进制文件..."
if [ ! -f ${ETCD_PKGS} ]; then
  wget ${GET_ETCD_PKGS}
  #wget https://github.com/etcd-io/etcd/releases/download/v3.4.9/$PKGS
fi
if [ ! $? -eq 0 ]; then
  recho ">>> 下载失败，请检查链接或网络!"
  exit 1
fi
tar -xzf ${ETCD_PKGS}

gecho ">>> 分发二进制文件到集群所有节点..."
ETCD_DIR=`echo ${ETCD_PKGS} | rev | cut -d. -f3- | rev`
for node_ip in ${ETCD_IPS[@]}; do
    echo ">>> 分发二进制文件到 ${node_ip}"
    scp ${ETCD_DIR}/etcd* root@${node_ip}:/opt/k8s/bin
    ssh root@${node_ip} "chmod +x /opt/k8s/bin/*"
  done
}

# 创建 etcd 证书和私钥
cert_etcd(){
gecho ">>> 创建证书签名请求..."
cat > etcd-csr.json <<EOF
{
  "CN": "etcd",
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
      "O": "k8s",
      "OU": "${CSR_OU}"
    }
  ]
}
EOF

# 将IP添加到证书的hosts字段中
for (( i=0; i < "${#ETCD_IPS[@]}"; i++ ))
do
  if [ "${i}" -eq 0 ]; then
    sed -i '4a'"\    \"${ETCD_IPS[i]}\""'' etcd-csr.json
  else
    sed -i '4a'"\    \"${ETCD_IPS[i]}\","'' etcd-csr.json
  fi
done                               

## 生成证书和私钥
gecho ">>> 生成证书和私钥..."
cfssl gencert -ca=/opt/k8s/work/ca.pem \
    -ca-key=/opt/k8s/work/ca-key.pem \
    -config=/opt/k8s/work/ca-config.json \
    -profile=kubernetes etcd-csr.json | cfssljson -bare etcd

if [ $? -eq 0 ]; then
  gecho ">>> 证书生成成功!"
else
  recho ">>> 证书生成失败！请检查原因"
  exit 1
fi

## 分发生成的证书和私钥到各 etcd 节点：
for node_ip in ${ETCD_IPS[@]}
  do
    gecho ">>> 分发生成的证书和私钥到到 ${node_ip}"
    ssh root@${node_ip} "mkdir -p /opt/k8s/cert"
    scp etcd*.pem root@${node_ip}:/opt/k8s/cert/
  done
}

#创建 etcd 的 systemd unit 模板文件
systemd_etcd(){
cat > etcd.service.template <<EOF
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target
Documentation=https://github.com/coreos
[Service]
Type=notify
WorkingDirectory=${ETCD_DATA_DIR}
ExecStart=/opt/k8s/bin/etcd \\
  --data-dir=${ETCD_DATA_DIR} \\
  --wal-dir=${ETCD_WAL_DIR} \\
  --name=##NODE_NAME## \\
  --cert-file=/opt/k8s/cert/etcd.pem \\
  --key-file=/opt/k8s/cert/etcd-key.pem \\
  --trusted-ca-file=/opt/k8s/cert/ca.pem \\
  --peer-cert-file=/opt/k8s/cert/etcd.pem \\
  --peer-key-file=/opt/k8s/cert/etcd-key.pem \\
  --peer-trusted-ca-file=/opt/k8s/cert/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --listen-peer-urls=https://##NODE_IP##:2380 \\
  --initial-advertise-peer-urls=https://##NODE_IP##:2380 \\
  --listen-client-urls=https://##NODE_IP##:2379,http://127.0.0.1:2379 \\
  --advertise-client-urls=https://##NODE_IP##:2379 \\
  --initial-cluster-token=etcd-cluster-0 \\
  --initial-cluster=${ETCD_NODES} \\
  --initial-cluster-state=new \\
  --auto-compaction-mode=periodic \\
  --auto-compaction-retention=1 \\
  --max-request-bytes=33554432 \\
  --quota-backend-bytes=6442450944 \\
  --heartbeat-interval=250 \\
  --election-timeout=2000
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF

# 替换配置文件的变量
for (( i=0; i < "${#ETCD_IPS[@]}"; i++ ))
  do
    sed -e "s/##NODE_NAME##/${ETCD_NAMES[i]}/" -e "s/##NODE_IP##/${ETCD_IPS[i]}/" etcd.service.template > etcd-${ETCD_IPS[i]}.service 
  done

# 为各节点创建和分发 etcd systemd unit 文件并启动服务
for node_ip in ${ETCD_IPS[@]}
  do
    gecho ">>> 创建和分发 etcd systemd unit 文件到 ${node_ip}"
    scp etcd-${node_ip}.service root@${node_ip}:/etc/systemd/system/etcd.service

    gecho ">>> 启动etcd服务 ${node_ip}"
    ssh root@${node_ip} "mkdir -p ${ETCD_DATA_DIR} ${ETCD_WAL_DIR}"
    ssh root@${node_ip} "systemctl daemon-reload && systemctl enable etcd && systemctl restart etcd " &
    sleep 5
	
    gecho ">>> 检查启动结果 ${node_ip}"
    ssh root@${node_ip} "systemctl status etcd|grep Active"
done
gecho ">>> 验证服务状态 ${node_ip}"
ssh root@${node_ip} "/opt/k8s/bin/etcdctl \
  --endpoints=https://${node_ip}:2379 \
  --cacert=/opt/k8s/cert/ca.pem \
  --cert=/opt/k8s/cert/etcd.pem \
  --key=/opt/k8s/cert/etcd-key.pem endpoint health && \
  /opt/k8s/bin/etcdctl \
  -w table --cacert=/opt/k8s/cert/ca.pem \
  --cert=/opt/k8s/cert/etcd.pem \
  --key=/opt/k8s/cert/etcd-key.pem \
  --endpoints=${ETCD_ENDPOINTS} endpoint status"
}

get_etcd
cert_etcd
systemd_etcd
