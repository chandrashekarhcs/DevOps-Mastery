#!/bin/bash
# ============================================================
# Kubernetes WORKER NODE Setup Script
# Ubuntu 26.04 LTS (Resolute Raccoon)
# K8s v1.32 | containerd
#
# Usage:
#   sudo bash k8s-worker.sh --join-command "kubeadm join <ip>:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>"
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }

[[ $EUID -ne 0 ]] && error "Run with sudo: sudo bash $0 --join-command \"...\""

# Parse --join-command
JOIN_COMMAND=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --join-command) JOIN_COMMAND="$2"; shift 2 ;;
    *) error "Unknown argument: $1. Usage: sudo bash $0 --join-command \"kubeadm join ...\"" ;;
  esac
done

[[ -z "$JOIN_COMMAND" ]] && error "--join-command is required.\nUsage: sudo bash $0 --join-command \"kubeadm join <ip>:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>\""

echo -e "${CYAN}${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   K8s Worker Node Setup — Ubuntu 26.04  ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ============================================================
# 1. DISABLE SWAP
# ============================================================
section "1. Disable Swap"
swapoff -a
sed -i '/\bswap\b/s/^/#/' /etc/fstab
info "Swap disabled."

# ============================================================
# 2. KERNEL MODULES
# ============================================================
section "2. Kernel Modules"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
info "overlay + br_netfilter loaded."

# ============================================================
# 3. SYSCTL
# ============================================================
section "3. Sysctl Params"
cat > /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system > /dev/null
info "Sysctl params applied."

# ============================================================
# 4. DEPENDENCIES
# ============================================================
section "4. Base Dependencies"
apt-get update -y -q
apt-get install -y -q ca-certificates curl gnupg2 apt-transport-https
info "Dependencies installed."

# ============================================================
# 5. DOCKER REPO (for containerd.io)
# ============================================================
section "5. Docker Repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: resolute
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
info "Docker repo added."

# ============================================================
# 6. KUBERNETES REPO
# ============================================================
section "6. Kubernetes Repository (v1.32)"
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | \
    tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
info "Kubernetes repo added."

# ============================================================
# 7. INSTALL PACKAGES
# ============================================================
section "7. Install containerd + K8s Tools"
apt-get update -y -q
apt-get install -y containerd.io kubeadm kubelet kubectl
apt-mark hold kubelet kubeadm kubectl
info "Packages installed and held."

# ============================================================
# 8. CONFIGURE CONTAINERD
# ============================================================
section "8. Configure containerd"
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd
info "containerd configured with SystemdCgroup=true."

# ============================================================
# 9. ENABLE KUBELET
# ============================================================
section "9. Enable kubelet"
systemctl enable kubelet
info "kubelet enabled."

# ============================================================
# 10. JOIN CLUSTER
# ============================================================
section "10. Joining Kubernetes Cluster"
info "Running: $JOIN_COMMAND"
eval "$JOIN_COMMAND"
info "Node joined successfully!"

# ============================================================
# DONE
# ============================================================
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║      Worker Node Setup COMPLETE! 🎉      ║"
echo "  ║                                          ║"
echo "  ║  Verify from control-plane:              ║"
echo "  ║    kubectl get nodes -o wide             ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"
