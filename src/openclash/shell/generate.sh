#!/bin/bash
# Clash 配置生成脚本
# 读取 config.yaml 配置并调用 subconverter 服务生成配置文件

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
SUBCONVERTER_BIN="/Users/user/Documents/develop/subconverter/subconverter/subconverter"
SERVICE_PORT=25500

# 检查配置文件是否存在
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "错误: 配置文件不存在: $CONFIG_FILE"
    exit 1
fi

# 检查 yq 是否安装 (用于解析 yaml)
if ! command -v yq &> /dev/null; then
    echo "错误: 需要安装 yq 来解析 yaml 配置"
    echo "安装方式: brew install yq"
    exit 1
fi

# 检查 subconverter 服务是否运行
check_service() {
    if lsof -i :${SERVICE_PORT} &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 启动 subconverter 服务
start_service() {
    if [[ ! -f "$SUBCONVERTER_BIN" ]]; then
        echo "错误: subconverter 可执行文件不存在: $SUBCONVERTER_BIN"
        exit 1
    fi

    echo "正在启动 subconverter 服务..."

    # 切换到 subconverter 目录并后台启动
    SUBCONVERTER_DIR="$(dirname "$SUBCONVERTER_BIN")"
    (cd "$SUBCONVERTER_DIR" && nohup ./subconverter > /dev/null 2>&1 &)

    # 等待服务启动
    echo "等待服务启动..."
    for i in {1..10}; do
        sleep 1
        if check_service; then
            echo "✅ subconverter 服务已启动 (端口: ${SERVICE_PORT})"
            return 0
        fi
        echo "等待中... ($i/10)"
    done

    echo "❌ 服务启动超时"
    exit 1
}

# 检查并启动服务
if check_service; then
    echo "✅ subconverter 服务已运行 (端口: ${SERVICE_PORT})"
else
    echo "⚠️  subconverter 服务未运行"
    start_service
fi

# 读取配置
SERVICE_URL=$(yq '.serviceUrl' "$CONFIG_FILE")
TARGET_URL=$(yq '.targetUrl' "$CONFIG_FILE")
CONFIG=$(yq '.config' "$CONFIG_FILE")
OUTPUT=$(yq '.output' "$CONFIG_FILE")
EXCLUDE=$(yq '.exclude' "$CONFIG_FILE")
TARGET=$(yq '.target' "$CONFIG_FILE")
EMOJI=$(yq '.emoji' "$CONFIG_FILE")
LIST=$(yq '.list' "$CONFIG_FILE")
UDP=$(yq '.udp' "$CONFIG_FILE")
SCV=$(yq '.scv' "$CONFIG_FILE")

# 处理输出路径 (支持相对路径)
if [[ "$OUTPUT" != /* ]]; then
    OUTPUT="${SCRIPT_DIR}/${OUTPUT}"
fi

# URL 编码函数
urlencode() {
    python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))"
}

# 构建请求 URL
ENCODED_URL=$(urlencode "$TARGET_URL")
ENCODED_CONFIG=$(urlencode "$CONFIG")
ENCODED_EXCLUDE=$(urlencode "$EXCLUDE")

REQUEST_URL="${SERVICE_URL}?target=${TARGET}&url=${ENCODED_URL}&config=${ENCODED_CONFIG}&exclude=${ENCODED_EXCLUDE}"

# 添加可选参数
if [[ "$EMOJI" == "true" ]]; then
    REQUEST_URL="${REQUEST_URL}&emoji=true"
fi

if [[ "$LIST" == "true" ]]; then
    REQUEST_URL="${REQUEST_URL}&list=true"
fi

if [[ "$UDP" == "true" ]]; then
    REQUEST_URL="${REQUEST_URL}&udp=true"
fi

if [[ "$SCV" == "true" ]]; then
    REQUEST_URL="${REQUEST_URL}&scv=true"
fi

echo "========================================="
echo "Clash 配置生成器"
echo "========================================="
echo "服务地址: $SERVICE_URL"
echo "订阅地址: $TARGET_URL"
echo "配置文件: $CONFIG"
echo "排除规则: $EXCLUDE"
echo "输出文件: $OUTPUT"
echo "========================================="
echo ""
echo "正在生成配置..."

# 调用服务并保存结果
HTTP_CODE=$(curl -s -w "%{http_code}" -o "$OUTPUT" -L "$REQUEST_URL")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "✅ 配置生成成功!"
    echo "📄 文件路径: $OUTPUT"
    echo ""
    # 显示文件大小
    FILE_SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
    echo "📊 文件大小: $FILE_SIZE"
else
    echo "❌ 配置生成失败! HTTP 状态码: $HTTP_CODE"
    cat "$OUTPUT"
    rm -f "$OUTPUT"
    exit 1
fi