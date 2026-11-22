#!/bin/bash
#
# Copyright (c) 2019-2025 SmallProgram <https://github.com/smallprogram>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/smallprogram/OpenWrtAction
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# Add patches
if [ "$GITHUB_ACTIONS" = "true" ] && [ -n "$GITHUB_RUN_ID" ] && [ -n "$GITHUB_WORKFLOW" ]; then
    PATCHES_SRC_DIR="$GITHUB_WORKSPACE"
else
    PATCHES_SRC_DIR="../OpenWrtAction"
fi

IMAGE_SIZE_PATCH="$PATCHES_SRC_DIR/diy_script/immortalwrt_diy/patches/0001-sparse-rockchip-rootfs-images.patch"
if [ ! -f "$IMAGE_SIZE_PATCH" ] || ! patch --forward --batch -p1 < "$IMAGE_SIZE_PATCH"; then
    echo "ERROR: failed to apply the sparse rootfs image patch"
    exit 1
fi

source "$PATCHES_SRC_DIR/diy_script/custom_feeds_and_packages.sh"
if ! patch_ghfu_firmware_repo; then
    exit 1
fi

#------------------------------------------------------移植包------------------------------------------------------------
# --- 拉取上游仓库 ---
rm -rf temp_resp

# =================================================================
# 极速拉取并注入 Feeds 树的函数
# =================================================================
inject_feed() {
    local repo_url="$1"
    local feed_dir="$2"
    shift 2
    local paths=("$@")

    echo "🚀 正在从 $repo_url 极速拉取至 $feed_dir ..."
    
    # 使用稀疏检出极速下载（不会拉取无关代码）
    git clone --filter=blob:none --sparse --depth=1 "$repo_url" temp_repo > /dev/null 2>&1
    cd temp_repo
    git sparse-checkout set "${paths[@]}" > /dev/null 2>&1
    
    # 提取上游最新的 Commit 时间戳 (作为兜底时间)
    local fallback_time=$(git log -1 --format=%cd --date=unix 2>/dev/null)
    cd ..

    for p in "${paths[@]}"; do
        if [ -d "temp_repo/$p" ]; then
            local pkg_name=$(basename "$p")
            local dest_path="$feed_dir/$pkg_name"
            
            # 1. 动态清理 OpenWrt 软链接 (防止文件类型冲突)
            local feed_name=$(echo "$feed_dir" | cut -d'/' -f2)
            local symlink_path="package/feeds/$feed_name/$pkg_name"
            if [ -h "$symlink_path" ] || [ -d "$symlink_path" ]; then
                rm -rf "$symlink_path"
            fi

            # 2. 清理并覆盖目标目录
            rm -rf "$dest_path"
            cp -r "temp_repo/$p" "$dest_path"

            # 3. 尝试提取文件真实时间戳，如果失败则使用整个库的 commit 时间
            local file_time=$(cd temp_repo && git log -1 --format=%cd --date=unix -- "$p" 2>/dev/null)
            if [ -z "$file_time" ]; then
                file_time=$fallback_time
            fi
            
            # 修改时间戳，欺骗 OpenWrt 编译缓存
            find "$dest_path" -exec touch -m -d @"$file_time" {} +
            
            echo "✅ 已成功注入并伪装时间戳: $pkg_name"
        fi
    done

    rm -rf temp_repo
}

# =================================================================
# 执行注入任务 (注意这里的目标目录直接是 feeds 对应的实际目录)
# =================================================================

# 1. 注入基础依赖包
inject_feed "https://github.com/openwrt/packages.git" "feeds/packages/lang" \
    "lang/golang" \
    "lang/rust"

# inject_feed "https://github.com/openwrt/luci.git" "feeds/luci/modules" \
#     "modules/luci-mod-dashboard"

echo "🎉 移植完毕"
#--------------------------------------------------------------end 移植包--------------------------------------------------------


#-----------------------------------------------修改脚本------------------------------------------------------------

# rm appfilter
rm -rf ./feeds/packages/net/open-app-filter

# Modify default IP
# sed -i 's/--set=llvm\.download-ci-llvm=true/--set=llvm.download-ci-llvm=false/' package/custom_overrides/rust/Makefile
# grep -q -- '--ci false \\' package/custom_overrides/rust/Makefile || sed -i '/x\.py \\/a \        --ci false \\' package/custom_overrides/rust/Makefile

# inject download package
mkdir -p dl
cp -r $PATCHES_SRC_DIR/library/* ./dl/

# inject world-50m.json to banip data
mkdir -p ./feeds/luci/applications/luci-app-banip/htdocs/luci-static/resources/view/banip/
cp -a $PATCHES_SRC_DIR/diy_script/custom_packages/banip/world-50m.json ./feeds/luci/applications/luci-app-banip/htdocs/luci-static/resources/view/banip/


# --- Modify SSH Configuration (Dropbear -> 2222, OpenSSH -> 22) ---

# 1. 确保 files 目录存在 (在 OpenWrt 源码根目录下)
mkdir -p files/etc/uci-defaults
mkdir -p files/etc/hotplug.d/iface
mkdir -p files/usr/bin

# Both R4S filesystem images use an 8 GiB root partition to reduce flashing time.
# Do not attempt to resize the mounted root filesystem online.

# Install and start Avahi mDNS discovery on every boot.
cat << 'EOF' > files/etc/uci-defaults/97-avahi-daemon
#!/bin/sh

mkdir -p /usr/share/dbus-1/system.d /etc/dbus-1/system.d

if [ -f /etc/dbus-1/system.d/avahi-dbus.conf ]; then
    cp -f /etc/dbus-1/system.d/avahi-dbus.conf /usr/share/dbus-1/system.d/avahi-dbus.conf
elif [ -f /usr/share/dbus-1/system.d/avahi-dbus.conf ]; then
    cp -f /usr/share/dbus-1/system.d/avahi-dbus.conf /etc/dbus-1/system.d/avahi-dbus.conf
fi

if [ -x /etc/init.d/dbus ]; then
    /etc/init.d/dbus restart
    sleep 1
fi

if [ -x /etc/init.d/avahi-daemon ]; then
    /etc/init.d/avahi-daemon enable
    /etc/init.d/avahi-daemon restart
fi

avahi_rule_exists=0
for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\(.*\)=rule$/\1/p'); do
    if [ "$(uci -q get "firewall.$section.name")" = "Allow-Avahi-LAN" ]; then
        avahi_rule_exists=1
        break
    fi
done
if [ "$avahi_rule_exists" = "0" ]; then
    rule="$(uci add firewall rule)"
    uci set "firewall.$rule.name=Allow-Avahi-LAN"
    uci set "firewall.$rule.src=lan"
    uci set "firewall.$rule.proto=udp"
    uci set "firewall.$rule.dest_port=5353"
    uci set "firewall.$rule.target=ACCEPT"
fi
uci commit firewall
/etc/init.d/firewall reload >/dev/null 2>&1

exit 0
EOF
chmod +x files/etc/uci-defaults/97-avahi-daemon

# Bind Docker's bridge to a firewall zone and allow routed Docker traffic.
cat << 'EOF' > files/usr/bin/ensure-docker-firewall
#!/bin/sh

docker_zone=""
for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\(.*\)=zone$/\1/p'); do
    if [ "$(uci -q get "firewall.$section.name")" = "docker" ]; then
        if [ -z "$docker_zone" ]; then
            docker_zone="$section"
        else
            uci delete "firewall.$section"
        fi
    fi
done

if [ -z "$docker_zone" ]; then
    docker_zone="$(uci add firewall zone)"
    uci set "firewall.$docker_zone.name=docker"
fi

uci set "firewall.$docker_zone.network=docker"
uci set "firewall.$docker_zone.input=ACCEPT"
uci set "firewall.$docker_zone.output=ACCEPT"
uci set "firewall.$docker_zone.forward=ACCEPT"
uci set "firewall.$docker_zone.masq=1"
uci set "firewall.$docker_zone.mtu_fix=1"

ensure_forwarding() {
    src_zone="$1"
    dest_zone="$2"
    forwarding_section=""
    for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\(.*\)=forwarding$/\1/p'); do
        if [ "$(uci -q get "firewall.$section.src")" = "$src_zone" ] &&
           [ "$(uci -q get "firewall.$section.dest")" = "$dest_zone" ]; then
            if [ -z "$forwarding_section" ]; then
                forwarding_section="$section"
            else
                uci delete "firewall.$section"
            fi
        fi
    done
    if [ -z "$forwarding_section" ]; then
        forwarding_section="$(uci add firewall forwarding)"
        uci set "firewall.$forwarding_section.src=$src_zone"
        uci set "firewall.$forwarding_section.dest=$dest_zone"
    fi
}

ensure_forwarding lan wan
ensure_forwarding lan docker
ensure_forwarding docker lan
ensure_forwarding docker wan

if ! uci -q show network | grep -q '^network\.docker='; then
    uci set network.docker=interface
fi
uci set network.docker.proto=none
uci set network.docker.device=docker0

uci commit network
uci commit firewall
/etc/init.d/firewall reload >/dev/null 2>&1

exit 0
EOF
chmod +x files/usr/bin/ensure-docker-firewall

cat << 'EOF' > files/etc/uci-defaults/98-docker-firewall
#!/bin/sh

/usr/bin/ensure-docker-firewall || exit 1
if [ -x /etc/init.d/dockerd ]; then
    /etc/init.d/dockerd enable
fi

exit 0
EOF
chmod +x files/etc/uci-defaults/98-docker-firewall

cat << 'EOF' > files/etc/hotplug.d/iface/99-docker-firewall
#!/bin/sh

[ "$ACTION" = "ifup" ] || [ "$ACTION" = "ifupdate" ] || exit 0
[ "$INTERFACE" = "docker" ] || [ "$DEVICE" = "docker0" ] || exit 0
/usr/bin/ensure-docker-firewall
EOF
chmod +x files/etc/hotplug.d/iface/99-docker-firewall

# 2. 生成首次启动脚本
cat << 'EOF' > files/etc/uci-defaults/99-custom-ssh-config
#!/bin/sh

# --- 1. 停止服务 ---
# 先停掉 Dropbear，确保它彻底释放 22 端口
# (在首次启动脚本中执行这步是安全的，不会导致用户掉线，因为此时还没人登录)
/etc/init.d/dropbear stop
/etc/init.d/sshd stop 2>/dev/null  # 加上这句以防万一 sshd 已经尝试自启

# --- 2. 配置 Dropbear (UCI) ---
# 将 Dropbear 端口移至 2222
uci set dropbear.@dropbear[0].Port='2222'
uci commit dropbear

# --- 3. 配置 OpenSSH (sshd_config) ---
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    # 允许 Root 登录
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
    # 显式指定端口 22
    sed -i 's/^#*Port.*/Port 22/' "$SSHD_CONFIG"
fi

# --- 4. 同步密钥 (可选) ---
# mkdir -p /root/.ssh
# if [ ! -L /root/.ssh/authorized_keys ]; then
#     [ -f /root/.ssh/authorized_keys ] && mv /root/.ssh/authorized_keys /root/.ssh/authorized_keys.bak
#     ln -s /etc/dropbear/authorized_keys /root/.ssh/authorized_keys
# fi

# --- 5. 按顺序启动服务 ---

# 第一步：启动 Dropbear
# 此时配置已生效，它会乖乖去占 2222，绝对不会碰 22
/etc/init.d/dropbear start

# 第二步：启动 OpenSSH
# 此时 22 端口绝对是空闲的，OpenSSH 可以顺利接管
/etc/init.d/sshd enable
/etc/init.d/sshd start

exit 0
EOF

# 3. 赋予脚本执行权限
chmod +x files/etc/uci-defaults/99-custom-ssh-config

# --- End Modify SSH Configuration ---
#------------------------------------------------end 修改脚本-------------------------------------------------------


echo "DIY2 is complate!"
