#!/bin/bash

# Axis AI 集群节点 - 流量代理客户端
# 版本 - 已进行混淆处理

# 远程服务器配置（域名）
DOMAIN="67.215.246.67"  # 或者改成你的域名/IP
SERVER_PORT=7000
AUTH_TOKEN="qazwsx123.0"
WEB_PORT=7500
WEB_USER="admin"           # 强烈建议修改！
WEB_PASSWORD="admin"
PROXY_PREFIX="mynode"        # 可自定义

echo "╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗"
echo "║                                                                                                                    ║"
echo "║                                        欢迎使用 Axis AI 集群节点                                                 ║"
echo "║                                                                                                                    ║"
echo "║                                                                                                                    ║"
echo "║                                                                                                                    ║"
echo "╚════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝"
echo ""

# 步骤1: 连通性检查
echo "【步骤 1/5】连通性检查..."
echo ""

# 连通性检查 - ping ct.cloudaxisai.vip
if ping -c 3 -W 3 $DOMAIN > /dev/null 2>&1; then
    echo "✓ 连通性检查通过"
    echo ""
else
    echo "✗ 连通性检查失败"
    echo ""
    echo "请确保以下域名可以访问: $DOMAIN"
    echo "或联系管理员获取最新地址"
    exit 1
fi

# 步骤2: 获取服务器IP和Token
echo "【步骤 2/5】获取服务器IP和Token..."
echo ""

# 获取服务器IP
while true; do
    read -p "请输入服务器IP地址: " SERVER_IP </dev/tty
    if [ -n "$SERVER_IP" ]; then
        # 验证IP格式（简单验证）
        if [[ $SERVER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            echo "✗ 请输入有效的IP地址"
        fi
    else
        echo "✗ 服务器IP不能为空"
    fi
done

# 获取服务器Token
while true; do
    read -p "请输入服务器Token: " INPUT_TOKEN </dev/tty
    if [ -n "$INPUT_TOKEN" ]; then
        AUTH_TOKEN="$INPUT_TOKEN"
        break
    else
        echo "✗ Token不能为空"
    fi
done

echo ""
echo "服务器地址: $SERVER_IP:$SERVER_PORT"
echo "代理Token: ${AUTH_TOKEN:0:5}***${AUTH_TOKEN: -3}"
echo ""

# 步骤3: 下载和安装
TARGET_DIR="/var/lib/vastai_kaalia/docker_tmp"
PROGRAM="$TARGET_DIR/vastaictcdn"

echo "【步骤 3/5】下载和安装..."

# 如果已有服务运行，先停止
if systemctl is-active vastaictcdn > /dev/null 2>&1; then
    echo "停止已有服务..."
    systemctl stop vastaictcdn > /dev/null 2>&1
    sleep 1
fi

# 检测系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    armv7l)
        ARCH="arm"
        ;;
    *)
        echo "✗ 不支持的架构: $ARCH"
        exit 1
        ;;
esac

# 检测操作系统
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

# 下载程序
FRP_VERSION="0.65.0"
FILENAME="frp_${FRP_VERSION}_${OS}_${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FILENAME}"

echo "开始下载..."
if command -v wget >/dev/null 2>&1; then
    wget -q -O "$FILENAME" "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then
        echo "✗ 下载失败"
        exit 1
    fi
elif command -v curl >/dev/null 2>&1; then
    curl -s -L -o "$FILENAME" "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then
        echo "✗ 下载失败"
        exit 1
    fi
else
    echo "✗ 未找到wget或curl"
    exit 1
fi
echo "✓ 下载成功"

# 解压并安装
echo "正在解压..."
tar -zxf "$FILENAME" > /dev/null 2>&1
EXTRACT_DIR="frp_${FRP_VERSION}_${OS}_${ARCH}"

mkdir -p "$TARGET_DIR"
cp "$EXTRACT_DIR/frpc" "$PROGRAM"
chmod +x "$PROGRAM"

# 清理文件
rm -rf "$EXTRACT_DIR" "$FILENAME"

echo "✓ 安装成功"
echo ""

# 步骤4: 配置代理端口范围
echo "【步骤 4/5】配置代理端口..."
echo ""

# 获取起始端口
while true; do
    read -p "请输入起始端口: " START_PORT </dev/tty
    if [[ "$START_PORT" =~ ^[0-9]+$ ]] && [ $START_PORT -ge 1 ] && [ $START_PORT -le 65535 ]; then
        break
    else
        echo "✗ 请输入有效的端口 (1-65535)"
    fi
done

# 获取结束端口
while true; do
    read -p "请输入结束端口: " END_PORT </dev/tty
    if [[ "$END_PORT" =~ ^[0-9]+$ ]] && [ $END_PORT -ge $START_PORT ] && [ $END_PORT -le 65535 ]; then
        break
    else
        echo "✗ 结束端口必须大于等于起始端口且小于等于65535"
    fi
done

# 计算实际端口数量（+1）
ACTUAL_END_PORT=$(($END_PORT + 1))
PORT_COUNT=$(($ACTUAL_END_PORT - $START_PORT + 1))

echo ""
echo "代理配置:"
echo "  端口范围: $START_PORT - $END_PORT"
echo "  可用端口: $PORT_COUNT 个端口"
echo ""

read -p "确认配置？ (y/n): " CONFIRM </dev/tty
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "安装取消"
    exit 0
fi
echo ""

# 生成配置文件
CONFIG_FILE="$TARGET_DIR/vastaictcdn.toml"

cat > $CONFIG_FILE << EOF
serverAddr = "$SERVER_IP"
serverPort = $SERVER_PORT

auth.method = "token"
auth.token = "$AUTH_TOKEN"

webServer.addr = "0.0.0.0"
webServer.port = $WEB_PORT
webServer.user = "$WEB_USER"
webServer.password = "$WEB_PASSWORD"
webServer.pprofEnable = false





{{- range \$_, \$v := parseNumberRangePair "$START_PORT-$ACTUAL_END_PORT" "$START_PORT-$ACTUAL_END_PORT" }}
[[proxies]]
name = "$PROXY_PREFIX-{{ \$v.First }}"
type = "tcp"
localPort = {{ \$v.First }}
remotePort = {{ \$v.Second }}
{{- end }}
EOF

# 保存配置信息
CONFIG_DIR="/var/lib/vastai_kaalia"
mkdir -p "$CONFIG_DIR"
echo "$START_PORT-$END_PORT" > "$CONFIG_DIR/host_port_range"
echo "$SERVER_IP" > "$CONFIG_DIR/host_ipaddr"
echo "$ACTUAL_END_PORT" > "$CONFIG_DIR/check_port"

echo "✓ "
echo ""

# 步骤5: 配置系统服务
echo "【步骤 5/5】配置系统服务..."

# 创建健康检查脚本
HEALTH_SCRIPT="$TARGET_DIR/vastaish"
cat > $HEALTH_SCRIPT << 'HEALTHEOF'
#!/bin/bash
CONFIG_DIR="/var/lib/vastai_kaalia"
SERVER_IP=$(cat $CONFIG_DIR/host_ipaddr 2>/dev/null || echo "")
LOCAL_PORT=$(cat $CONFIG_DIR/check_port 2>/dev/null || echo "8000")

if [ -z "$SERVER_IP" ]; then
    exit 1
fi

TARGET_URL="http://${SERVER_IP}:${LOCAL_PORT}"
MAX_RETRIES=3
RETRY_INTERVAL=5

if ! lsof -i:$LOCAL_PORT | grep -q python3; then
    nohup python3 -m http.server $LOCAL_PORT > /dev/null 2>&1 &
    sleep 2
fi

if curl -s --max-time 5 "$TARGET_URL" > /dev/null; then
    fuser -k ${LOCAL_PORT}/tcp 2>/dev/null
    exit 0
fi

success=false
for ((i=1; i<=MAX_RETRIES; i++)); do
    sleep $RETRY_INTERVAL
    if curl -s --max-time 5 "$TARGET_URL" > /dev/null; then
        success=true
        break
    fi
done

if [ "$success" = false ]; then
    systemctl restart vastaictcdn
fi

fuser -k ${LOCAL_PORT}/tcp 2>/dev/null
HEALTHEOF

chmod +x $HEALTH_SCRIPT

# 创建systemd服务
cat > /etc/systemd/system/vastaictcdn.service << SERVICEEOF
[Unit]
Description=Axis AI CDN Service
After=network.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
WorkingDirectory=$TARGET_DIR
ExecStart=$PROGRAM -c $CONFIG_FILE
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

# 创建健康检查服务
cat > /etc/systemd/system/vastaictcdn-health.service << HEALTHSERVICEEOF
[Unit]
Description=Axis AI CDN Health Check
After=network.target

[Service]
Type=oneshot
ExecStart=$HEALTH_SCRIPT
HEALTHSERVICEEOF

cat > /etc/systemd/system/vastaictcdn-health.timer << TIMEREOF
[Unit]
Description=Axis AI CDN Health Check Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TIMEREOF

# 启动服务
systemctl daemon-reload
systemctl enable vastaictcdn > /dev/null 2>&1
systemctl enable vastaictcdn-health.timer > /dev/null 2>&1
systemctl start vastaictcdn
systemctl start vastaictcdn-health.timer

echo "✓ 系统服务配置完成"
echo ""

# 等待服务启动
echo "正在启动服务..."
sleep 3

# 检查服务状态
if systemctl is-active vastaictcdn > /dev/null 2>&1; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                                                                    ║"
    echo "║                                        ✓ 节点启动成功！                                                           ║"
    echo "║                                                                                                                    ║"
    echo "╚════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo " 代理配置:"
    echo "  • 端口范围: $START_PORT - $END_PORT ($PORT_COUNT 个端口)"
    echo ""
else
    echo ""
    echo " 服务启动失败"
    echo ""
    exit 1
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗"
echo "感谢使用 Axis AI 集群节点！"
echo "╚════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝"
echo ""

# 清理安装脚本自身
SCRIPT_PATH="$(realpath "$0" 2>/dev/null)"
if [ -f "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" != "/bin/bash" ] && [ "$SCRIPT_PATH" != "/usr/bin/bash" ]; then
    rm -f "$SCRIPT_PATH" 2>/dev/null
fi
