#!/bin/sh
# Installe et configure k3s sur ce nœud. Relançable : il ne refait que ce qui a changé.
#   k3s-1          : crée le cluster (master)
#   k3s-2, k3s-3   : rejoignent le cluster en master
#   autres (DockerV2) : rejoignent le cluster en worker
set -eu
cd "$(dirname "$0")"

K3S_VERSION=v1.35.5+k3s1
FIRST=172.16.1.5   # IP privée de k3s-1
NODE=$(hostname | tr '[:upper:]' '[:lower:]')

case $NODE in
  k3s-*) ROLE=server; SERVICE=k3s ;;
  *)     ROLE=agent;  SERVICE=k3s-agent ;;
esac

# dépendances de Longhorn : iSCSI pour les volumes, NFS pour les volumes partagés
if ! dpkg -s open-iscsi nfs-common >/dev/null 2>&1; then
  sudo apt-get update -q && sudo apt-get install -y -q open-iscsi nfs-common
fi
sudo systemctl enable --now iscsid

CONFIG=$(mktemp)
if [ $ROLE = server ]; then cp k3s-config.yaml "$CONFIG"; else : > "$CONFIG"; fi
if [ "$NODE" = k3s-1 ]; then
  echo "cluster-init: true" >> "$CONFIG"   # etcd intégré
else
  echo "server: https://$FIRST:6443" >> "$CONFIG"
  echo "token-file: /etc/rancher/k3s/token" >> "$CONFIG"   # déposé par la CI
fi

if ! sudo cmp -s "$CONFIG" /etc/rancher/k3s/config.yaml; then
  sudo install -D -m 644 "$CONFIG" /etc/rancher/k3s/config.yaml
  CONFIG_CHANGED=1
fi
rm "$CONFIG"

if [ "$(k3s --version 2>/dev/null | awk 'NR==1 {print $3}')" != "$K3S_VERSION" ]; then
  # installation ou mise à jour : démarre k3s avec la config ci-dessus
  curl -sfL https://get.k3s.io | sudo env INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - $ROLE
elif [ -n "${CONFIG_CHANGED:-}" ]; then
  sudo systemctl restart $SERVICE
fi

if [ $ROLE = server ]; then
  # le nœud met quelques secondes à s'enregistrer
  timeout 300 sh -c "until kubectl get node $NODE 2>/dev/null | grep -qw Ready; do sleep 3; done"
  kubectl get nodes
else
  # un worker n'a pas de kubectl : on vérifie juste que le service tourne
  timeout 120 sh -c "until systemctl is-active -q $SERVICE; do sleep 3; done"
  echo "$NODE : $SERVICE actif"
fi
