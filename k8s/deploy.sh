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

# après un redémarrage de DockerV2, Vault est scellé : il faut le déverrouiller à la main
if curl -s "$VAULT_ADDR/v1/sys/seal-status" | jq -e .sealed >/dev/null; then
  echo "Vault est scellé : lancer 'docker exec -it vault vault operator unseal' sur DockerV2" >&2
  exit 1
fi

# lus d'abord dans des variables : si Vault ne répond pas, le script s'arrête ici
DB_PASSWORD=$(vault_get db_password)
DB_ROOT_PASSWORD=$(vault_get db_root_password)
ADMIN_PASSWORD=$(vault_get admin_password)
GRAFANA_PASSWORD=$(vault_get grafana_password)

kubectl apply -f namespaces.yaml

# où Longhorn a le droit de stocker des copies (la région, elle, est posée par bootstrap.sh)
for node in k3s-1 dockerv2 k3s-2; do
  kubectl label node "$node" node.longhorn.io/create-default-disk=true --overwrite >/dev/null
done

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
# 1re installation avec un seul pod (copie des fichiers sur le volume partagé, longue),
# puis 3 pods répartis : jamais plusieurs installations en même temps
kubectl -n nextcloud rollout status deploy/nextcloud --timeout=1800s || debug
kubectl -n nextcloud scale deploy/nextcloud --replicas=3
kubectl -n nextcloud rollout status deploy/nextcloud --timeout=900s || debug