# vps-setup

Server setup script

```bash
# 安装git
sudo apt update && sudo apt install git -y

#网络优化
echo 'net.core.default_qdisc=fq' > /etc/sysctl.d/98-bbr.conf
echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.d/98-bbr.conf
lsmod | grep bbr
sudo sysctl --system
```
