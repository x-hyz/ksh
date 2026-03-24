#!/bin/bash
set -e

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  Docker一键安装与系统优化脚本 (CentOS 7)${NC}"
echo -e "${GREEN}  [特色: 自动嗅探网段并固定静态IP版本]   ${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""

# 检查是否为CentOS 7
if [ ! -f /etc/redhat-release ]; then
    echo -e "${RED}错误: 此脚本仅适用于CentOS/RHEL系统${NC}"
    exit 1
fi

CENTOS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | cut -d. -f1)
if [ "$CENTOS_VERSION" != "7" ]; then
    echo -e "${RED}错误: 此脚本仅适用于CentOS 7，检测到版本: $CENTOS_VERSION${NC}"
    exit 1
fi

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 此脚本需要root权限运行，请使用 sudo bash $0${NC}"
    exit 1
fi

# ========== 步骤0: 自动嗅探网络并固定静态IP ==========
echo -e "${GREEN}步骤0: 正在检测网卡并自动配置静态网络...${NC}"

# 1. 获取主物理网卡名称 (忽略lo)
NETCARD=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2}' | cut -d'@' -f1 | head -1 | tr -d ' ')

if [ -z "$NETCARD" ]; then
    echo -e "${RED}错误: 未检测到任何物理网卡！请检查虚拟机硬件设置。${NC}"
    exit 1
fi
echo -e "${GREEN}-> 找到主网卡: $NETCARD${NC}"

IFCFG_FILE="/etc/sysconfig/network-scripts/ifcfg-$NETCARD"

# 2. 强制开启DHCP以嗅探当前网段信息
echo -e "${YELLOW}-> 正在请求 DHCP 服务器以获取网段信息，请稍候...${NC}"
if [ -f "$IFCFG_FILE" ]; then
    cp "$IFCFG_FILE" "$IFCFG_FILE.bak.$(date +%s)"
    UUID=$(grep -oP '(?<=UUID=).*' "$IFCFG_FILE" | head -1 || echo "")
    HWADDR=$(grep -oP '(?<=HWADDR=).*' "$IFCFG_FILE" | head -1 || grep -oP '(?<=MACADDR=).*' "$IFCFG_FILE" | head -1 || echo "")
else
    UUID=""
    HWADDR=""
fi

# 临时写入DHCP配置
cat > "$IFCFG_FILE" << EOF
TYPE=Ethernet
BOOTPROTO=dhcp
NAME=$NETCARD
DEVICE=$NETCARD
ONBOOT=yes
EOF
if [ -n "$UUID" ]; then echo "UUID=$UUID" >> "$IFCFG_FILE"; fi
if [ -n "$HWADDR" ]; then echo "HWADDR=$HWADDR" >> "$IFCFG_FILE"; fi

# 重启网络服务触发DHCP
systemctl restart network || true
sleep 5 # 等待IP分配

# 3. 提取刚刚获取到的网络信息
AUTO_IP=$(ip -4 addr show "$NETCARD" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
AUTO_PREFIX=$(ip -4 addr show "$NETCARD" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1 | cut -d/ -f2)
AUTO_GATEWAY=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)

if [ -z "$AUTO_IP" ] || [ -z "$AUTO_GATEWAY" ]; then
    echo -e "${RED}严重错误: 无法通过 DHCP 自动获取到 IP 或网关！${NC}"
    echo -e "${RED}这通常意味着：${NC}"
    echo -e "${RED}1. 您的 VMware/VirtualBox 宿主机网络服务(NAT/DHCP)未启动。${NC}"
    echo -e "${RED}2. 虚拟机的网络适配器处于“未连接”状态。${NC}"
    echo -e "${RED}脚本无法凭空猜出网段，请修复虚拟机网络设置后再试。${NC}"
    exit 1
fi

# 将前缀长度转换为子网掩码 (简易处理常见掩码)
case "$AUTO_PREFIX" in
    24) AUTO_NETMASK="255.255.255.0" ;;
    16) AUTO_NETMASK="255.255.0.0" ;;
    8)  AUTO_NETMASK="255.0.0.0" ;;
    *)  AUTO_NETMASK="255.255.255.0" ;; # 兜底默认值
esac

echo -e "${GREEN}-> 成功获取网段信息!${NC}"
echo -e "   获取到的IP: ${AUTO_IP}"
echo -e "   子网掩码  : ${AUTO_NETMASK}"
echo -e "   默认网关  : ${AUTO_GATEWAY}"

# 4. 固化为静态IP配置
echo -e "${YELLOW}-> 正在将获取到的 IP 固化为永久静态 IP...${NC}"
cat > "$IFCFG_FILE" << EOF
TYPE=Ethernet
BOOTPROTO=static
DEFROUTE=yes
PEERDNS=yes
PEERROUTES=yes
IPV4_FAILURE_FATAL=no
IPV6INIT=yes
IPV6_AUTOCONF=yes
IPV6_DEFROUTE=yes
IPV6_PEERDNS=yes
IPV6_PEERROUTES=yes
IPV6_FAILURE_FATAL=no
NAME=$NETCARD
DEVICE=$NETCARD
ONBOOT=yes
IPADDR=$AUTO_IP
NETMASK=$AUTO_NETMASK
GATEWAY=$AUTO_GATEWAY
DNS1=114.114.114.114
DNS2=8.8.8.8
EOF
if [ -n "$UUID" ]; then echo "UUID=$UUID" >> "$IFCFG_FILE"; fi
if [ -n "$HWADDR" ]; then echo "HWADDR=$HWADDR" >> "$IFCFG_FILE"; fi

systemctl restart network || true
sleep 3
echo -e "${GREEN}-> 静态IP配置完成！${NC}\n"

# 5. 测试外网连通性
echo "测试外网连通性..."
if ! ping -c 2 -W 3 223.5.5.5 &>/dev/null && ! ping -c 2 -W 3 114.114.114.114 &>/dev/null; then
    echo -e "${RED}错误: 无法连接到互联网！网络配置似乎存在异常。${NC}"
    exit 1
fi
echo -e "${GREEN}网络连通性测试通过！准备开始安装 Docker。${NC}\n"

# ========== 步骤1: 关闭防火墙（永久） ==========
echo -e "${GREEN}步骤1: 关闭并禁用防火墙...${NC}"
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true
iptables -F 2>/dev/null || true
echo -e "防火墙已关闭\n"

# ========== 步骤2: 配置yum源 (阿里云加速) ==========
echo -e "${GREEN}步骤2: 配置阿里云Yum源...${NC}"
# 清理残留的yum锁
if [ -f /var/run/yum.pid ]; then
    rm -f /var/run/yum.pid
    rm -f /var/run/yum.pid.lock
fi

mkdir -p /etc/yum.repos.d/backup
mv /etc/yum.repos.d/CentOS-*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
mv /etc/yum.repos.d/epel*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true

curl -fsSL -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-7.repo
curl -fsSL -o /etc/yum.repos.d/epel.repo http://mirrors.aliyun.com/repo/epel-7.repo

yum clean all >/dev/null
yum makecache >/dev/null
echo -e "Yum源配置完成\n"

# ========== 步骤3: 安装依赖包 ==========
echo -e "${GREEN}步骤3: 安装Docker底层依赖...${NC}"
yum install -y yum-utils device-mapper-persistent-data lvm2 curl >/dev/null
echo -e "依赖包安装完成\n"

# ========== 步骤4: 添加Docker官方仓库(阿里云镜像) ==========
echo -e "${GREEN}步骤4: 添加Docker仓库...${NC}"
yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo >/dev/null
echo -e "Docker仓库添加完成\n"

# ========== 步骤5: 安装Docker ==========
echo -e "${GREEN}步骤5: 正在下载并安装Docker，请稍候...${NC}"
yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
echo -e "Docker安装完成\n"

# ========== 步骤6: 配置镜像加速器 ==========
echo -e "${GREEN}步骤6: 配置国内Docker镜像加速器及日志优化...${NC}"
mkdir -p /etc/docker

cat > /etc/docker/daemon.json <<'EOF'
{
    "registry-mirrors": [
        "https://docker.m.daocloud.io",
        "https://dockerproxy.com",
        "https://hub-mirror.c.163.com",
        "https://mirror.baidubce.com",
        "https://ccr.ccs.tencentyun.com"
    ],
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "3"
    },
    "storage-driver": "overlay2"
}
EOF
echo -e "镜像加速器配置完成\n"

# ========== 步骤7: 启动并设置开机自启 ==========
echo -e "${GREEN}步骤7: 启动Docker服务...${NC}"
systemctl daemon-reload
systemctl enable docker 2>/dev/null
systemctl restart docker
echo -e "Docker已启动并设置开机自启\n"

# ========== 步骤8: 验证配置 ==========
echo -e "${GREEN}步骤8: 运行测试容器...${NC}"
if docker run --rm hello-world | grep -q "Hello from Docker!"; then
    echo -e "${GREEN}测试容器运行成功！Docker工作正常。${NC}\n"
else
    echo -e "${RED}测试容器运行失败，请手动使用 docker info 检查状态。${NC}\n"
fi

# ========== 总结 ==========
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}            Docker 安装全部完成！         ${NC}"
echo -e "${GREEN}=========================================${NC}"
echo -e "  网络与系统信息:"
echo -e "  - Docker版本 : $(docker --version | awk '{print $3}' | tr -d ',')"
echo -e "  - 本机主网卡 : ${NETCARD}"
echo -e "  - 本机IP地址 : ${AUTO_IP} ${YELLOW}(自动嗅探并已永久固定静态)${NC}"
echo -e "  - 网卡配置   : ${IFCFG_FILE}"
echo ""
echo -e "  常用命令提示:"
echo -e "  - 查看服务状态: ${YELLOW}systemctl status docker${NC}"
echo -e "  - 查看运行容器: ${YELLOW}docker ps${NC}"
echo -e "  - 查看本地镜像: ${YELLOW}docker images${NC}"
echo -e "${GREEN}=========================================${NC}"