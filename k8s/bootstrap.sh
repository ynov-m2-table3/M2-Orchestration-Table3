#!/bin/sh
# Installe et configure k3s. Relançable : il ne refait que ce qui a changé.
set -eu
cd "$(dirname "$0")"

K3S_VERSION=v1.35.5+k3s1

# config de k3s, versionnée dans Git
if ! sudo cmp -s k3s-config.yaml /etc/rancher/k3s/config.yaml; then
  sudo install -D -m 644 k3s-config.yaml /etc/rancher/k3s/config.yaml
  CONFIG_CHANGED=1
fi

if [ "$(k3s --version 2>/dev/null | awk 'NR==1 {print $3}')" != "$K3S_VERSION" ]; then
  # installation ou mise à jour : démarre k3s avec la config ci-dessus
  curl -sfL https://get.k3s.io | sudo env INSTALL_K3S_VERSION="$K3S_VERSION" sh -
elif [ -n "${CONFIG_CHANGED:-}" ]; then
  sudo systemctl restart k3s
fi

# le nœud met quelques secondes à s'enregistrer
timeout 180 sh -c 'until kubectl get nodes 2>/dev/null | grep -qw Ready; do sleep 3; done'
kubectl get nodes