#!/bin/sh
# Installe k3s sur la VM, ou le met à jour si la version change.
# Relançable sans risque : si c'est déjà la bonne version, il ne fait rien.
set -eu
export KUBECONFIG="$HOME/.kube/config"

K3S_VERSION=v1.35.5+k3s1

if [ "$(k3s --version 2>/dev/null | awk 'NR==1 {print $3}')" != "$K3S_VERSION" ]; then
  # --cluster-init : etcd intégré, pour pouvoir ajouter d'autres masters plus tard
  curl -sfL https://get.k3s.io | sudo env INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server --cluster-init
fi

# kubectl sans sudo pour deploy
mkdir -p ~/.kube
sudo install -m 600 -o "$(id -un)" /etc/rancher/k3s/k3s.yaml ~/.kube/config

kubectl wait --for=condition=Ready node --all --timeout=180s
