#!/bin/bash

if [ ! -d /opt/k8s/work -o ! -e /opt/k8s/work/`basename $0` ]; then
	echo "you must create directory \"/opt/k8s/work\" first,"
	echo "and copy all of the scrips to this directory to run its one by one!"
	exit 1
fi
if [ ! -e /opt/k8s/work/00environment.sh ]; then
  echo "you must copy 00environment.sh to /opt/k8s/work with scripts!"
	exit 1
fi
source ./00environment.sh

IPS=(${MASTER_IPS[@]} ${NODE_IPS[@]} ${ETCD_IPS[@]})
NAMES=(${MASTER_NAMES[@]} ${NODE_NAMES[@]} ${ETCD_NAMES[@]})


#########################################################################
# 去重复的IP，在00environment.sh中定义 master 和 etcd 在同一个节点时, 
# 以下只对其中的一个节做准备工作，否则会出现一个IP重复准备工作。
#########################################################################
if [ -z "$2" -a -z "$3" ]; then
  for (( i=0; i < "${#IPS[@]}"; i++ )); do
    swich=no
    for (( j=$[i+1]; j< "${#IPS[@]}"; j++ )); do
      if [ ${IPS[i]} = ${IPS[j]} ]; then
        swich=yes
      fi
    done
    if [ "$swich" = no ]; then
      NEW_IPS[${#NEW_IPS[*]}]=${IPS[i]}
    fi
  done
fi

# install expect
if rpm -q expect &>/dev/null; then
#  echo "expect installed already"
  :
else
  gecho ">>> install expect"
	echo -n "installing expect..."
  yum clean all &>/dev/null
  yum repolist &>/dev/null
  if yum install -y expect &>/dev/null; then
    gecho "successful"
  else
    recho "failed"
    exit 1
  fi
fi

ssh_key(){
#generate key from localhost
read -s -p "input root password for host:" root_pass
clear
gecho ">>> Generate key"
echo -e -n "Generate key for localhost..." 
if [ -e /root/.ssh/id_rsa ]; then
	echo -e " key has exist"
else
	if ssh-keygen -t rsa -N '' -f /root/.ssh/id_rsa -q; then
	  echo -e " finished!"
  else
    echo -e " failed!"
  fi
fi

#copy key to hosts
gecho ">>> start copy key to hosts"
for host_ip in ${NEW_IPS[@]} ; do 
echo -e -n "coping file to ${host_ip}...,"
expect >/dev/null 2>&1 <<EOF
set timeout 5
spawn ssh-copy-id root@${host_ip}
expect {
    "yes/no" { send "yes\n";exp_continue }
    "password:" { send "${root_pass}\n" }
}
expect eof
EOF
if [ $? -eq 0 ]; then 
  echo -e " finish!"
else
  echo -e " failed!"
fi
done
}

set_hosts(){
for node_ip in ${MASTER_IPS[@]}; do
  let i=0
	gecho ">>> adding records of below to ${node_ip}:/etc/hosts"
  for node_ip2 in ${IPS[@]}; do
    node_name=${NAMES[i]}
    if ssh root@${node_ip} "grep "${node_ip2}" /etc/hosts | grep "$node_name"" >/dev/null 2>&1; then
      #recho "主机记录已经存在...!"
      :
		else
      echo "${node_ip2} ${node_name}"
      ssh root@${node_ip} "echo "${node_ip2} ${node_name}" >> /etc/hosts"
    fi
    let i++
  done
done
}

set_env(){
# gecho ">>> setup environment variables..."
# rpm -qa bash-completion || yum install bash-completion -y
# grep 'export PATH=/opt/k8s/bin:$PATH' /etc/profile >/dev/null 2>&1 || echo 'export PATH=/opt/k8s/bin:$PATH' >>/etc/profile
# grep 'source /usr/share/bash-completion/bash_completion' /etc/profie || echo 'source /usr/share/bash-completion/bash_completion' >> /etc/profile
# grep 'source <(kubectl completion bash)' /etc/profile || echo 'source <(kubectl completion bash)' >> /etc/profile
cat > /opt/k8s/work/kubernetes.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.tcp_tw_recycle=0
net.ipv4.neigh.default.gc_thresh1=1024
net.ipv4.neigh.default.gc_thresh1=2048
net.ipv4.neigh.default.gc_thresh1=4096
vm.swappiness=0
vm.overcommit_memory=1
vm.panic_on_oom=0
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=1048576
fs.file-max=52706963
fs.nr_open=52706963
net.ipv6.conf.all.disable_ipv6=1
net.netfilter.nf_conntrack_max=2310720
EOF

for host_ip in ${NEW_IPS[@]} ; do
gecho ">>> initialize environment on ${host_ip}"

echo -n "setup PATH environment variable..."
if ssh root@${host_ip} "grep 'export PATH=/opt/k8s/bin:\$PATH' /etc/profile >/dev/null 2>&1"; then
	:
else
  ssh root@${host_ip} "echo 'export PATH=/opt/k8s/bin:\$PATH' >>/etc/profile" 
	gecho "successful"
fi

echo -n "install necessary software..."
if ssh root@${host_ip} "yum install -y conntrack ipvsadm ipset iptables curl sysstat libseccomp wget socat git bash-completion &> /dev/null"; then
   gecho "successful"
else
   recho "failed"
   exit 1
fi

echo -n "Disable firewall..."
if ssh root@${host_ip} "systemctl stop firewalld && systemctl disable firewalld"; then
   gecho "successful"
else
   recho "failed"
   exit 1
fi

echo -n "flush iptables..."
if ssh root@${host_ip} "iptables -F && iptables -X && iptables -F -t nat && iptables -X -t nat &&iptables -P FORWARD ACCEPT"; then
   gecho "successful"
else
   recho "failed"
   exit 1
fi

echo -n "disable swap..."
if ssh root@${host_ip} "sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab && swapoff -a"; then
   gecho "successful"
else
   recho "failed"
   exit 1
fi

echo -n "disable SELINUX..."
if ssh root@${host_ip} "sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config"; then
   gecho "successful"
	 setenforce 0 &> /dev/null
else
   recho "failed"
   exit 1
fi

echo -n "apply conf file..." 
if scp /opt/k8s/work/kubernetes.conf  root@${host_ip}:/etc/sysctl.d/kubernetes.conf >/dev/null 2>&1; then
	if ssh root@${host_ip} "sysctl -p /etc/sysctl.d/kubernetes.conf >/dev/null 2>&1"; then 
    gecho "successful"
  else
    recho "failed"
    exit 1
  fi
else 
  recho "failed"
  exit 1
fi

# timedatectl set-timezone Asia/Shanghai
echo -n "create directory..." 
if ssh root@${host_ip} "mkdir -p /opt/k8s/{bin,cert,conf,work} && mkdir -p /opt/cni/bin"; then
   gecho "successful"
else
   recho "failed"
   exit 1
fi
done
}


case $1 in
cluster)
  ssh_key
	set_hosts
	set_env
	;;
addone)
  if [ -z "$2" -o -z "$3" ]; then
 	 echo "Usage $0 addone <node_ip> <node_name>"
 	 exit 1
	fi
  NEW_IPS=("$2")
  IPS=("$2")
  NAMES=("$3")
  ssh_key
  set_hosts
  set_env
  ;;
addmore)
	NEW_IPS=(${NEW_NODE_IPS[@]})
	IPS=(${NEW_NODE_IPS[@]})
	NAMES=(${NEW_NODE_NAMES[@]})
  ssh_key
  set_hosts
  set_env
	;;
#sethosts)
#  IPS=(${IPS[@]} ${NEW_NODE_IPS[@]})
#  NEW_IPS=(${NEW_IPS[@]} ${NEW_NODE_IPS[@]}) 
#  NAMES=(${NAMES[@]} ${NEW_NODE_NAMES[@]})  
#  set_hosts
#  ;;
*)
 echo "Usage $0 <cluster|addmore|addone> [<node_ip> <node_name>]" 
 ;;
esac
