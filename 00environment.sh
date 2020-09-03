#!/bin/bash
# 生成 EncryptionConfig 所需的加密 key
export ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

# 集群各NODE IP 和对应的主机名数组
export NODE_IPS=(10.1.3.191 10.1.3.206)
export NODE_NAMES=(node1 node2)

# 新增节点时的IP和对应的主机名数组
export NEW_NODE_IPS=(10.1.3.59 10.1.3.144)
export NEW_NODE_NAMES=(node3 node4)

# 集群各MASTER IP 和对应的主机名数组
export MASTER_IPS=(10.1.3.42 10.1.3.117 10.1.3.166)
export MASTER_NAMES=(master1 master2 master3)

# 集群各ETCD IP 和对应的主机名数组
export ETCD_IPS=(10.1.3.42 10.1.3.117 10.1.3.166)
export ETCD_NAMES=(etcd1 etcd2 etcd3)

# etcd 集群服务地址列表
export ETCD_ENDPOINTS="https://10.1.3.42:2379,https://10.1.3.117:2379,https://10.1.3.166:2379"

# etcd 集群间通信的 IP 和端口
export ETCD_NODES="etcd1=https://10.1.3.42:2380,etcd2=https://10.1.3.117:2380,etcd3=https://10.1.3.166:2380"

# kube-apiserver 的反向代理 nginx 172.100.100.100地址端口, 此处建议先使用域名的方式, 
export KUBE_APISERVER="https://10.1.3.42:6443"

# 节点间互联网络接口名称
export IFACE="eth0"

# etcd 数据目录
export ETCD_DATA_DIR="/data/etcd"

# etcd WAL 目录，建议是 SSD 磁盘分区，或者和 ETCD_DATA_DIR 不同的磁盘分区
export ETCD_WAL_DIR="/data/etcd/wal"

# k8s 各组件数据目录
export K8S_DIR="/data/k8s"
# docker 数据目录
export DOCKER_DIR="/data/k8s/docker"

# containerd 数据目录
export CONTAINERD_DIR="/data/k8s/containerd"

## 以下参数一般不需要修改
# TLS Bootstrapping 使用的 Token，可以使用命令 head -c 16 /dev/urandom | od -An -t x | tr -d ' ' 生成
#export BOOTSTRAP_TOKEN="d65dbd7c45678e755a961233cd23a949"

# 最好使用 当前未用的网段 来定义服务网段和 Pod 网段
# 服务网段，部署前路由不可达，部署后集群内路由可达(kube-proxy 保证)
export SERVICE_CIDR="10.253.0.0/16"

# Pod 网段，建议 /16 段地址，部署前路由不可达，部署后集群内路由可达(flanneld 保证)
export CLUSTER_CIDR="172.18.0.0/16"

# 服务端口范围 (NodePort Range)
export NODE_PORT_RANGE="30000-32767"

# flanneld 网络配置前缀
export FLANNEL_ETCD_PREFIX="/kubernetes/network"

# kubernetes 服务 IP (一般是 SERVICE_CIDR 中第一个IP)
export CLUSTER_KUBERNETES_SVC_IP="10.253.0.1"

# 集群 DNS 服务 IP (从 SERVICE_CIDR 中预分配)
export CLUSTER_DNS_SVC_IP="10.253.0.2"

# 集群 DNS 域名（末尾不带点号）
export CLUSTER_DNS_DOMAIN="cluster.local"

# 将二进制目录 /opt/k8s/bin 加到 PATH 中
export PATH=/opt/k8s/bin:$PATH 

# 证书配置信息
export KUBE_APISERVER_DNS_NAME="kube-api.01zhuanche.com"
export CSR_C="CN"
export CSR_ST="BeiJing"
export CSR_L="BeiJing"
export CSR_O="k8s"
export CSR_OU="01zhuanche"

###################################
#软件安装版本及下载地址
###################################
#cfssl
export CFSSL="cfssl_1.4.1_linux_amd64"
export CFSSLJSON="cfssljson_1.4.1_linux_amd64"
export CFSSL_CERTINFO="cfssl-certinfo_1.4.1_linux_amd64"
export GET_CFSSL="http://192.168.10.102/K8s/cfssl/${CFSSL}"
export GET_CFSSLJSON="http://192.168.10.102/K8s/cfssl/${CFSSLJSON}"
export GET_CFSSL_CERTINFO="http://192.168.10.102/K8s/cfssl/${CFSSL_CERTINFO}"

#master file
export CUBERNETES_SERVER="kubernetes1.18.5-server-linux-amd64.tar.gz"
export GET_CUBERNETES_SERVER="http://192.168.10.102/K8s/${CUBERNETES_SERVER}"

#ETCD 
export ETCD_PKGS="etcd-v3.4.9-linux-amd64.tar.gz"
export GET_ETCD_PKGS="http://192.168.10.102/K8s/${ETCD_PKGS}"

#runc,containerd,cni,critcl
export CRICTL="crictl-v1.18.0-linux-amd64.tar.gz"
export RUNC="runc.amd64-1.0-rc91"
export CNI_PLUGINS="cni-plugins-linux-amd64-v0.8.6.tgz"
export CONTAINERD="containerd-1.3.6-linux-amd64.tar.gz"
export GET_CRICTL="http://192.168.10.102/K8s/${CRICTL}"
export GET_RUNC="http://192.168.10.102/K8s/${RUNC}"
export GET_CNI_PLUGINS="http://192.168.10.102/K8s/${CNI_PLUGINS}"
export GET_CONTAINERD="http://192.168.10.102/K8s/${CONTAINERD}"

#docker
export DOCKER="docker-18.09.6.tgz"
export GET_DOCKER="http://192.168.10.102/K8s/${DOCKER}"

#calicoctl
export CALICOCTL="calicoctl-3.15.1"
export GET_CALICOCTL="http://192.168.10.102/K8s/calico/${CALICOCTL}"

#coredns
export COREDNS="coredns_1.7.0_linux_amd64.tgz"
export GET_COREDNS="http://192.168.10.102/K8s/${COREDNS}"

#color functions
gecho() {
  echo -e "\e[1;2;32m $1 \e[0m"                                                                                                                           
  sleep 0.5
}
recho() {
  echo -e "\e[1;2;31m $1 \e[0m" 
  sleep 0.5
}
becho() {
  echo -e "\e[1;4;34m $1 \e[0m" 
  sleep 0.5
}
