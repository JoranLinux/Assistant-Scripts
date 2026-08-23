#!/bin/bash
# ============================================================================
# Ubuntu (WSL) 初始化脚本
#
# 功能：
#   0. 将 apt 软件源切换为阿里云镜像（脚本执行的第一步）
#   1. 安装常用软件包（git、curl、unzip、build-essential 等）
#   2. 安装 zsh 并切换默认 shell 为 zsh
#   3. 安装 Oh My Zsh
#   4. 安装并启用 zsh 插件：git、z、zsh-autosuggestions、zsh-syntax-highlighting
#   5. 安装 ubuntu-desktop（GNOME 桌面）
#   6. 安装 xrdp，配置自签名证书，监听端口改为 3390
#
# 用法：
#   ./Ubuntu-wsl-set.sh
#
# 说明：
#   - 以普通用户运行即可（需要 sudo 权限，内部会自动调用）。
#   - 也可以 sudo ./Ubuntu-wsl-set.sh，脚本会自动把用户级配置应用到原始用户。
#   - 所有安装与提示信息输出完成后，脚本最后会直接切换到 zsh；
#     切换命令是最后一条语句，之后没有任何待执行的脚本代码。
#   - 安装 ubuntu-desktop 需要下载数 GB 软件包，请耐心等待。
#   - 脚本可重复执行，已完成的步骤会自动跳过。
# ============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# 仅支持 apt 系系统（Ubuntu / Debian）
if ! command -v apt-get >/dev/null 2>&1; then
  echo "此脚本仅适用于 Ubuntu/Debian 系系统" >&2
  exit 1
fi

SCRIPT_PATH="$(readlink -f "$0")"
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"

log()  { printf '\033[1;32m[setup ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[notice]\033[0m %s\n' "$*"; }

# root 直接执行命令，否则自动加 sudo
maybe_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# ----------------------------------------------------------------------------
# 0. 检查 Ubuntu 版本（执行脚本前先校验）
#    仅支持 Ubuntu 22.04 / 24.04 / 26.04，其余版本直接报错退出。
#    校验通过后设置全局变量 UBUNTU_VERSION / UBUNTU_CODENAME，
#    供后续软件镜像源配置按版本使用。
# ----------------------------------------------------------------------------
check_ubuntu_version() {
  local os_id version_id major minor

  if [ -r /etc/os-release ]; then
    . /etc/os-release
    os_id="${ID:-}"
    version_id="${VERSION_ID:-}"
  fi

  if [ "$os_id" != "ubuntu" ]; then
    echo "此脚本仅支持 Ubuntu 系统（当前系统 ID: ${os_id:-未知}）" >&2
    exit 1
  fi

  # 归一化版本号：22.04 / 22.04.1 统一为 22.04
  major="${version_id%%.*}"
  minor="${version_id#*.}"
  minor="${minor%%.*}"
  UBUNTU_VERSION="$major.$minor"

  case "$UBUNTU_VERSION" in
    22.04 | 24.04 | 26.04) ;;
    *)
      echo "不支持的 Ubuntu 版本: ${UBUNTU_VERSION}（此脚本仅支持 Ubuntu 22.04 / 24.04 / 26.04）" >&2
      exit 1
      ;;
  esac

  # 优先使用 /etc/os-release 中的代号，缺失时按版本号映射
  UBUNTU_CODENAME="${VERSION_CODENAME:-}"
  if [ -z "$UBUNTU_CODENAME" ]; then
    case "$UBUNTU_VERSION" in
      22.04) UBUNTU_CODENAME=jammy ;;
      24.04) UBUNTU_CODENAME=noble ;;
      26.04) UBUNTU_CODENAME=resolute ;;
    esac
  fi

  log "检测到 Ubuntu ${UBUNTU_VERSION}（${UBUNTU_CODENAME}），继续执行 ..."
}

# ----------------------------------------------------------------------------
# 0. 切换到阿里云 apt 镜像源（先于所有安装步骤执行）
#    同时兼容传统 sources.list 格式与 Ubuntu 24.04 的 deb822 格式
#    （/etc/apt/sources.list.d/ubuntu.sources）。
#    使用 http 而非 https：脚本刚开始时 ca-certificates 可能尚未安装，
#      https 证书校验可能失败，http 可避免这个引导问题。
#    修改前会自动备份原文件为 *.bak-aliyun。
#    按检测到的 Ubuntu 版本（UBUNTU_CODENAME）统一源中的套件名称。
# ----------------------------------------------------------------------------
set_aliyun_mirror() {
  log "Ubuntu ${UBUNTU_VERSION}（${UBUNTU_CODENAME}）：将 apt 软件源切换为阿里云镜像 ..."

  # 备份统一放到 /etc/apt/backups/ 目录：
  # apt 会扫描 sources.list.d/ 下所有文件，*.bak-aliyun 后缀不符合
  # .list/.sources 命名规则，会导致每次 apt 都打印
  # “Ignoring file ... invalid filename extension” 的提示。
  # /etc/apt/backups/ 不在 apt 的扫描范围内，可以避免这个噪音。
  local backup_dir=/etc/apt/backups
  maybe_sudo mkdir -p "$backup_dir"

  # 清理之前版本脚本遗留在扫描目录里的 *.bak-aliyun 备份
  local stray
  for stray in /etc/apt/sources.list.bak-aliyun /etc/apt/sources.list.d/*.bak-aliyun; do
    [ -e "$stray" ] || continue
    maybe_sudo mv "$stray" "$backup_dir/"
    log "已将旧备份移入 $backup_dir: $(basename "$stray")"
  done

  local f
  local candidates=()
  [ -f /etc/apt/sources.list ] && candidates+=(/etc/apt/sources.list)
  for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [ -e "$f" ] && candidates+=("$f")
  done

  local changed=0
  local any_aliyun=0
  for f in "${candidates[@]}"; do
    grep -q 'mirrors.aliyun.com' "$f" 2>/dev/null && any_aliyun=1

    if grep -qE 'https?://(archive|security|old-releases|ports)\.ubuntu\.com/' "$f" 2>/dev/null; then
      changed=1
      maybe_sudo cp "$f" "$backup_dir/$(basename "$f").bak-aliyun"
      maybe_sudo sed -i \
        -e 's|https\?://archive.ubuntu.com/ubuntu/|http://mirrors.aliyun.com/ubuntu/|g' \
        -e 's|https\?://security.ubuntu.com/ubuntu/|http://mirrors.aliyun.com/ubuntu/|g' \
        -e 's|https\?://old-releases.ubuntu.com/ubuntu/|http://mirrors.aliyun.com/ubuntu/|g' \
        -e 's|https\?://ports.ubuntu.com/ubuntu-ports/|http://mirrors.aliyun.com/ubuntu-ports/|g' \
        "$f"

      # 版本相关：将源文件中可能残留的其他版本套件名统一修正为当前版本，
      # 例如系统升级后遗留的 jammy / noble 等，避免源与系统版本不一致。
      local stale
      for stale in focal jammy noble resolute; do
        [ "$stale" = "$UBUNTU_CODENAME" ] && continue
        maybe_sudo sed -i -E \
          -e "s/\\b${stale}(-security|-updates|-backports|-proposed)?\\b/${UBUNTU_CODENAME}\\1/g" \
          "$f"
      done

      log "已替换: $f"
    fi
  done

  if [ "$changed" -eq 1 ]; then
    log "软件源已切换为阿里云镜像（原文件备份于 $backup_dir/）"
    maybe_sudo apt-get update
  elif [ "$any_aliyun" -eq 1 ]; then
    log "软件源已是阿里云镜像，跳过"
  else
    warn "未找到 Ubuntu 官方源（archive/security.ubuntu.com），跳过镜像切换"
  fi
}

# ----------------------------------------------------------------------------
# 用户级配置：Oh My Zsh、插件、.zshrc、GNOME over xrdp 兼容
# ----------------------------------------------------------------------------
user_setup() {
  local home="$1"
  local zshrc="$home/.zshrc"
  local zsh_dir="${ZSH:-$home/.oh-my-zsh}"
  local custom_dir="${ZSH_CUSTOM:-$zsh_dir/custom}"
  local plugins_dir="$custom_dir/plugins"
  local expected='plugins=(git z zsh-autosuggestions zsh-syntax-highlighting)'

  # 3. Oh My Zsh
  if [ ! -d "$zsh_dir" ]; then
    log "安装 Oh My Zsh ..."
    # --unattended : 不询问、不再次切换 shell
    # --keep-zshrc : 保留已有的 .zshrc
    # RUNZSH=no    : 安装完不要 exec zsh（否则会中断当前脚本的后续执行）
    RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc
  else
    log "Oh My Zsh 已存在，跳过安装"
  fi

  mkdir -p "$plugins_dir"

  # 4. 插件：git、z 是 Oh My Zsh 内置插件，只需在 plugins 列表中启用；
  #    zsh-autosuggestions、zsh-syntax-highlighting 需要单独克隆。
  if [ ! -d "$plugins_dir/zsh-autosuggestions" ]; then
    log "安装插件 zsh-autosuggestions ..."
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$plugins_dir/zsh-autosuggestions"
  else
    log "插件 zsh-autosuggestions 已存在"
  fi

  if [ ! -d "$plugins_dir/zsh-syntax-highlighting" ]; then
    log "安装插件 zsh-syntax-highlighting ..."
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "$plugins_dir/zsh-syntax-highlighting"
  else
    log "插件 zsh-syntax-highlighting 已存在"
  fi

  # 在 .zshrc 中启用插件
  if [ -f "$zshrc" ] && grep -Fqx "$expected" "$zshrc"; then
    log "插件已在 .zshrc 中启用，跳过"
  else
    if [ -f "$zshrc" ]; then
      sed -i 's/^plugins=(.*)$/plugins=(git z zsh-autosuggestions zsh-syntax-highlighting)/' "$zshrc"
    fi
    if [ ! -f "$zshrc" ] || ! grep -q '^plugins=' "$zshrc"; then
      printf '\n%s\n' "$expected" >> "$zshrc"
    fi
    log "已在 .zshrc 启用插件：git、z、zsh-autosuggestions、zsh-syntax-highlighting"
  fi

  # GNOME 通过 xrdp 连接时需要的会话环境（Ubuntu 桌面）
  local xsessionrc="$home/.xsessionrc"
  if [ ! -f "$xsessionrc" ] || ! grep -q 'XDG_CURRENT_DESKTOP' "$xsessionrc"; then
    cat > "$xsessionrc" <<'EOF'
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg
EOF
    log "已生成 ~/.xsessionrc（xrdp 连接 GNOME 所需）"
  fi
}

# ----------------------------------------------------------------------------
# 1. 常用软件包
# ----------------------------------------------------------------------------
install_common_packages() {
  log "安装常用软件包（git、curl、unzip 等）..."
  maybe_sudo apt-get update
  maybe_sudo apt-get install -y \
    git curl unzip wget ca-certificates gnupg \
    software-properties-common apt-transport-https \
    build-essential vim htop tree net-tools dbus-x11 vim npm
  git config --global user.name "Joran"
  git config --global user.email "zcj20080882@outlook.com"
  if command -v uv >/dev/null 2>&1; then
    log "uv 已安装（$(command -v uv)）"
  else
    log "安装 uv ..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  sudo npm install -g @openai/codex
  bash <(curl -fsSL https://cdn.deepseek.com/api-docs/codex-deepseek-setup.sh)
}

# ----------------------------------------------------------------------------
# 2. zsh 安装
#    注意：这里只安装 zsh 并确保它出现在 /etc/shells。
#    “切换 shell”统一放在脚本最后处理（switch_default_shell + exec zsh）：
#    中途用 exec zsh 切换会打断脚本，而放在最后切换则不会有任何遗留代码。
# ----------------------------------------------------------------------------
install_zsh() {
  if command -v zsh >/dev/null 2>&1; then
    log "zsh 已安装（$(command -v zsh)）"
  else
    log "安装 zsh ..."
    maybe_sudo apt-get install -y zsh
  fi

  local zsh_path
  zsh_path="$(command -v zsh)"

  # chsh 要求目标 shell 出现在 /etc/shells
  if ! grep -qxF "$zsh_path" /etc/shells 2>/dev/null; then
    echo "$zsh_path" | maybe_sudo tee -a /etc/shells >/dev/null
  fi
}

# ----------------------------------------------------------------------------
# 5. ubuntu-desktop（GNOME）
# ----------------------------------------------------------------------------
install_desktop() {
  if dpkg -s ubuntu-desktop >/dev/null 2>&1; then
    log "ubuntu-desktop 已安装，跳过"
  else
    log "安装 ubuntu-desktop（GNOME 桌面，需下载数 GB，请耐心等待）..."
    maybe_sudo apt-get install -y ubuntu-desktop
  fi

  # WSL 下 GDM 显示管理器与 xrdp 容易冲突，这里停用 GDM；
  # 如需要在控制台直接登录图形界面，可执行: sudo systemctl enable --now gdm3
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    maybe_sudo systemctl disable gdm3 2>/dev/null || true
  fi
}

# ----------------------------------------------------------------------------
# 6. xrdp：证书 + 端口 3390
# ----------------------------------------------------------------------------
install_xrdp() {
  if dpkg -s xrdp >/dev/null 2>&1; then
    log "xrdp 已安装，跳过"
    maybe_sudo apt-get install -y xorgxrdp || true
  else
    log "安装 xrdp ..."
    maybe_sudo apt-get install -y xrdp xorgxrdp
  fi

  # 6.1 自签名证书（缺失时生成）
  log "配置 xrdp 证书 ..."
  if [ ! -f /etc/xrdp/cert.pem ] || [ ! -f /etc/xrdp/key.pem ]; then
    maybe_sudo openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem \
      -days 3650 -subj "/C=CN/ST=Shanghai/L=Shanghai/O=WSL/CN=$(hostname)"
  fi
  maybe_sudo chown root:xrdp /etc/xrdp/cert.pem /etc/xrdp/key.pem
  maybe_sudo chmod 640 /etc/xrdp/cert.pem /etc/xrdp/key.pem

  # 6.2 xrdp.ini 指向证书
  maybe_sudo sed -i 's|^certificate=.*|certificate=/etc/xrdp/cert.pem|' /etc/xrdp/xrdp.ini
  maybe_sudo sed -i 's|^key_file=.*|key_file=/etc/xrdp/key.pem|' /etc/xrdp/xrdp.ini

  # 6.3 监听端口 3389 -> 3390
  if grep -q '^port=3389' /etc/xrdp/xrdp.ini; then
    maybe_sudo sed -i 's|^port=3389|port=3390|' /etc/xrdp/xrdp.ini
  elif ! grep -q '^port=3390' /etc/xrdp/xrdp.ini; then
    maybe_sudo sed -i 's|^port=.*|port=3390|' /etc/xrdp/xrdp.ini
  fi
  log "xrdp 监听端口已设置为 3390"

  # 6.4 用户加入 ssl-cert 组，可读取证书
  maybe_sudo usermod -aG ssl-cert "$TARGET_USER"

  # 6.5 GNOME 颜色管理 polkit 授权（避免 xrdp 会话里 colord 报错）
  local pkla="/etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla"
  if [ ! -f "$pkla" ]; then
    log "添加 GNOME colord polkit 授权 ..."
    maybe_sudo mkdir -p "$(dirname "$pkla")"
    printf '%s\n' \
      '[Allow Colord all Users]' \
      'Identity=unix-user:*' \
      'Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile' \
      'ResultAny=no' \
      'ResultInactive=no' \
      'ResultActive=yes' | maybe_sudo tee "$pkla" >/dev/null
  fi

  # 6.6 防火墙放行（WSL 一般默认无防火墙，规则留着无妨）
  if command -v ufw >/dev/null 2>&1; then
    maybe_sudo ufw allow 3390/tcp >/dev/null 2>&1 || true
  fi

  # 6.7 修复 xrdp 连接黑屏：
  #     Ubuntu 22.04+ 默认 GNOME 是 Wayland 优先，而 xrdp 只能提供 X11；
  #     走通用 /etc/X11/Xsession 启动的是“vanilla”GNOME 会话，
  #     在 xrdp/WSLg 下经常直接失败（黑屏，日志里常见
  #     gnome-session-check-accelerated: no X11 display found）。
  #     参照 xrdp 官方 wiki（Running GNOME on Ubuntu 24.04 LTS）的做法：
  #     在 startwm.sh 里检测默认会话是否为 GNOME，是则直接以 GDM 相同的
  #     环境启动 gnome-session --session=ubuntu；同时清掉 WSLg 注入的
  #     WAYLAND_DISPLAY 并强制 GDK 走 X11，避免 GDK 连到 WSLg 的 Wayland。
  #     若用户已有 ~/.xsession / ~/.Xsession，则尊重用户自定义会话。
  local startwm=/etc/xrdp/startwm.sh
  if [ -f "$startwm" ] && ! grep -q 'xrdp-gnome-fix' "$startwm"; then
    log "修复 xrdp 黑屏：更新 startwm.sh 直启 Ubuntu GNOME 会话 ..."
    maybe_sudo cp "$startwm" "$startwm.bak"

    local fixfile tmpfile
    fixfile="$(mktemp)"
    tmpfile="$(mktemp)"
    cat > "$fixfile" <<'GNOME_FIX_BLOCK'

# --- xrdp-gnome-fix: xrdp 直启 Ubuntu GNOME 会话（修复黑屏） ---
# 通用 Xsession 启动的 vanilla GNOME 会话在 xrdp 下经常失败；
# 检测默认会话是否为 GNOME，是则按 GDM 的方式直接启动 ubuntu 会话。
# 同时清理 WSLg 注入的 WAYLAND_DISPLAY，强制 GDK 使用 X11。
unset WAYLAND_DISPLAY 2>/dev/null || true
export XDG_SESSION_TYPE=x11
export GDK_BACKEND=x11

USERXSESSION=$HOME/.xsession
ALTUSERXSESSION=$HOME/.Xsession
ERRFILE=$HOME/.xsession-errors

using_gnome=
if [ -e "$USERXSESSION" ] || [ -e "$ALTUSERXSESSION" ]; then
	: # 用户已指定自己的会话，尊重用户选择
elif [ -e /usr/bin/x-session-manager ]; then
	case "$(readlink -f /usr/bin/x-session-manager)" in
		*/gnome-session) using_gnome=1 ;;
	esac
fi

if [ -n "$using_gnome" ]; then
	export DESKTOP_SESSION=ubuntu-xorg
	export XDG_SESSION_DESKTOP="$DESKTOP_SESSION"
	export XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu-xorg:/etc/xdg
	export XDG_CURRENT_DESKTOP=ubuntu:GNOME
	export XDG_DATA_DIRS=/usr/share/"$DESKTOP_SESSION":/usr/share/gnome:/usr/local/share/:/usr/share/:/var/lib/snapd/desktop
	export GNOME_SHELL_SESSION_MODE=ubuntu
	exec >"$ERRFILE" 2>&1
	exec /usr/bin/gnome-session --session=ubuntu
fi
GNOME_FIX_BLOCK

    # 在 Xsession 启动行之前插入修复块（兼容有无 `test -x` 行两种写法）
    awk 'NR==FNR { block[NR]=$0; n=NR; next }
         !done && ($0 ~ /^[[:space:]]*test -x \/etc\/X11\/Xsession/ || $0 ~ /^[[:space:]]*exec \/bin\/sh \/etc\/X11\/Xsession/) {
           for (i=1; i<=n; i++) print block[i]
           done=1
         }
         { print }' "$fixfile" "$startwm" > "$tmpfile"
    maybe_sudo mv "$tmpfile" "$startwm"
    maybe_sudo chown root:root "$startwm"
    maybe_sudo chmod +x "$startwm"
    rm -f "$fixfile"

    if grep -q 'xrdp-gnome-fix' "$startwm"; then
      log "startwm.sh 已更新（备份：$startwm.bak）"
    else
      warn "未能自动修改 startwm.sh（未找到 Xsession 启动行），请手动编辑 $startwm"
    fi
  fi

  # 确保 startwm.sh 可被会话用户读取执行：
  # mktemp 生成的文件默认 600，mv 后需恢复 755，
  # 否则 xrdp 会话（以普通用户运行）会因无法读取脚本而直接黑屏。
  if [ -f "$startwm" ]; then
    maybe_sudo chmod 755 "$startwm"
  fi

  # 6.8 启动服务（优先 systemd，其次 service）
  log "启动 xrdp 服务 ..."
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    maybe_sudo systemctl enable xrdp >/dev/null 2>&1 || true
    if ! maybe_sudo systemctl restart xrdp >/dev/null 2>&1; then
      maybe_sudo service xrdp restart >/dev/null 2>&1 \
        || warn "xrdp 启动失败，请手动运行：sudo service xrdp start"
    fi
  else
    maybe_sudo service xrdp-sesman restart >/dev/null 2>&1 || true
    maybe_sudo service xrdp start >/dev/null 2>&1 \
      || warn "xrdp 启动失败，请手动运行：sudo service xrdp start"
  fi
}

# ----------------------------------------------------------------------------
# WSL 兼容：确保 systemd 启用（xrdp / 桌面服务依赖）
# ----------------------------------------------------------------------------
ensure_wsl_systemd() {
  if [ -d /run/systemd/system ]; then
    return 0 # systemd 已在运行
  fi
  if ! grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    return 0 # 非 WSL
  fi

  local conf=/etc/wsl.conf
  log "在 /etc/wsl.conf 中启用 systemd ..."
  if [ -f "$conf" ]; then
    maybe_sudo cp "$conf" "${conf}.bak"
  fi
  if [ -f "$conf" ] && grep -q '^systemd=' "$conf"; then
    maybe_sudo sed -i 's|^systemd=.*|systemd=true|' "$conf"
  elif [ -f "$conf" ] && grep -q '^\[boot\]' "$conf"; then
    maybe_sudo sed -i '/^\[boot\]/a systemd=true' "$conf"
  else
    printf '\n[boot]\nsystemd=true\n' | maybe_sudo tee -a "$conf" >/dev/null
  fi
  warn "已修改 /etc/wsl.conf 启用 systemd；请在 PowerShell 中执行 wsl --shutdown 后重新进入 WSL。"
}

# ----------------------------------------------------------------------------
# 切换默认 shell 为 zsh（放到所有安装步骤完成之后、输出汇总之前执行）
# ----------------------------------------------------------------------------
switch_default_shell() {
  local zsh_path
  zsh_path="$(command -v zsh)"

  local current_shell
  current_shell="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
  if [ "$current_shell" != "$zsh_path" ]; then
    log "切换默认 shell 为 zsh（$zsh_path）..."
    maybe_sudo chsh -s "$zsh_path" "$TARGET_USER"
    log "已切换，所有提示信息输出完成后当前终端将直接进入 zsh"
  else
    log "默认 shell 已是 zsh，跳过切换"
  fi
}

# ----------------------------------------------------------------------------
# 用户级步骤：普通用户直接执行，root 时切回原始用户执行
# ----------------------------------------------------------------------------
run_user_setup() {
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    log "以用户 $TARGET_USER 身份执行用户级配置 ..."
    su -s /bin/bash "$TARGET_USER" -c "bash '$SCRIPT_PATH' --user-setup"
  else
    user_setup "$TARGET_HOME"
  fi
}

# ----------------------------------------------------------------------------
# 汇总
# ----------------------------------------------------------------------------
summary() {
  local shell_now
  shell_now="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
  echo
  log "================================================================"
  log "初始化完成"
  log "  默认 shell : ${shell_now:-未知}（已切换为 zsh）"
  log "  Oh My Zsh  : $TARGET_HOME/.oh-my-zsh"
  log "  插件        : git、z、zsh-autosuggestions、zsh-syntax-highlighting"
  log "  桌面        : ubuntu-desktop（GNOME）"
  log "  xrdp        : 端口 3390，证书 /etc/xrdp/cert.pem"
  log ""
  log "  当前终端即将自动进入 zsh"
  log "  连接方式：Windows 远程桌面客户端 -> localhost:3390"
  log "  自签名证书会提示不受信任，选择“仍然连接”即可。"
  if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ':3390'; then
    log "  状态：xrdp 已在 3390 端口监听 ✓"
  else
    warn "  状态：暂未检测到 3390 端口监听，请检查：sudo service xrdp status"
  fi
  log "================================================================"
}

# ----------------------------------------------------------------------------
# 入口
# ----------------------------------------------------------------------------
if [ "${1:-}" = "--user-setup" ]; then
  # 由 run_user_setup 以目标用户身份调用，只执行用户级配置
  user_setup "$(getent passwd "$(id -un)" | cut -d: -f6)"
  exit 0
fi

# 执行前先校验 Ubuntu 版本，不支持则报错退出
check_ubuntu_version

main() {
  log "开始 Ubuntu WSL 初始化 ..."
  set_aliyun_mirror
  install_common_packages
  install_zsh
  run_user_setup
  install_desktop
  ensure_wsl_systemd
  install_xrdp
  switch_default_shell
  summary
}

main

# ----------------------------------------------------------------------------
# 最后一步：当前终端直接进入 zsh。
# exec 会替换当前 bash 进程，因此这条语句之后不会再有任何脚本代码执行；
# 上面的安装与提示信息（含汇总）都已完整输出。
# 仅当：标准输入是终端（交互运行）、非 root 方式执行、且当前不在 zsh 中时生效；
# 否则脚本正常结束，默认 shell 已由 switch_default_shell 改为 zsh。
# ----------------------------------------------------------------------------
if [ -t 0 ] && [ "$(id -u)" -ne 0 ] && [ -z "${ZSH_VERSION:-}" ]; then
  printf '\033[1;32m[setup ]\033[0m 所有配置完成，正在进入 zsh ...\n'
  exec zsh
fi
