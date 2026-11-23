#!/bin/sh
# Déploie tout ce qui tourne dans le cluster. Lancé par la CI après bootstrap.sh.
set -eu
cd "$(dirname "$0")"

# Vault tourne sur DockerV2, joint par le réseau privé Azure
VAULT_ADDR=http://172.16.1.4:8200
vault_get() {
  curl -fsS -H "X-Vault-Token: $(cat ~/.vault-token)" "$VAULT_ADDR/v1/secret/data/nextcloud" \
    | jq -er ".data.data.$1"
}

# lus d'abord dans des variables : si Vault ne répond pas, le script s'arrête ici
DB_PASSWORD=$(vault_get db_password)
DB_ROOT_PASSWORD=$(vault_get db_root_password)
ADMIN_PASSWORD=$(vault_get admin_password)
GRAFANA_PASSWORD=$(vault_get grafana_password)

kubectl apply -f namespaces.yaml

# région de chaque nœud, et où Longhorn a le droit de stocker des copies
label() {
  node=$1; shift
  kubectl get node "$node" >/dev/null 2>&1 && kubectl label node "$node" "$@" --overwrite >/dev/null || true
}
label k3s-1    topology.kubernetes.io/region=norwayeast    node.longhorn.io/create-default-disk=true
label dockerv2 topology.kubernetes.io/region=norwayeast    node.longhorn.io/create-default-disk=true
label k3s-2    topology.kubernetes.io/region=swedencentral node.longhorn.io/create-default-disk=true
label k3s-3    topology.kubernetes.io/region=polandcentral

kubectl -n nextcloud create secret generic nextcloud \
  --from-literal=db-password="$DB_PASSWORD" \
  --from-literal=db-root-password="$DB_ROOT_PASSWORD" \
  --from-literal=admin-password="$ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$GRAFANA_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# cert-manager, monitoring et Longhorn, installés par le contrôleur Helm de k3s
kubectl apply -f platform/

# les ClusterIssuers ont besoin que cert-manager soit installé
until kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1; do sleep 5; done
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
kubectl apply -f issuers.yaml

# Longhorn doit être prêt avant de créer les volumes
timeout 600 sh -c 'until kubectl get storageclass longhorn >/dev/null 2>&1; do sleep 5; done'
kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=600s

# en cas d'échec, affiche de quoi comprendre dans le log de la CI
debug() {
  kubectl -n nextcloud get pods
  kubectl -n nextcloud get events --sort-by=.lastTimestamp | tail -20
  exit 1
}

kubectl apply -f nextcloud/
kubectl -n nextcloud rollout status statefulset/mariadb --timeout=300s || debug
kubectl -n nextcloud rollout status deploy/redis --timeout=120s || debug
# la première installation de Nextcloud est longue
kubectl -n nextcloud rollout status deploy/nextcloud --timeout=900s || debug
