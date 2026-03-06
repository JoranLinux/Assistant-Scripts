#!/bin/bash
#
# Copyright (c) Joran, 2026
#
# Authors:
#    Joran <zcj20080882@outlook.com>
#
# SPDX-License-Identifier: MIT
#
# Description:
# This script automates the process of building a custom WSL kernel for Windows Subsystem for Linux (WSL).

set -e -o pipefail

KERNEL_VERSION=""
JOBS="$(nproc)"
KERNEL_SRC_TOP="${PWD}/wsl-kernel-src"
OUTPUT_DIR="${PWD}/wsl-kernel-output"
CONFIG_OPTIONS=()
KERNEL_NAME=""

KERNEL_SRC_DIR=
WSL_KERNEL_ARCHIVE_BASE_URL="https://github.com/microsoft/WSL2-Linux-Kernel/archive/refs/tags"
WSL_KERNEL_QUERY_URL="https://api.github.com/repos/microsoft/WSL2-Linux-Kernel/releases"
DOWNLOAD_URL=
KERNEL_SRC_TARBALL=
info()
{
    echo -e "\e[34m$(date '+%Y-%m-%d %H:%M:%S') [INFO]: $* \e[0m"
}

warn()
{
    echo -e "\e[33m$(date '+%Y-%m-%d %H:%M:%S') [WARN]: $* \e[0m"
}


error()
{
    echo -e "\e[31m$(date '+%Y-%m-%d %H:%M:%S') [ERR ]: $* \e[0m"
}

usage()
{ 
    cat << EOF
Build the custom WSL kernel for Windows Subsystem for Linux (WSL).
Usage: $0 [options]
Options:
  -h, --help            Show this help message and exit
  -j, --jobs            Specify the number of parallel jobs for building (default: number of CPU cores)
  -o, --output-dir      Specify the output directory for the built kernel (default: ./build-output)
  -c, --config          Specify the extra kernel configuration with format: "CONFIG_OPTION1=value:CONFIG_OPTION1=value" (can be specified multiple times,each config must be split by colon, values will be merged)
  -n, --name            Specify the name for the built kernel (default: <kernelrelease>)
EOF
    exit 1
}

get_release()
{
    local tag
    local date
    local content
    local choice
    local fzf_data
    local depend_pkgs=(curl jq fzf pv)
    local apt_updated=true
    printf -v fzf_data "%-32s\t%s\n" "Version" "Published At"
    for pkg in "${depend_pkgs[@]}"; do
        if ! dpkg -s "$pkg" &> /dev/null; then
            warn "Package '$pkg' is required to fetch the latest WSL kernel release. Do you want to install it? [Y/n]"
            read -r answer
            if [[ "$answer" != "Y" && "$answer" != "y" ]]; then
                error "Cannot fetch the latest WSL kernel release without '$pkg'. Exiting."
                exit 1
            fi
            if [ "$apt_updated" = true ]; then
                sudo apt update
                apt_updated=false
            fi
            sudo apt install -y "$pkg"
        fi
    done
    if ! dpkg -s curl jq fzf pv &> /dev/null; then
        warn "curl, jq, and fzf are required to fetch the latest WSL kernel release. Do you want to install them? [Y/n]"
        read -r answer
        if [[ "$answer" != "Y" && "$answer" != "y" ]]; then
            error "Cannot fetch the latest WSL kernel release without curl, jq, and fzf. Exiting."
            exit 1
        fi
        sudo apt update && sudo apt install -y curl jq fzf
    fi
    content=$(curl -sL "$WSL_KERNEL_QUERY_URL")
    while read -r line; do
        tag=$(echo "$line" | awk '{print $1}')
        date=$(echo "$line" | awk '{print $2}')
        if [[ -z "$tag" ]]; then
            continue
        fi
        printf -v line "%-32s\t%s\n" "$tag" "$(date -d "$date" "+%Y-%m-%d %H:%M:%S %Z")"
        fzf_data+="$line"
    done < <(echo "$content" | jq -r '.[] | "\(.tag_name)\t\(.published_at)"')
    
    choice=$(echo -e "$fzf_data" | fzf \
        --header-lines=1 \
        --height=70% \
        --border \
        --layout=reverse \
        --prompt="Select a WSL kernel release(q for exit): ")
    if [[ -z "$choice" ]]; then
        error "No release selected. Exiting."
        exit 1
    fi
    KERNEL_VERSION=$(echo "$choice" | awk '{print $1}')
    DOWNLOAD_URL="${WSL_KERNEL_ARCHIVE_BASE_URL}/${KERNEL_VERSION}.tar.gz"
    KERNEL_SRC_TARBALL="wsl-kernel-src-${KERNEL_VERSION}.tar.gz"
    KERNEL_SRC_DIR="${KERNEL_SRC_TOP}/WSL2-Linux-Kernel-${KERNEL_VERSION}"
    mkdir -p "$KERNEL_SRC_DIR"
    if [ ! -f "$KERNEL_SRC_TARBALL" ]; then
        info "Downloading WSL kernel source code for version '$KERNEL_VERSION'..."
        curl -fL "$DOWNLOAD_URL" -o "$KERNEL_SRC_TARBALL"
    else
        info "WSL kernel source tarball already exists. Skipping download."
    fi
    info "Extracting WSL kernel source code..."
    pv "$KERNEL_SRC_TARBALL" | tar -xzf - --strip-components=1 -C "$KERNEL_SRC_DIR"
}

build()
{
    local option=
    local value=
    mkdir -p "$OUTPUT_DIR"
    info "Building WSL kernel version '$KERNEL_VERSION' with $JOBS parallel jobs..."
    pushd "$KERNEL_SRC_DIR"
    mkdir -p modules
    cp arch/x86/configs/config-wsl .config
    for config in "${CONFIG_OPTIONS[@]}"; do
        info "Applying extra kernel configuration: $config"
        config=$(echo "$config" | tr -d ' ')
        option=$(echo "$config" | cut -d= -f1)
        value=$(echo "$config" | cut -d= -f2)
        scripts/config --set-val "$option" "$value" || { error "Failed to apply kernel configuration: $config"; exit 1; }
    done
    # scripts/config --module CONFIG_USB_NET_RNDIS_HOST
    make -j "$JOBS"
    make INSTALL_MOD_PATH="$PWD/modules" modules_install INSTALL_MOD_STRIP=1
    rm -f $PWD/modules/build
    if [ -z "$KERNEL_NAME" ]; then
        KERNEL_NAME=$(make -s kernelrelease)
    fi
    sudo ./Microsoft/scripts/gen_modules_vhdx.sh "$PWD/modules" "$KERNEL_NAME" "$KERNEL_NAME-modules.vhdx"
    cp -f "$KERNEL_NAME-modules.vhdx" "$OUTPUT_DIR/"
    cp -f arch/x86/boot/bzImage "$OUTPUT_DIR/${KERNEL_NAME}-bzImage"
    popd
    sudo rm -rf "$KERNEL_SRC_DIR"
    rm -f "$KERNEL_SRC_TARBALL"
}


while [[ $# -gt 0 ]]; do
    option=$1
    optarg=$2
    case $option in
        -j|--jobs)
            JOBS="$optarg"
            shift 2
            ;;
        -o|--output-dir)
            OUTPUT_DIR="$optarg"
            shift 2
            ;;
        -c|--config)
            mapfile -t CONFIG_OPTIONS < <(echo "$optarg" | tr ':' ' ')
            shift 2
            ;;
        -n|--name)
            KERNEL_NAME="$optarg"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $option"
            usage
            ;;
    esac
done

get_release
build
