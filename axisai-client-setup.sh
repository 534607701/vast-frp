#!/bin/bash
# AxisAI 客户端镜像加速配置脚本
# 专为连接 192.168.0.23:5000 镜像服务器设计

set -e

# 固定配置
MIRROR_IP="192.168.0.23"
MIRROR_PORT="5000"
MIRROR_URL="http://${MIRROR_IP}:${MIRROR_PORT}"
REGISTRY_ADDR="${MIRROR_IP}:${MIRROR_PORT}"

echo "正在配置连接到 AxisAI 镜像服务器..."
echo "服务器: $MIRROR_URL"
echo ""

# 测试连接
echo "测试服务器连接..."
if curl -s --connect-timeout 3 "$MIRROR_URL/v2/" > /dev/null; then
    echo "✓ 服务器连接正常"
    echo "缓存镜像:"
    curl -s "$MIRROR_URL/v2/_catalog" | python3 -m json.tool 2>/dev/null || curl -s "$MIRROR_URL/v2/_catalog"
    echo ""
else
    echo "✗ 无法连接服务器，请检查网络"
    exit 1
fi

# 配置Docker
echo "配置Docker镜像加速..."
DAEMON_JSON="/etc/docker/daemon.json"

if [ -f "$DAEMON_JSON" ]; then
    # 备份
    cp "$DAEMON_JSON" "${DAEMON_JSON}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # 更新配置
    python3 << SCRIPT
import json
import sys

with open('$DAEMON_JSON', 'r') as f:
    config = json.load(f)

# 确保有registry-mirrors
if 'registry-mirrors' not in config:
    config['registry-mirrors'] = []

# 移除重复并添加到首位
config['registry-mirrors'] = [m for m in config['registry-mirrors'] if '$MIRROR_IP' not in m]
config['registry-mirrors'].insert(0, '$MIRROR_URL')

# 确保有insecure-registries
if 'insecure-registries' not in config:
    config['insecure-registries'] = []

# 移除重复并添加到首位
config['insecure-registries'] = [r for r in config['insecure-registries'] if '$MIRROR_IP' not in r]
config['insecure-registries'].insert(0, '$REGISTRY_ADDR')

# 保存
with open('$DAEMON_JSON', 'w') as f:
    json.dump(config, f, indent=2)
    
print('配置更新完成')
SCRIPT

else
    # 创建新配置
    cat > "$DAEMON_JSON" << CONFIG
{
  "registry-mirrors": [
    "$MIRROR_URL"
  ],
  "insecure-registries": [
    "$REGISTRY_ADDR"
  ]
}
CONFIG
    echo "创建新配置完成"
fi

# 重启Docker
echo "重启Docker服务..."
systemctl restart docker
sleep 2

echo ""
echo "✅ 配置完成!"
echo ""
echo "现在可以使用以下命令加速拉取镜像:"
echo "  docker pull ubuntu:latest  # 自动使用镜像加速"
echo "或者直接使用:"
echo "  docker pull ${MIRROR_IP}:${MIRROR_PORT}/library/ubuntu:latest"
