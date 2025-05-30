#!/bin/bash

# 脚本：CentOS 7.8 系统更新和 OpenSSH 更新脚本 (增强版)
# 功能：1. 修改YUM源为天翼云 (带下载校验)
#       2. 更新所有系统补丁
#       3. 更新OpenSSH到仓库最新版

# --- 安全警告和用户确认 ---
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!! 警告：CentOS 7 已于 2024 年 6 月 30 日停止维护 (EOL)。                !!"
echo "!! 您当前的操作系统 CentOS 7.8 已不受官方支持，可能存在安全风险。           !!"
echo "!! 强烈建议您尽快迁移到 CentOS Stream、AlmaLinux、Rocky Linux 等受支持的 OS。!!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo ""
read -p "您理解以上风险并希望继续执行此脚本吗？(yes/no): " confirm_execution
if [[ "$confirm_execution" != "yes" ]]; then
    echo "操作已取消。"
    exit 0
fi

# --- 检查是否以 root 权限运行 ---
if [[ $EUID -ne 0 ]]; then
   echo "错误：此脚本必须以 root 权限运行。"
   exit 1
fi

echo "脚本开始执行..."
echo "当前时间: $(date)"

# --- 函数：下载并验证 repo 文件 ---
download_and_validate_repo() {
    local url="$1"
    local dest_file="$2"
    local repo_name="$3" # "Base" or "EPEL"

    echo "正在下载天翼云 CentOS 7 ${repo_name} YUM 源配置文件从 ${url} ..."

    # 使用 curl -f 会在 HTTP 错误时静默失败并返回非零退出码
    # -s 静默模式，-L 跟随重定向
    # 同时捕获 HTTP 状态码
    http_code=$(curl -L -s -f -o "$dest_file" -w "%{http_code}" "$url")
    curl_exit_code=$?

    if [ "$curl_exit_code" -ne 0 ]; then
        echo "错误：curl 下载 ${repo_name} 源配置文件失败。curl 退出码: $curl_exit_code, HTTP 状态码: $http_code"
        echo "URL: $url"
        rm -f "$dest_file" # 删除可能已创建的不完整文件
        return 1
    fi
    
    if [ "$http_code" -ne 200 ]; then
        echo "错误：下载 ${repo_name} 源配置文件时服务器返回非 200 HTTP 状态码: $http_code"
        echo "URL: $url"
        rm -f "$dest_file"
        return 1
    fi

    # 检查文件是否为空或过小 (YUM repo 文件通常不会小于几十字节)
    if [ ! -s "$dest_file" ] || [ "$(stat -c%s "$dest_file")" -lt 50 ]; then
        echo "错误：下载的 ${repo_name} 源配置文件 '${dest_file}' 为空或过小。"
        echo "文件内容摘要 (如果存在):"
        head -n 3 "$dest_file" 2>/dev/null
        rm -f "$dest_file"
        return 1
    fi

    # 检查文件是否包含基本的 YUM repo 节头 (例如 [base], [updates], [epel])
    if ! grep -q -E '^\s*\[.+\]' "$dest_file"; then
        echo "错误：下载的 ${repo_name} 源配置文件 '${dest_file}' 似乎不是有效的 YUM repo 文件 (缺少节头，如 [section_name])。"
        echo "文件内容前5行:"
        head -n 5 "$dest_file"
        rm -f "$dest_file"
        return 1
    fi

    echo "天翼云 ${repo_name} 源配置文件下载并初步验证成功: ${dest_file}"
    return 0
}


# --- 1. 修改 YUM 镜像源为天翼云 ---
echo ""
echo "### 步骤 1: 正在修改 YUM 镜像源为天翼云 ###"

# 备份当前的 .repo 文件
BACKUP_DIR="/etc/yum.repos.d/backup_$(date +%Y%m%d%H%M%S)"
echo "正在备份 /etc/yum.repos.d/ 中的 CentOS-*repo 文件到 $BACKUP_DIR ..."
mkdir -p "$BACKUP_DIR"
repo_files_found=0
if ls /etc/yum.repos.d/CentOS-*.repo 1> /dev/null 2>&1; then
    mv /etc/yum.repos.d/CentOS-*.repo "$BACKUP_DIR/"
    echo "CentOS-*repo 文件备份完成。"
    repo_files_found=1
fi
if ls /etc/yum.repos.d/epel*.repo 1> /dev/null 2>&1; then # 也备份epel相关的
    mv /etc/yum.repos.d/epel*.repo "$BACKUP_DIR/"
    echo "epel*.repo 文件备份完成。"
    repo_files_found=1
fi
if [ "$repo_files_found" -eq 0 ]; then
    echo "没有找到标准的 CentOS-*repo 或 epel*.repo 文件进行备份，可能已被修改或已是第三方源。"
fi


# 定义天翼云 repo 文件 URL 和目标路径
CTYUN_BASE_REPO_URL="https://mirrors.ctyun.cn/repo/CentOS-Base-7.repo"
CTYUN_BASE_REPO_DEST="/etc/yum.repos.d/CentOS-Base.repo"
CTYUN_EPEL_REPO_URL="https://mirrors.ctyun.cn/repo/epel-7.repo"
CTYUN_EPEL_REPO_DEST="/etc/yum.repos.d/epel.repo"

# 下载并验证 Base 源
if ! download_and_validate_repo "$CTYUN_BASE_REPO_URL" "$CTYUN_BASE_REPO_DEST" "Base"; then
    echo "错误：处理天翼云 Base 源配置文件失败。"
    echo "正在尝试恢复备份的源文件..."
    if [ "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then # 检查备份目录是否非空
        cp -a "$BACKUP_DIR"/*.repo /etc/yum.repos.d/
        echo "备份已恢复。"
    else
        echo "未找到备份文件或备份目录为空，无法恢复。"
    fi
    exit 1
fi

# 可选：配置 EPEL 源
epel_configured=0
read -p "是否需要配置天翼云的 EPEL 源? (EPEL 包含许多额外的常用软件包) (yes/no): " add_epel
if [[ "$add_epel" == "yes" ]]; then
    if download_and_validate_repo "$CTYUN_EPEL_REPO_URL" "$CTYUN_EPEL_REPO_DEST" "EPEL"; then
        epel_configured=1
        echo "天翼云 EPEL 源已成功配置。"
    else
        echo "警告：下载或验证天翼云 EPEL 源配置文件失败。将跳过 EPEL 配置。"
    fi
fi

echo "清理 YUM 缓存..."
yum clean all # > /dev/null # 暂时不重定向，方便看输出
echo "生成新的 YUM 缓存..."
yum makecache
if [ $? -ne 0 ]; then
    echo "错误：YUM makecache 失败。请检查源配置或网络。"
    echo "当前 /etc/yum.repos.d/ 目录内容:"
    ls -la /etc/yum.repos.d/
    echo "CentOS-Base.repo 内容预览:"
    head /etc/yum.repos.d/CentOS-Base.repo 2>/dev/null || echo "无法读取 CentOS-Base.repo"
    if [[ "$epel_configured" -eq 1 ]]; then
        echo "epel.repo 内容预览:"
        head /etc/yum.repos.d/epel.repo 2>/dev/null || echo "无法读取 epel.repo"
    fi
    exit 1
fi
echo "YUM 镜像源已成功修改为天翼云，并已更新缓存。"

# --- 2. 将系统补丁更新至最新版本 ---
echo ""
echo "### 步骤 2: 正在全面更新系统补丁 ###"
echo "这将更新所有已安装的软件包到仓库中的最新版本。此过程可能需要一些时间..."
yum update -y
if [ $? -ne 0 ]; then
    echo "警告：系统更新过程中可能发生了一些错误。请检查上面的 YUM 输出。"
else
    echo "系统补丁已成功更新至仓库中的最新版本。"
fi

# --- 3. 单独更新系统自带的 SSH 版本 ---
echo ""
echo "### 步骤 3: 正在更新 OpenSSH ###"
echo "提示：CentOS 7 仓库中的 OpenSSH 版本通常为 7.4p1 系列，它会接收安全补丁，"
echo "但不会升级到如 9.8p1 等全新主要版本。此脚本将尝试更新到仓库中可用的最新 7.4p1 系列版本。"
echo ""

current_ssh_version_full=$(ssh -V 2>&1)
echo "当前 OpenSSH 版本: $current_ssh_version_full"

read -p "您希望将 OpenSSH 更新到当前已配置源中可用的最新版本吗？(yes/no): " update_ssh_choice
if [[ "$update_ssh_choice" == "yes" ]]; then
    echo "正在尝试更新 OpenSSH 软件包 (openssh, openssh-clients, openssh-server)..."
    yum update -y openssh openssh-clients openssh-server
    if [ $? -eq 0 ]; then
        new_ssh_version_full=$(ssh -V 2>&1)
        echo "OpenSSH 更新操作完成。"
        echo "更新后 OpenSSH 版本: $new_ssh_version_full"
        if [[ "$current_ssh_version_full" == "$new_ssh_version_full" ]]; then
            echo "OpenSSH 版本没有变化，可能已是最新或没有可用更新。"
        fi
    else
        echo "错误：OpenSSH 更新失败。请检查上面的 YUM 输出。"
    fi
else
    echo "已跳过 OpenSSH 更新。"
fi

echo ""
echo "------------------------------------------------------------------------"
echo "脚本执行完毕。"
echo "重要提示：由于 CentOS 7 已 EOL，请尽快规划迁移到受支持的操作系统！"
echo "------------------------------------------------------------------------"
echo ""

# 提示重启 (检查 yum-utils 包是否安装，如果未安装，needs-restarting 命令可能不存在)
if ! rpm -q yum-utils &>/dev/null; then
    echo "正在安装 yum-utils 以检查是否需要重启..."
    yum install -y yum-utils &>/dev/null
fi

if command -v needs-restarting &>/dev/null && needs-restarting -r; then
    echo "建议重启系统以应用所有更新（特别是内核或 glibc 等核心库的更新）。"
    read -p "是否现在重启系统？(yes/no): " reboot_choice
    if [[ "$reboot_choice" == "yes" ]]; then
        echo "正在重启系统..."
        reboot
    else
        echo "请在方便时手动重启系统。"
    fi
else
    echo "根据 'needs-restarting' 工具的判断，当前可能不需要重启。"
    echo "但如果有内核或关键系统库更新，手动重启仍然是一个好习惯。"
fi

exit 0