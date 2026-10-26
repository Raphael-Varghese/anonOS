#!/usr/bin/env bash
set -euo pipefail
WORK="${WORK:-/workspaces}"
BR_DIR="$WORK/buildroot"
PROJ="$WORK/anonos"
BR_BRANCH="${BR_BRANCH:-2025.02.x}"
JOBS="${JOBS:-$(nproc)}"
MODE="build"
case "${1:-}" in
  --setup-only) MODE="setup" ;;
  --run)        MODE="run" ;;
  "")           ;;
  *) echo "Unknown option: $1"; exit 1 ;;
esac
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
run_qemu() {
  cd "$BR_DIR"
  log "Booting anonOS (login: root, no password). Exit QEMU with Ctrl-A then X."
  exec qemu-system-x86_64 -M pc -m 2G -smp 2 -nographic \
    -kernel output/images/bzImage \
    -drive file=output/images/rootfs.ext2,if=virtio,format=raw \
    -append "rootwait root=/dev/vda console=ttyS0" \
    -nic user,model=virtio-net-pci
}
if [ "$MODE" = "run" ]; then
  run_qemu
fi
log "1/7 Installing host dependencies"
sudo apt-get update
sudo apt-get install -y build-essential libncurses-dev bc cpio rsync unzip \
  wget file git qemu-system-x86 flex bison libssl-dev tmux
log "2/7 Fetching Buildroot ($BR_BRANCH)"
if [ ! -d "$BR_DIR/.git" ]; then
  git clone --depth 1 --branch "$BR_BRANCH" \
    https://gitlab.com/buildroot.org/buildroot.git "$BR_DIR"
else
  echo "Buildroot already present at $BR_DIR, reusing it."
fi
log "3/7 Writing project files in $PROJ"
mkdir -p "$PROJ"/overlay/etc/{tor,nftables,openvpn,wireguard,init.d}
cat > "$PROJ/kernel.fragment" <<'EOF'
CONFIG_TUN=y
CONFIG_WIREGUARD=y
CONFIG_NETFILTER=y
CONFIG_NF_CONNTRACK=y
CONFIG_NF_NAT=y
CONFIG_NF_TABLES=y
CONFIG_NF_TABLES_INET=y
CONFIG_NFT_CT=y
CONFIG_NFT_NAT=y
CONFIG_NFT_REDIRECT=y
CONFIG_NFT_REJECT=y
EOF
cat > "$PROJ/overlay/etc/tor/torrc" <<'EOF'
User tor
DataDirectory /var/lib/tor
SocksPort 9050
TransPort 9040
DNSPort 5353
AutomapHostsOnResolve 1
VirtualAddrNetworkIPv4 10.192.0.0/10
Log notice file /var/log/tor.log
EOF
cat > "$PROJ/overlay/etc/nftables/killswitch.nft" <<'EOF'
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iif lo accept
    ct state established,related accept
    udp sport 67 udp dport 68 accept
  }
  chain output {
    type filter hook output priority 0; policy drop;
    oif lo accept
    udp sport 68 udp dport 67 accept
    meta skuid "tor" accept
    oifname { "wg0", "tun0" } accept
    ct state established,related accept
    # Add one line per VPN server so the tunnel itself can connect, e.g.:
    # ip daddr 203.0.113.10 accept
  }
}
table ip nat {
  chain output {
    type nat hook output priority -100;
    meta skuid "tor" return
    oifname "lo" return
    udp dport 53 redirect to :5353
    ip protocol tcp redirect to :9040
  }
}
EOF
cat > "$PROJ/overlay/etc/init.d/S40killswitch" <<'EOF'
#!/bin/sh
case "$1" in
  start) nft -f /etc/nftables/killswitch.nft && echo "kill switch active" ;;
  stop)  nft flush ruleset ;;
esac
EOF
chmod +x "$PROJ/overlay/etc/init.d/S40killswitch"
cat > "$PROJ/overlay/etc/os-release" <<'EOF'
NAME="anonOS"
PRETTY_NAME="anonOS 0.1"
ID=anonos
VERSION="0.1"
VERSION_ID=0.1
EOF
cat > "$PROJ/overlay/etc/motd" <<'EOF'

  anonOS 0.1
  Created by Raphael Varghese
  
  Full anonymity.
  Hacktools for y'all.
EOF
cat > "$PROJ/.gitignore" <<'EOF'
overlay/etc/openvpn/*
overlay/etc/wireguard/*
!overlay/etc/openvpn/.gitkeep
!overlay/etc/wireguard/.gitkeep
EOF
touch "$PROJ/overlay/etc/openvpn/.gitkeep" "$PROJ/overlay/etc/wireguard/.gitkeep"
log "4/7 Configuring Buildroot"
cd "$BR_DIR"
make qemu_x86_64_defconfig
set_opt() {
  local sym="$1" val="$2"
  sed -i "/^${sym}=/d;/^# ${sym} is not set/d" .config
  echo "${sym}=${val}" >> .config
}
set_opt BR2_TARGET_GENERIC_HOSTNAME '"anonos"'
set_opt BR2_TARGET_GENERIC_ISSUE '"anonOS - privacy-first Linux"'
set_opt BR2_ROOTFS_OVERLAY "\"$PROJ/overlay\""
set_opt BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES "\"$PROJ/kernel.fragment\""
set_opt BR2_TARGET_ROOTFS_EXT2_SIZE '"2G"'
set_opt BR2_TOOLCHAIN_BUILDROOT_CXX y
set_opt BR2_INSTALL_LIBSTDCPP y
set_opt BR2_PACKAGE_OPENSSL y
set_opt BR2_PACKAGE_CA_CERTIFICATES y
set_opt BR2_PACKAGE_LIBCURL y
set_opt BR2_PACKAGE_LIBCURL_CURL y
for pkg in TOR OPENVPN WIREGUARD_TOOLS NFTABLES IPROUTE2 DNSMASQ DROPBEAR \
           PROXYCHAINS_NG; do
  set_opt "BR2_PACKAGE_${pkg}" y
done
for pkg in NMAP TCPDUMP AIRCRACK_NG SOCAT; do
  set_opt "BR2_PACKAGE_${pkg}" y
done
make olddefconfig
log "5/7 Verifying selected packages survived olddefconfig"
MISSING=0
for pkg in TOR OPENVPN WIREGUARD_TOOLS NFTABLES IPROUTE2 DNSMASQ DROPBEAR \
           PROXYCHAINS_NG NMAP TCPDUMP AIRCRACK_NG SOCAT LIBCURL_CURL; do
  if grep -q "^BR2_PACKAGE_${pkg}=y" .config; then
    echo "  ok       $pkg"
  else
    echo "  MISSING  $pkg  (search for it with: make menuconfig, then press /)"
    MISSING=1
  fi
done
[ "$MISSING" -eq 1 ] && echo "Some packages were dropped; the build will continue without them."
cat > "$PROJ/run-qemu.sh" <<EOF
#!/usr/bin/env bash
cd "$BR_DIR"
exec qemu-system-x86_64 -M pc -m 2G -smp 2 -nographic \\
  -kernel output/images/bzImage \\
  -drive file=output/images/rootfs.ext2,if=virtio,format=raw \\
  -append "rootwait root=/dev/vda console=ttyS0" \\
  -nic user,model=virtio-net-pci
EOF
chmod +x "$PROJ/run-qemu.sh"
make savedefconfig BR2_DEFCONFIG="$PROJ/anonos_defconfig"
if [ "$MODE" = "setup" ]; then
  log "Setup complete. Build later with:  cd $BR_DIR && make -j$JOBS"
  exit 0
fi
log "6/7 Building (40-90 min on 4 vCPU; needs ~10-15 GB disk)"
make -j"$JOBS" 2>&1 | tee build.log
log "7/7 Done"
cat <<EOF

Images:    $BR_DIR/output/images/{bzImage,rootfs.ext2}
Boot:      bash $0 --run      (or $PROJ/run-qemu.sh)
Log in:    root (no password)

Inside the VM, test with:
  cat /etc/os-release
  nft list ruleset
  tail -f /var/log/tor.log          # wait for "Bootstrapped 100%"
  curl -s https://check.torproject.org/api/ip     # expect "IsTor":true

Config saved: $PROJ/anonos_defconfig
Rebuild from scratch later:
  cd $BR_DIR && make BR2_DEFCONFIG=$PROJ/anonos_defconfig defconfig && make -j$JOBS
EOF
