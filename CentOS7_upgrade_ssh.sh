#!/bin/bash

# CentOS 7.8 系统更新和SSH升级脚本
# 功能：修改镜像源、更新系统、升级SSH版本

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限执行"
        exit 1
    fi
}

# 备份原始源配置
backup_repos() {
    log_step "备份原始镜像源配置..."
    if [ ! -d "/etc/yum.repos.d/backup" ]; then
        mkdir -p /etc/yum.repos.d/backup
    fi
    cp /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
    log_info "原始配置已备份到 /etc/yum.repos.d/backup/"
}

# 配置天翼云镜像源
setup_ctyun_repos() {
    log_step "配置天翼云镜像源..."
    
    # 禁用现有的repo文件
    find /etc/yum.repos.d/ -name "*.repo" -exec mv {} {}.bak \; 2>/dev/null || true
    
    # 创建CentOS-Base.repo
    cat > /etc/yum.repos.d/CentOS-Base.repo << 'EOF'
[base]
name=CentOS-$releasever - Base
baseurl=https://mirrors.ctyun.cn/centos/$releasever/os/$basearch/
gpgcheck=1
gpgkey=https://mirrors.ctyun.cn/centos/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-$releasever - Updates
baseurl=https://mirrors.ctyun.cn/centos/$releasever/updates/$basearch/
gpgcheck=1
gpgkey=https://mirrors.ctyun.cn/centos/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-$releasever - Extras
baseurl=https://mirrors.ctyun.cn/centos/$releasever/extras/$basearch/
gpgcheck=1
gpgkey=https://mirrors.ctyun.cn/centos/RPM-GPG-KEY-CentOS-7
enabled=1

[centosplus]
name=CentOS-$releasever - Plus
baseurl=https://mirrors.ctyun.cn/centos/$releasever/centosplus/$basearch/
gpgcheck=1
enabled=0
gpgkey=https://mirrors.ctyun.cn/centos/RPM-GPG-KEY-CentOS-7
EOF

    # 创建EPEL源
    cat > /etc/yum.repos.d/epel.repo << 'EOF'
[epel]
name=Extra Packages for Enterprise Linux 7 - $basearch
baseurl=https://mirrors.ctyun.cn/epel/7/$basearch
failovermethod=priority
enabled=1
gpgcheck=1
gpgkey=https://mirrors.ctyun.cn/epel/RPM-GPG-KEY-EPEL-7
EOF

    log_info "天翼云镜像源配置完成"
}

# 清理并更新缓存
update_cache() {
    log_step "清理并更新yum缓存..."
    yum clean all
    yum makecache
    log_info "缓存更新完成"
}

# 更新系统补丁
update_system() {
    log_step "更新系统补丁到最新版本..."
    log_warn "系统更新可能需要较长时间，请耐心等待..."
    
    yum update -y
    log_info "系统补丁更新完成"
}

# 安装编译依赖
install_dependencies() {
    log_step "安装SSH编译依赖..."
    yum groupinstall -y "Development Tools"
    yum install -y zlib-devel openssl-devel pam-devel libselinux-devel wget
    log_info "编译依赖安装完成"
}

# 编译安装新版SSH
install_openssh() {
    local ssh_version=${1:-"9.8p1"}
    log_step "开始编译安装OpenSSH $ssh_version..."
    
    # 创建工作目录
    mkdir -p /tmp/openssh_build
    cd /tmp/openssh_build
    
    # 下载OpenSSH源码
    log_info "下载OpenSSH $ssh_version 源码..."
    wget "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${ssh_version}.tar.gz"
    
    if [ ! -f "openssh-${ssh_version}.tar.gz" ]; then
        log_error "OpenSSH源码下载失败"
        exit 1
    fi
    
    # 解压源码
    tar -xzf "openssh-${ssh_version}.tar.gz"
    cd "openssh-${ssh_version}"
    
    # 备份现有SSH配置
    log_info "备份现有SSH配置..."
    cp -r /etc/ssh /etc/ssh.backup.$(date +%Y%m%d_%H%M%S)
    
    # 配置编译选项
    log_info "配置编译选项..."
    ./configure \
        --prefix=/usr \
        --sysconfdir=/etc/ssh \
        --with-md5-passwords \
        --with-pam \
        --with-selinux \
        --with-tcp-wrappers \
        --without-hardening
    
    # 编译
    log_info "编译OpenSSH..."
    make -j$(nproc)
    
    # 停止SSH服务（但不卸载包，避免依赖问题）
    log_info "停止SSH服务..."
    systemctl stop sshd
    
    # 安装新版本
    log_info "安装新版OpenSSH..."
    make install
    
    # 复制服务文件
    if [ -f "contrib/redhat/sshd.init" ]; then
        cp contrib/redhat/sshd.init /etc/init.d/sshd
        chmod +x /etc/init.d/sshd
    fi
    
    # 创建systemd服务文件
    cat > /etc/systemd/system/sshd.service << 'EOF'
[Unit]
Description=OpenSSH server daemon
Documentation=man:sshd(8) man:sshd_config(5)
After=network.target sshd-keygen.service
Wants=sshd-keygen.service

[Service]
Type=notify
ExecStart=/usr/sbin/sshd -D
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=42s

[Install]
WantedBy=multi-user.target
EOF

    # 重新加载systemd配置
    systemctl daemon-reload
    
    # 启动SSH服务
    log_info "启动SSH服务..."
    systemctl start sshd
    systemctl enable sshd
    
    # 清理临时文件
    cd /
    rm -rf /tmp/openssh_build
    
    log_info "OpenSSH $ssh_version 安装完成"
}

# 验证SSH版本
verify_ssh() {
    log_step "验证SSH版本..."
    local ssh_version=$(ssh -V 2>&1 | head -n1)
    log_info "当前SSH版本: $ssh_version"
    
    # 检查服务状态
    if systemctl is-active --quiet sshd; then
        log_info "SSH服务运行正常"
    else
        log_error "SSH服务未正常运行"
        systemctl status sshd
    fi
}

# 主函数
main() {
    local ssh_version=${1:-"9.8p1"}
    
    log_info "开始执行CentOS 7.8系统更新和SSH升级..."
    log_info "目标SSH版本: $ssh_version"
    
    check_root
    
    # 第一步：修改镜像源
    backup_repos
    setup_ctyun_repos
    update_cache
    
    # 第二步：更新系统补丁
    update_system
    
    # 第三步：升级SSH
    install_dependencies
    install_openssh "$ssh_version"
    verify_ssh
    
    log_info "所有操作完成！"
    log_warn "建议重启系统以确保所有更新生效"
    log_warn "请确保您有其他方式访问服务器，以防SSH配置出现问题"
}

# 脚本使用说明
usage() {
    echo "使用方法: $0 [SSH版本]"
    echo "示例:"
    echo "  $0              # 安装OpenSSH 9.8p1"
    echo "  $0 9.9p1        # 安装OpenSSH 9.9p1"
    echo "  $0 latest       # 安装最新版本（需要手动指定版本号）"
    exit 1
}

# 参数处理
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

# 执行主函数
main "$@"