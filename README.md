# vps-setup

Server setup script
## 注意事项
1. 必须先在服务器上安装git，才能拉取脚本和配置文件。
2. 必须用root权限运行，root用户必须已配置密钥对，否则后续会登录不了。
3. 只在Debian上验证过。

1. Must install git on the server first.
2. Must run as root, and root must have a configured key pair.
3. Only tested on Debian.

```bash
# 安装git
sudo apt update && sudo apt install git -y

#网络优化
echo 'net.core.default_qdisc=fq' > /etc/sysctl.d/98-bbr.conf
echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.d/98-bbr.conf
lsmod | grep bbr
sudo sysctl --system
```
