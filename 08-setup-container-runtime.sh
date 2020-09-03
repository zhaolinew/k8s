#!/bin/bash
source ./00environment.sh

#############################################################
# 下载并分发二进制文件
#############################################################
get_containerd(){
#  wget https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.17.0/crictl-v1.17.0-linux-amd64.tar.gz \
#  https://github.com/opencontainers/runc/releases/download/v1.0.0-rc10/runc.amd64 \
#  https://github.com/containernetworking/plugins/releases/download/v0.8.5/cni-plugins-linux-amd64-v0.8.5.tgz \
#  https://github.com/containerd/containerd/releases/download/v1.3.3/containerd-1.3.3.linux-amd64.tar.gz 

gecho ">>> 下载work节点需要的二进制文件并分发..."
if [ ! -f ${CRICTL} ]; then
  wget ${GET_CRICTL}
fi

if [ $? -eq 0 ]; then
  tar -xvf ${CRICTL}
else
  recho "下载 ${CRICTL} 失败，请检查链接或网络!"
  exit 1
fi

if [ ! -f  ${RUNC} ]; then
  wget ${GET_RUNC}
fi
if [ $? -eq 0 ]; then
	rm -f runc >/dev/null 2>&1
  sudo mv ${RUNC} runc
else
  recho "下载 ${RUNC} 失败，请检查链接或网络!"
  exit 
fi

if [ ! -f ${CNI_PLUGINS} ]; then
  wget ${GET_CNI_PLUGINS}
fi
if [ $? -eq 0 ]; then
  mkdir cni-plugins
  sudo tar -xvf ${CNI_PLUGINS} -C cni-plugins
else
  recho "下载 ${CNI_PLUGINS} 失败，请检查链接或网络!"
  exit 
fi

if [ ! -f ${CONTAINERD} ]; then
  wget ${GET_CONTAINERD}
fi
if [ $? -eq 0 ]; then
  mkdir containerd
  tar -xvf ${CONTAINERD} -C containerd
else
  recho "下载 ${CONTAINERD} 失败，请检查链接或网络!"
  exit 
fi

# 分发二进制文件到所有 worker 节点：
for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do
    gecho ">>> 分发二进制文件到 worker 节点 ${node_ip}"
    ssh root@${node_ip} "mkdir /opt/cni/bin -p"
    scp containerd/bin/* crictl runc root@${node_ip}:/opt/k8s/bin
#    scp cni-plugins/* root@${node_ip}:/opt/cni/bin
    ssh root@${node_ip} "chmod a+x /opt/k8s/bin/* && mkdir -p /etc/cni/net.d"
  done
}

############################################
#     创建和分发 containerd 配置文件
############################################
config_containerd(){
cat > containerd-config.toml << EOF
version = 2
root = "${CONTAINERD_DIR}/root"
state = "${CONTAINERD_DIR}/state"
[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "registry.cn-beijing.aliyuncs.com/images_k8s/pause-amd64:3.1"
    [plugins."io.containerd.grpc.v1.cri".cni]
      bin_dir = "/opt/cni/bin"
      conf_dir = "/etc/cni/net.d"
  [plugins."io.containerd.runtime.v1.linux"]
    shim = "containerd-shim"
    runtime = "runc"
    runtime_root = ""
    no_shim = false
    shim_debug = false
EOF

for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do
    gecho ">>> 分发 containerd 配置文件 ${node_ip}"
    ssh root@${node_ip} "mkdir -p /etc/containerd ${CONTAINERD_DIR}/{root,state}"
    scp containerd-config.toml root@${node_ip}:/etc/containerd/config.toml
  done
}

##############################################
# 创建和分发 containerd systemd unit 文件
##############################################
systemd_containerd(){
cat > containerd.service <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target
[Service]
Environment="PATH=/opt/k8s/bin:/bin:/sbin:/usr/bin:/usr/sbin"
ExecStartPre=/sbin/modprobe overlay
ExecStart=/opt/k8s/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
[Install]
WantedBy=multi-user.target
EOF

# 分发 systemd unit 文件，启动 containerd 服务
for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do
  gecho ">>> 分发 systemd unit 文件，启动 containerd 服务 ${node_ip}"
  scp containerd.service root@${node_ip}:/etc/systemd/system
done
	
for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do
  gecho ">>> 启动 containerd 服务 ${node_ip}"
  ssh root@${node_ip} "systemctl enable containerd && systemctl restart containerd"
	sleep 5
done
	
for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do
	gecho ">>> 检查服务运行状态 ${node_ip}"
  ssh root@${node_ip} "systemctl status containerd | grep Active"
done
}

######################################
# 创建和分发 crictl 配置文件
######################################
# crictl 是兼容 CRI 容器运行时的命令行工具，提供类似于 docker 命令的功能。具体参考官方文档。
crictl_containerd(){
cat > crictl.yaml << EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# 分发 crictl 到所有 worker 节点：
for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do
    gecho ">>> 分发 crictl.yaml 文件到${node_ip}"
    scp crictl.yaml root@${node_ip}:/etc/crictl.yaml
  done
}

####################################################################################################
########################################################
# 下载和分发 docker 二进制文件
########################################################
get_docker() {
cd /opt/k8s/work
gecho ">>> 下载并解压 docker 文件"
if [ ! -f ${DOCKER} ]; then
  if wget -N ${GET_DOCKER} > /dev/null 2>&1; then
    gecho "成功！"
    tar -xf ${DOCKER}
  else
    recho "下载 ${DOCKER} 失败，请检查链接或网络!"
    exit 1
  fi
else 
  if tar -xf ${DOCKER}; then
		gecho "成功！"
	else
		recho "失败！"
		exit 1
  fi
fi

for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]} 
  do
    ssh root@${node_ip} "mkdir /opt/cni/bin /etc/cni/net.d -p"
    gecho ">>> 分发 docker 二进制文件到 ${node_ip}"
    scp docker/*  root@${node_ip}:/opt/k8s/bin/
    ssh root@${node_ip} "chmod +x /opt/k8s/bin/*"
  done
}

##########################################
#创建和分发 systemd unit 文件 for Docker
#########################################
systemd_docker(){
cat > docker.service <<"EOF"
[Unit]
Description=Docker Application Container Engine
Documentation=http://docs.docker.io
After=network-online.target firewalld.service containerd.service
Wants=network-online.target

[Service]
WorkingDirectory=##DOCKER_DIR##
Environment="PATH=/opt/k8s/bin:/bin:/sbin:/usr/bin:/usr/sbin"
ExecStart=/opt/k8s/bin/dockerd $DOCKER_NETWORK_OPTIONS
ExecReload=/bin/kill -s HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

# 配置和分发 docker 配置文件
# 使用国内的仓库镜像服务器以加快 pull image 的速度，同时增加下载的并发数 (需要重启 dockerd 生效)：
#    "exec-opts": ["native.cgroupdriver=systemd"],
cat > docker-daemon.json <<EOF
{
    "max-concurrent-downloads": 20,
    "live-restore": true,
    "max-concurrent-uploads": 10,
    "debug": true,
    "data-root": "${DOCKER_DIR}/data",
    "exec-root": "${DOCKER_DIR}/exec",
    "log-opts": {
      "max-size": "100m",
      "max-file": "5"
    }
}
EOF

# 分发|启动|检查 docker 配置文件到所有 worker 节点：
for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}
  do
    sed -i -e "s|##DOCKER_DIR##|${DOCKER_DIR}|" docker.service
    gecho ">>> 分发 docker systemd 文件到 ${node_ip}"
    scp docker.service root@${node_ip}:/etc/systemd/system/
  done

for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}
  do
    gecho ">>> 分发 docker 配置文件到 ${node_ip}"
    ssh root@${node_ip} "mkdir -p  /etc/docker/ ${DOCKER_DIR}/{data,exec}"
    scp docker-daemon.json root@${node_ip}:/etc/docker/daemon.json
  done

for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}
  do
    gecho ">>> 启动 docker 服务 ${node_ip}"
    ssh root@${node_ip} "systemctl daemon-reload && systemctl enable docker && systemctl restart docker"
    sleep 5
  done

for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}
  do
    gecho ">>> 检查服务运行状态 ${node_ip}"
    ssh root@${node_ip} "systemctl status docker|grep Active"
  done
}

set_registry(){
wget http://192.168.10.102/K8s/certs/harbor-ca.crt http://192.168.10.102/K8s/certs/config.json -N >/dev/null 2>&1
for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do
	gecho ">>> 设置 docker registry for ${node_ip}"
	ssh root@${node_ip} "mkdir -p /etc/docker/certs.d/registry.zhuanche.com /root/.docker"
	scp harbor-ca.crt root@${node_ip}:/etc/docker/certs.d/registry.zhuanche.com
  scp config.json root@${node_ip}:/root/.docker
done
}

case $1 in
containerd)
	get_containerd
  config_containerd
	systemd_containerd
	crictl_containerd
  ;;
docker)
  get_docker
  systemd_docker
	set_registry
  ;;
*)
  echo "Usage $0 <containerd|docker>"
  ;;
esac
