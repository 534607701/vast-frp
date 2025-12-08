!/bin/bash
set -e  # 遇到错误时退出

echo "========================================="
echo "Docker镜像缓存服务器一键优化脚本"
echo "开始时间: $(date)"
echo "========================================="

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志文件
LOG_DIR="/var/log/docker-cache"
mkdir -p $LOG_DIR
MAIN_LOG="$LOG_DIR/optimization-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$MAIN_LOG") 2>&1

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# ==================== 步骤1: 创建网络监控脚本 ====================
echo -e "\n${YELLOW}步骤1: 创建网络监控脚本${NC}"

cat > /usr/local/bin/check-network-enhanced << 'EOF'
#!/bin/bash
# 增强版网络监控脚本
LOG_DIR="/var/log/docker-cache"
mkdir -p $LOG_DIR
LOG_FILE="$LOG_DIR/network-check.log"
ALERT_FILE="$LOG_DIR/network-alert.log"

echo "=== 网络健康检查 $(date) ===" | tee -a $LOG_FILE

STATUS="HEALTHY"
FAILURES=()

# 1. 检查DNS解析
echo "1. 检查DNS服务..." | tee -a $LOG_FILE
if nslookup registry-1.docker.io &>/dev/null; then
    echo "  DNS解析: 正常" | tee -a $LOG_FILE
else
    echo "  DNS解析: 失败" | tee -a $LOG_FILE
    FAILURES+=("DNS解析失败")
    STATUS="UNHEALTHY"
    
    # 尝试自动修复
    echo "  尝试修复DNS..." | tee -a $LOG_FILE
    systemctl restart systemd-resolved 2>/dev/null
    sleep 2
    
    # 检查修复结果
    if nslookup registry-1.docker.io &>/dev/null; then
        echo "  DNS修复: 成功" | tee -a $LOG_FILE
    else
        echo "  DNS修复: 失败" | tee -a $LOG_FILE
        # 使用备用DNS
        echo "nameserver 8.8.8.8" > /etc/resolv.conf.tmp
        echo "nameserver 114.114.114.114" >> /etc/resolv.conf.tmp
        cp /etc/resolv.conf.tmp /etc/resolv.conf 2>/dev/null || true
    fi
fi

# 2. 检查外网连通性
echo "2. 检查外网连通性..." | tee -a $LOG_FILE
if ping -c 2 -W 1 8.8.8.8 &>/dev/null; then
    echo "  外网连接: 正常" | tee -a $LOG_FILE
else
    echo "  外网连接: 失败" | tee -a $LOG_FILE
    FAILURES+=("外网连接失败")
    STATUS="UNHEALTHY"
fi

# 3. 检查缓存服务
echo "3. 检查缓存服务..." | tee -a $LOG_FILE
if curl -s -f http://localhost:5000/v2/ &>/dev/null; then
    echo "  缓存服务: 运行正常" | tee -a $LOG_FILE
else
    echo "  缓存服务: 运行异常" | tee -a $LOG_FILE
    FAILURES+=("缓存服务异常")
    STATUS="UNHEALTHY"
    
    # 尝试重启缓存服务
    echo "  尝试重启缓存服务..." | tee -a $LOG_FILE
    docker restart docker-registry 2>/dev/null || true
    sleep 3
fi

# 4. 检查Docker服务
echo "4. 检查Docker服务..." | tee -a $LOG_FILE
if systemctl is-active --quiet docker; then
    echo "  Docker服务: 运行正常" | tee -a $LOG_FILE
else
    echo "  Docker服务: 停止" | tee -a $LOG_FILE
    FAILURES+=("Docker服务停止")
    STATUS="UNHEALTHY"
fi

# 5. 检查存储空间
echo "5. 检查存储空间..." | tee -a $LOG_FILE
DISK_USAGE=$(df -h /var/lib/registry 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
if [ -n "$DISK_USAGE" ]; then
    echo "  存储使用率: ${DISK_USAGE}%" | tee -a $LOG_FILE
    if [ "$DISK_USAGE" -gt 90 ]; then
        echo "  警告: 存储空间不足!" | tee -a $LOG_FILE
        FAILURES+=("存储空间不足 (${DISK_USAGE}%)")
        STATUS="WARNING"
    fi
fi

# 生成摘要报告
echo "" | tee -a $LOG_FILE
echo "=== 检查摘要 ===" | tee -a $LOG_FILE
echo "总体状态: $STATUS" | tee -a $LOG_FILE
echo "检查时间: $(date)" | tee -a $LOG_FILE

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "发现的问题:" | tee -a $LOG_FILE
    for failure in "${FAILURES[@]}"; do
        echo "  - $failure" | tee -a $LOG_FILE
    done
    
    # 记录到警报文件
    echo "[$(date)] 状态: $STATUS, 问题: ${FAILURES[*]}" >> $ALERT_FILE
    
    # 如果有严重问题，可以在这里添加发送邮件的代码
    # 例如: echo "Subject: 缓存服务器报警" | sendmail admin@example.com
fi

echo "检查完成: $(date)" | tee -a $LOG_FILE
EOF

chmod +x /usr/local/bin/check-network-enhanced
print_status "网络监控脚本创建完成"

# ==================== 步骤2: 创建镜像同步脚本 ====================
echo -e "\n${YELLOW}步骤2: 创建镜像同步脚本${NC}"

cat > /usr/local/bin/sync-key-images << 'EOF'
#!/bin/bash
# 关键镜像同步脚本
LOG_DIR="/var/log/docker-cache"
mkdir -p $LOG_DIR
LOG_FILE="$LOG_DIR/image-sync-$(date +%Y%m%d).log"

echo "=== 关键镜像同步开始: $(date) ===" >> $LOG_FILE

# 定义关键镜像及其标签
declare -A KEY_IMAGES=(
    ["vastai/pytorch"]="cuda-12.8.1-auto latest cuda-11.8.0-auto cuda-12.1.1-auto"
    ["vastai/tensorflow"]="latest"
    ["ubuntu"]="22.04 20.04"
    ["python"]="3.9-slim 3.11-slim"
    ["nginx"]="alpine"
    ["redis"]="alpine"
    ["alpine"]="latest"
)

# 同步函数
sync_image() {
    local image=$1
    local tag=$2
    local full_tag="$image:$tag"
    
    echo "[$(date)] 同步: $full_tag" >> $LOG_FILE
    
    # 检查是否已存在
    if curl -s -f "http://localhost:5000/v2/${image//\//\/}/manifests/$tag" &>/dev/null; then
        echo "  镜像已存在，检查更新..." >> $LOG_FILE
    fi
    
    # 拉取镜像
    if docker pull $full_tag 2>&1 | tee -a $LOG_FILE | grep -q "Downloaded\|Image is up to date"; then
        echo "  同步成功" >> $LOG_FILE
        return 0
    else
        echo "  同步失败或镜像已是最新" >> $LOG_FILE
        return 1
    fi
}

# 执行同步
for IMAGE in "${!KEY_IMAGES[@]}"; do
    echo "" >> $LOG_FILE
    echo "处理镜像: $IMAGE" >> $LOG_FILE
    for TAG in ${KEY_IMAGES[$IMAGE]}; do
        sync_image "$IMAGE" "$TAG"
        sleep 1  # 避免请求过快
    done
done

# 记录统计信息
echo "" >> $LOG_FILE
echo "=== 同步统计 ===" >> $LOG_FILE
echo "同步时间: $(date)" >> $LOG_FILE
echo "镜像仓库总数: $(curl -s http://localhost:5000/v2/_catalog 2>/dev/null | grep -o '"' | wc -l | awk '{print int($1/2)}' || echo 'N/A')" >> $LOG_FILE
echo "存储使用: $(du -sh /var/lib/registry/ 2>/dev/null | cut -f1 || echo '未知')" >> $LOG_FILE

echo "=== 关键镜像同步结束: $(date) ===" >> $LOG_FILE
EOF

chmod +x /usr/local/bin/sync-key-images
print_status "镜像同步脚本创建完成"

# ==================== 步骤3: 创建清理脚本 ====================
echo -e "\n${YELLOW}步骤3: 创建清理脚本${NC}"

cat > /usr/local/bin/cleanup-old-logs << 'EOF'
#!/bin/bash
# 日志清理脚本
LOG_DIR="/var/log/docker-cache"
DAYS_TO_KEEP=30

echo "开始清理旧日志文件 (保留最近 ${DAYS_TO_KEEP} 天)..."

# 清理网络检查日志
find $LOG_DIR -name "network-check.log" -type f -mtime +$DAYS_TO_KEEP -delete

# 清理镜像同步日志
find $LOG_DIR -name "image-sync-*.log" -type f -mtime +$DAYS_TO_KEEP -delete

# 清理优化日志
find $LOG_DIR -name "optimization-*.log" -type f -mtime +$DAYS_TO_KEEP -delete

# 清理空目录
find $LOG_DIR -type d -empty -delete

echo "日志清理完成: $(date)"
EOF

chmod +x /usr/local/bin/cleanup-old-logs
print_status "日志清理脚本创建完成"

# ==================== 步骤4: 配置定时任务 ====================
echo -e "\n${YELLOW}步骤4: 配置定时任务${NC}"

# 创建cron目录（如果不存在）
mkdir -p /etc/cron.d

# 创建定时任务配置文件
cat > /etc/cron.d/docker-cache-maintenance << 'EOF'
# Docker镜像缓存服务器维护任务
# 分钟 小时 日 月 周 用户 命令

# 每小时检查一次网络和服务健康
0 * * * * root /usr/local/bin/check-network-enhanced

# 每天凌晨2点同步关键镜像
0 2 * * * root /usr/local/bin/sync-key-images

# 每天凌晨3点检查并更新vastai核心镜像
30 3 * * * root docker pull vastai/pytorch:cuda-12.8.1-auto && docker pull vastai/tensorflow:latest

# 每周一凌晨4点清理旧日志
0 4 * * 1 root /usr/local/bin/cleanup-old-logs

# 每天凌晨5点检查存储空间，超过85%时发出警告
0 5 * * * root df -h /var/lib/registry | grep -v Filesystem | awk '{if(int($5)>85) print "警告: 存储使用率 "$5"%"}' >> /var/log/docker-cache/disk-alert.log
EOF

print_status "定时任务配置完成"

# ==================== 步骤5: 创建状态查看脚本 ====================
echo -e "\n${YELLOW}步骤5: 创建状态查看脚本${NC}"

cat > /usr/local/bin/cache-status << 'EOF'
#!/bin/bash
# 缓存服务器状态查看脚本

echo "========================================="
echo "Docker镜像缓存服务器状态"
echo "检查时间: $(date)"
echo "========================================="

# 1. 服务状态
echo "1. 服务状态:"
if systemctl is-active --quiet docker; then
    echo "  Docker服务: 运行中"
else
    echo "  Docker服务: 停止"
fi

if docker ps | grep -q docker-registry; then
    echo "  缓存服务: 运行中"
    REGISTRY_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' docker-registry 2>/dev/null || echo "localhost")
    echo "  服务地址: ${REGISTRY_IP}:5000"
else
    echo "  缓存服务: 未运行"
fi

# 2. 缓存内容
echo -e "\n2. 缓存内容:"
REPO_COUNT=$(curl -s http://localhost:5000/v2/_catalog 2>/dev/null | grep -o '"' | wc -l | awk '{print int($1/2)}' 2>/dev/null || echo "未知")
echo "  镜像仓库数量: $REPO_COUNT"

# 3. 存储信息
echo -e "\n3. 存储信息:"
if [ -d "/var/lib/registry" ]; then
    SIZE=$(du -sh /var/lib/registry 2>/dev/null | cut -f1)
    DISK_USAGE=$(df -h /var/lib/registry 2>/dev/null | tail -1 | awk '{print $5}')
    echo "  缓存大小: $SIZE"
    echo "  磁盘使用率: $DISK_USAGE"
else
    echo "  缓存目录不存在"
fi

# 4. 关键镜像状态
echo -e "\n4. 关键镜像状态:"
KEY_IMAGES=(
    "vastai/pytorch:cuda-12.8.1-auto"
    "vastai/tensorflow:latest"
    "ubuntu:22.04"
    "python:3.9-slim"
)

for IMAGE in "${KEY_IMAGES[@]}"; do
    REPO=$(echo $IMAGE | cut -d: -f1)
    TAG=$(echo $IMAGE | cut -d: -f2)
    if curl -s -I "http://localhost:5000/v2/$REPO/manifests/$TAG" 2>/dev/null | grep -q "200 OK"; then
        echo "  $IMAGE: 已缓存"
    else
        echo "  $IMAGE: 未缓存"
    fi
done

# 5. 最近日志
echo -e "\n5. 最近活动:"
LOG_DIR="/var/log/docker-cache"
if [ -f "$LOG_DIR/network-check.log" ]; then
    echo "  最后网络检查: $(tail -1 $LOG_DIR/network-check.log 2>/dev/null | cut -d' ' -f2- || echo '无记录')"
fi

echo "========================================="
echo "常用命令:"
echo "  查看详细状态: cache-status"
echo "  手动同步镜像: sync-key-images"
echo "  检查网络健康: check-network-enhanced"
echo "  查看缓存列表: curl http://localhost:5000/v2/_catalog | jq"
echo "========================================="
EOF

chmod +x /usr/local/bin/cache-status
print_status "状态查看脚本创建完成"

# ==================== 步骤6: 测试所有功能 ====================
echo -e "\n${YELLOW}步骤6: 测试所有功能${NC}"

# 测试网络监控脚本
echo "测试网络监控脚本..."
/usr/local/bin/check-network-enhanced
if [ $? -eq 0 ]; then
    print_status "网络监控脚本测试通过"
else
    print_warning "网络监控脚本测试异常，但继续执行"
fi

# 显示状态
echo -e "\n${YELLOW}最终状态检查:${NC}"
/usr/local/bin/cache-status

# ==================== 步骤7: 创建管理菜单 ====================
echo -e "\n${YELLOW}步骤7: 创建管理菜单脚本${NC}"

cat > /usr/local/bin/cache-manager << 'EOF'
#!/bin/bash
# 缓存服务器管理菜单

while true; do
    clear
    echo "========================================="
    echo "Docker镜像缓存服务器管理菜单"
    echo "========================================="
    echo "1. 查看服务器状态"
    echo "2. 立即检查网络健康"
    echo "3. 立即同步关键镜像"
    echo "4. 查看缓存镜像列表"
    echo "5. 查看系统日志"
    echo "6. 清理旧日志文件"
    echo "7. 重启缓存服务"
    echo "8. 查看存储使用情况"
    echo "9. 退出"
    echo "========================================="
    read -p "请选择操作 (1-9): " choice
    
    case $choice in
        1)
            /usr/local/bin/cache-status
            read -p "按回车键继续..."
            ;;
        2)
            echo "执行网络健康检查..."
            /usr/local/bin/check-network-enhanced
            read -p "按回车键继续..."
            ;;
        3)
            echo "开始同步关键镜像..."
            /usr/local/bin/sync-key-images
            read -p "按回车键继续..."
            ;;
        4)
            echo "缓存镜像列表:"
            curl -s http://localhost:5000/v2/_catalog | jq . 2>/dev/null || curl -s http://localhost:5000/v2/_catalog
            echo ""
            read -p "按回车键继续..."
            ;;
        5)
            echo "最近日志:"
            tail -20 /var/log/docker-cache/network-check.log 2>/dev/null || echo "日志文件不存在"
            read -p "按回车键继续..."
            ;;
        6)
            echo "清理旧日志..."
            /usr/local/bin/cleanup-old-logs
            read -p "按回车键继续..."
            ;;
        7)
            echo "重启缓存服务..."
            docker restart docker-registry
            sleep 3
            echo "服务重启完成"
            read -p "按回车键继续..."
            ;;
        8)
            echo "存储使用情况:"
            df -h /var/lib/registry
            echo ""
            du -sh /var/lib/registry/*
            read -p "按回车键继续..."
            ;;
        9)
            echo "退出管理菜单"
            exit 0
            ;;
        *)
            echo "无效选择，请重新输入"
            sleep 1
            ;;
    esac
done
EOF

chmod +x /usr/local/bin/cache-manager
print_status "管理菜单脚本创建完成"

# ==================== 完成总结 ====================
echo -e "\n${GREEN}=========================================${NC}"
echo -e "${GREEN}一键优化完成!${NC}"
echo -e "${GREEN}=========================================${NC}"

echo -e "\n已创建的工具和脚本:"
echo "1. 网络监控: /usr/local/bin/check-network-enhanced"
echo "2. 镜像同步: /usr/local/bin/sync-key-images"
echo "3. 日志清理: /usr/local/bin/cleanup-old-logs"
echo "4. 状态查看: /usr/local/bin/cache-status"
echo "5. 管理菜单: /usr/local/bin/cache-manager"

echo -e "\n配置的定时任务:"
echo "• 每小时检查网络健康"
echo "• 每天凌晨2点同步关键镜像"
echo "• 每天凌晨3点更新vastai核心镜像"
echo "• 每周一清理旧日志"

echo -e "\n日志目录: /var/log/docker-cache/"
echo -e "\n使用方法:"
echo "• 查看状态: cache-status"
echo "• 管理菜单: cache-manager"
echo "• 手动同步: sync-key-images"

echo -e "\n${YELLOW}建议立即执行的检查:${NC}"
echo "1. 运行 'cache-status' 查看当前状态"
echo "2. 运行 'sync-key-images' 同步关键镜像"
echo "3. 确保定时任务已加载: systemctl restart cron"

echo -e "\n${GREEN}优化完成时间: $(date)${NC}"
