#!/bin/bash
source ./00environment.sh

cd /opt/k8s/work
if [ -e ${CALICOCTL} ]; then
  :
else
	gecho ">>> 正在下载 clicoctl 客户端软件	"
  wget -N ${GET_CALICOCTL}
fi

[ -e calicoctl ] && rm -f calicoctl || mv ${CALICOCTL} calicoctl
chmod +x calicoctl

for node_ip in ${NODE_IPS[@]} ${MASTER_IPS[@]}; do 
    gecho ">>> 为各节点创建和分发 calicoctl 文件 ${node_ip}"
    scp calicoctl root@${node_ip}:/opt/k8s/bin
		ssh root@${node_ip} "grep 'export DATASTORE_TYPE=kubernetes' /etc/profile || echo 'export DATASTORE_TYPE=kubernetes' >> /etc/profile"
		ssh root@${node_ip} "grep 'export KUBECONFIG=~/.kube/config' /etc/profile || echo 'export KUBECONFIG=~/.kube/config' >> /etc/profile"
  done

kubectl apply -f http://192.168.10.102/K8s/calico/calico-v3.15.1.yaml
