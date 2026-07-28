# 更新系统
apt update && apt upgrade -y

# 基础工具
apt install -y curl wget vim ufw

# 开启 BBR 拥塞控制
cat >> /etc/sysctl.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl -p

# 检查当前 SSH 端口（很多 VPS 商不用 22）
SSH_PORT=$(ss -tlnp | grep sshd | head -1 | awk '{print $4}' | awk -F: '{print $NF}')
echo "SSH port: ${SSH_PORT:-22}"

# 防火墙放行
ufw allow ${SSH_PORT:-22}/tcp
ufw allow 443/tcp     # VLESS Reality
ufw allow 80/tcp     # 证书申请
ufw allow 8843/udp    # Hysteria2
ufw allow 10000:30000/udp    # 端口跳跃

# 先检查有没有 1Panel，它的防火墙会覆盖 ufw
if systemctl is-active --quiet 1panel-core 2>/dev/null; then
  echo "检测到 1Panel，注意：需要单独在 1Panel 防火墙里放行 443/tcp 和 8443/udp！"
fi

ufw --force enable

# 官方一键脚本（Debian/Ubuntu）
curl -fsSL https://get.docker.com | sh

# 启动并设为开机自启
systemctl enable docker
systemctl start docker

# 安装 Docker Compose v2（作为 Docker 插件）
apt install -y docker-compose-plugin

# 创建目录
mkdir -p /opt/sing-box/cert
mkdir -p /opt/sing-box/config

# 拉取镜像
docker pull ghcr.io/sagernet/sing-box:latest

# 安装 acme.sh
curl https://get.acme.sh | sh -s email=my123@gmail.com
source ~/.bashrc

# 申请证书（需要 80 端口暂时可用）
~/.acme.sh/acme.sh --issue -d kr.870910.xyz --standalone

# 安装到 sing-box 目录
~/.acme.sh/acme.sh --install-cert -d kr.870910.xyz \
  --key-file /opt/sing-box/cert/privkey.pem \
  --fullchain-file /opt/sing-box/cert/fullchain.pem

# 设置自动续期后重载 sing-box 容器
~/.acme.sh/acme.sh --install-cronjob

# 生成参数
domain=omnirouters.com
keys=$(docker run --rm ghcr.io/sagernet/sing-box generate reality-keypair)
private_key=$(echo $keys | awk -F " " '{print $2}')
public_key=$(echo $keys | awk -F " " '{print $4}')
UUID=$(docker run --rm ghcr.io/sagernet/sing-box generate uuid)
Short_ID=$(docker run --rm ghcr.io/sagernet/sing-box generate rand 8 --hex)
HY2pw=$(openssl rand -base64 16)

#设置端口跳跃
DEFAULT_INTERFACE=$(ip route | awk '/^default/ {print $5}')
echo "检测到默认网卡为: $DEFAULT_INTERFACE"
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt install -y iptables-persistent
iptables -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 10000:30000 -j DNAT --to-destination :8843
netfilter-persistent save

# 配置config.json
cat > /opt/sing-box/config/config.json <<-EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {"tag": "google", "type": "tls", "server": "8.8.8.8"}
    ]
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 8843,
      "users": [
        {"name": "main", "password": "$HY2pw"}
      ],
      "tls": {
        "enabled": true,
        "server_name": "localhost",
        "certificate_path": "/etc/sing-box/cert/fullchain.pem",
        "key_path": "/etc/sing-box/cert/privkey.pem"
      }
    },
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "name": "main",
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$domain",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$Short_ID"],
          "max_time_difference": "1m"
        }
      }
    }
  ],
  "outbounds": [
    {"type": "direct", "tag": "direct-out"}
  ]
}
EOF

# Docker Compose 部署
cat > /opt/sing-box/docker-compose.yml <<-EOF
version: "3.8"

services:
  sing-box:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: sing-box
    restart: always
    network_mode: host
    volumes:
      - /opt/sing-box/config:/etc/sing-box      # 配置
      - /opt/sing-box/cert:/etc/sing-box/cert      # 证书
    command: -C /etc/sing-box/ run
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

#运行docker
cd /opt/sing-box
docker compose up -d

echo
echo "----------  Reality配置信息 -------------"
echo -e "端口 (Port) = 443"
echo -e "UUID = ${UUID}"
echo -e "流控 (Flow) = xtls-rprx-vision"
echo -e "加密 (Encryption) = none"
echo -e "传输协议 (Network) = tcp"
echo -e "底层传输安全 (TLS) = reality"
echo -e "SNI =${domain}"
echo -e "指纹 (Fingerprint) = chrome"
echo -e "公钥 (PublicKey) = ${public_key}"
echo -e "ShortId = ${Short_ID}"
echo

echo
echo "----------  Hysteria2配置信息 -------------"
echo -e "端口 (Port) = 8843"
echo -e "端口跳跃 (Port) = 10000-30000"
echo -e "密码= ${HY2pw}"
echo -e "域名 =kr.870910.xyz "
echo
