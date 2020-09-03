#!/bin/bash
#
#******************************************************************* *
#Author:                Leo
#QQ:                    77961731
#Date:                  2020-09-02
#FileName：             delete.sh
#URL:                   https://blog.51cto.com/127601
#Description：          The test script
#Copyright (C):        2020 All rights reserved
#********************************************************************
systemctl stop kubelet
systemctl stop kube-proxy
systemctl stop docker
systemctl stop containerd

rm -rf /opt/{k8s,cni} 
rm -f /etc/systemd/system/kube*
rm -f /etc/systemd/system/docker*
rm -rf /etc/cni
rm -rf /etc/containerd

