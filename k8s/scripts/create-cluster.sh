#!/bin/sh
# Installe k3d (si absent) et crée le cluster. À lancer sur la VM qui a Docker.
set -eu
command -v k3d >/dev/null || curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
command -v kubectl >/dev/null || {
  curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x /usr/local/bin/kubectl
}
k3d cluster create --config k8s/k3d-cluster.yaml
kubectl get nodes
echo "Attendre que traefik et metrics-server soient Running :"
kubectl -n kube-system get pods
