#!/bin/bash
# ============================================================
# Kubernetes MASTER / CONTROL-PLANE Setup Script
# Ubuntu 26.04 LTS (Resolute Raccoon)
# K8s v1.32 | containerd | Flannel CNI
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }

[[ $EUID -ne 0 ]] && error "Run with sudo: sudo bash $0"

echo -e "${CYAN}${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  K8s Control-Plane Setup — Ubuntu 26.04 ║"
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
# 9. KUBEADM INIT
# ============================================================
section "9. kubeadm init (pod-cidr=10.244.0.0/16)"
kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables
info "kubeadm init complete."

# ============================================================
# 10. KUBECONFIG
# ============================================================
section "10. Configure kubectl"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
mkdir -p "$REAL_HOME/.kube"
cp /etc/kubernetes/admin.conf "$REAL_HOME/.kube/config"
chown "$(id -u "$REAL_USER"):$(id -g "$REAL_USER")" "$REAL_HOME/.kube/config"
export KUBECONFIG=/etc/kubernetes/admin.conf
info "kubeconfig written to $REAL_HOME/.kube/config"

# ============================================================
# 11. WAIT FOR API SERVER
# ============================================================
section "11. Waiting for API Server to be ready..."
for i in $(seq 1 20); do
  if kubectl get nodes &>/dev/null; then
    info "API server is ready."
    break
  fi
  echo "  Waiting... ($i/20)"
  sleep 5
done

# ============================================================
# 12. INSTALL FLANNEL CNI
# ============================================================
section "12. Install Flannel CNI"
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
info "Flannel CNI applied."

# ============================================================
# 13. WAIT FOR FLANNEL + NODE READY
# ============================================================
section "13. Waiting for control-plane to become Ready..."
for i in $(seq 1 30); do
  STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1)
  if [[ "$STATUS" == "Ready" ]]; then
    info "Control-plane is Ready!"
    break
  fi
  echo "  Node status: ${STATUS:-unknown} — waiting... ($i/30)"
  sleep 5
done

# ============================================================
# 14. PRINT JOIN COMMAND
# ============================================================
section "14. Worker Node Join Command"
JOIN_CMD=$(kubeadm token create --print-join-command)
echo ""
echo -e "${YELLOW}${BOLD}  Copy and run this on each worker node:${NC}"
echo ""
echo -e "  ${BOLD}sudo ${JOIN_CMD}${NC}"
echo ""
echo "sudo ${JOIN_CMD}" > /tmp/k8s-worker-join.sh
chmod +x /tmp/k8s-worker-join.sh
info "Join command saved to /tmp/k8s-worker-join.sh"

# ============================================================
# DONE
# ============================================================
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║     Control-Plane Setup COMPLETE! 🎉     ║"
echo "  ║                                          ║"
echo "  ║  Check:  kubectl get nodes -o wide       ║"
echo "  ║  Pods:   kubectl get pods -A             ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"
