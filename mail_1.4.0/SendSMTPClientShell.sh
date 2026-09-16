#!/bin/bash
set -e

SERVICE_NAME="smtpsender"
APP_PATH="/home/SendSMTPClientLinux"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_FILE="/etc/${SERVICE_NAME}/config.env"
ASSET_NAME="SendSMTPClientLinux"

# 前 7 个位置参数是安装器硬编码的接口，不可变更。
#   $2 = 中控地址 host:port —— 本脚本与发送端二进制都从它下发
# 额外参数（可选）：
#   $8 = release tag      $9 = 期望的 sha256
# 环境变量（可选，优先级低于位置参数）：
#   SMTP_RELEASE_TAG / SMTP_RELEASE_BASE / SMTP_RELEASE_SHA256 / SYSTEMD_OFFLINE / SMTP_CONTROL_PORT
RELEASE_TAG="${8:-${SMTP_RELEASE_TAG:-mail_1.4.0}}"

# ---- 下载基址：一律指向中控服务，不再走任何第三方托管 ----
# 优先级：SMTP_RELEASE_BASE > http://103.116.246.5:8621/asset（烘焙/下发的中控地址）> 由中控地址($2)推导
CONTROL_SERVER="$2"
CONTROL_HOST="${CONTROL_SERVER%%:*}"
case "$CONTROL_SERVER" in
  *:*) CONTROL_PORT="${CONTROL_SERVER##*:}" ;;
  *)   CONTROL_PORT="${SMTP_CONTROL_PORT:-8621}" ;;
esac
DERIVED_BASE="http://${CONTROL_HOST}:${CONTROL_PORT}/asset"
RELEASE_BASE="${SMTP_RELEASE_BASE:-https://raw.githubusercontent.com/yinweidong8650/guestx/refs/heads/main}"
if [ -z "$RELEASE_BASE" ]; then
  # 未烘焙时回落到从 $2 推导的中控地址
  RELEASE_BASE="$DERIVED_BASE"
fi
# 默认哈希由 prepare-release.ps1 在产出时注入，与该 tag 的 ELF 一一对应；
# 中控下发时 Server.BuildDeployScript 会按当前 tag 的 ELF 现算并覆盖这条默认值。
EXPECTED_SHA256="${9:-${SMTP_RELEASE_SHA256:-ddbff928088b262cff00e8459c546564a0811eb3eb9cdaee9f9d3929fdfe5238}}"
DOWNLOAD_URL="${RELEASE_BASE}/${RELEASE_TAG}/${ASSET_NAME}"
# 中控直发形态下资产挂在 /asset/<tag>/<name>；若中控未带 tag 子目录，回退到 /asset/<name>。
FALLBACK_URL="${RELEASE_BASE}/${ASSET_NAME}"

# 检查参数数量
if [ $# -lt 7 ]; then
  echo "用法: $0 <ARG1> <ARG2> <ARG3> <ARG4> <ARG5> <ARG6> <ARG7> [RELEASE_TAG] [SHA256]"
  exit 1
fi

ARG1=$1
ARG2=$2
ARG3=$3
ARG4=$4
ARG5=$5
ARG6=$6
ARG7=$7

echo ">>> 开始部署 ${SERVICE_NAME}"
echo ">>> 中控地址 ${CONTROL_HOST}:${CONTROL_PORT}"
echo ">>> 拉取地址 ${DOWNLOAD_URL}"
echo ">>> 备用地址 ${FALLBACK_URL}"
echo ">>> 版本 tag ${RELEASE_TAG}"

# ---- 1) 先下载到临时文件：下载或校验失败时，线上二进制与运行中的服务都保持原样 ----
TMP_PATH="$(mktemp "${APP_PATH}.new.XXXXXX")"
# 注意：EXIT trap 的返回值会成为脚本退出码。条件为假时 [ -n ] 返回 1，
# 会把「部署成功」覆盖成退出码 1，安装器会误判失败。必须显式 return 0。
cleanup() {
  if [ -n "$TMP_PATH" ]; then
    rm -f "$TMP_PATH"
  fi
  return 0
}
trap cleanup EXIT

fetch() {
  # $1 = 候选 URL；命中返回 0
  local url="$1" ok=1
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL -o "$TMP_PATH" "$url"; then return 0; fi
    ok=0
  fi
  if [ "$ok" -eq 1 ] && command -v wget >/dev/null 2>&1; then
    echo ">>> curl 不可用或失败，回退 wget"
    if wget -qO "$TMP_PATH" "$url"; then return 0; fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    echo ">>> 回退 python3 urllib"
    if python3 -c 'import sys,urllib.request;urllib.request.urlretrieve(sys.argv[1],sys.argv[2])' "$url" "$TMP_PATH"; then return 0; fi
  fi
  return 1
}

DOWNLOAD_OK=0
if fetch "$DOWNLOAD_URL"; then
  DOWNLOAD_OK=1
elif [ "$FALLBACK_URL" != "$DOWNLOAD_URL" ]; then
  echo ">>> 主地址未命中，尝试中控无 tag 路径"
  if fetch "$FALLBACK_URL"; then DOWNLOAD_OK=1; fi
fi

if [ "$DOWNLOAD_OK" -eq 0 ]; then
  echo ">>> 下载失败，未改动 ${APP_PATH}，服务保持运行: $DOWNLOAD_URL"
  exit 22
fi

# ---- 2) 完整性校验：有期望值就强校验，没有也至少确认是 ELF ----
if [ -n "$EXPECTED_SHA256" ]; then
  ACTUAL_SHA256="$(sha256sum "$TMP_PATH" | awk '{print $1}')"
  if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo ">>> 校验失败: 期望 ${EXPECTED_SHA256} 实际 ${ACTUAL_SHA256}"
    exit 23
  fi
  echo ">>> 校验通过 sha256=${ACTUAL_SHA256}"
fi

MAGIC="$(head -c 4 "$TMP_PATH" | od -An -tx1 | tr -d ' \n')"
if [ "$MAGIC" != "7f454c46" ]; then
  echo ">>> 校验失败: 不是 ELF 文件 (magic=${MAGIC})"
  exit 23
fi

# ---- 3) 校验通过后才停服务，然后原子替换 ----
chmod +x "$TMP_PATH"
if [ "${SYSTEMD_OFFLINE:-0}" != "1" ]; then
  echo ">>> 停止服务 ${SERVICE_NAME} (如果在运行)"
  sudo systemctl stop ${SERVICE_NAME} || echo "警告: 停止服务 ${SERVICE_NAME} 失败"
fi

echo ">>> 安装新二进制到 $APP_PATH"
mv -f "$TMP_PATH" "$APP_PATH"
TMP_PATH=""

# 保存参数到配置文件
echo ">>> 写入配置 $CONFIG_FILE"
sudo mkdir -p "$(dirname $CONFIG_FILE)"
sudo tee "$CONFIG_FILE" > /dev/null <<EOF
ARG1=$ARG1
ARG2=$ARG2
ARG3=$ARG3
ARG4=$ARG4
ARG5=$ARG5
ARG6=$ARG6
ARG7=$ARG7
EOF

# 每次都覆盖写入 systemd 服务文件
echo ">>> 写入 systemd 服务 $SERVICE_FILE"
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=SMTP Client Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/home
EnvironmentFile=$CONFIG_FILE
ExecStart=$APP_PATH "\${ARG1}" "\${ARG2}" "\${ARG3}" "\${ARG4}" "\${ARG5}" "\${ARG6}" "\${ARG7}"
Restart=always
RestartSec=5
StandardOutput=append:/var/log/${SERVICE_NAME}.log
StandardError=append:/var/log/${SERVICE_NAME}.err

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
if [ "${SYSTEMD_OFFLINE:-0}" != "1" ]; then
  echo ">>> 启动服务 ${SERVICE_NAME}"
  sudo systemctl daemon-reload
  sudo systemctl enable ${SERVICE_NAME}
  sudo systemctl restart ${SERVICE_NAME}
else
  echo ">>> SYSTEMD_OFFLINE=1，跳过 systemctl 调用"
fi

echo ">>> 部署完成 ✅"
echo "查看状态: systemctl status ${SERVICE_NAME}"
echo "查看日志: journalctl -u ${SERVICE_NAME} -f"
