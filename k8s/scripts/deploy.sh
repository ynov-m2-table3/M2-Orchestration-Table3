#!/bin/sh
# Déploiement complet depuis la racine du dépôt : secrets -> TLS -> manifests -> attente.
set -eu
sh k8s/scripts/create-secrets.sh
kubectl -n nextcloud get secret nextcloud-tls >/dev/null 2>&1 || sh k8s/scripts/create-tls.sh
kubectl apply -k k8s/
kubectl -n nextcloud rollout status statefulset/mariadb --timeout=300s
kubectl -n nextcloud rollout status deployment/redis --timeout=120s
kubectl -n nextcloud rollout status deployment/nextcloud --timeout=600s
DOMAIN=$(grep -E '^NEXTCLOUD_DOMAIN=' k8s/config.env | cut -d= -f2-)
echo
kubectl -n nextcloud get pods,svc,ingress,pvc,hpa
echo
echo "-> https://$DOMAIN  (login admin, mdp = ADMIN_PASSWORD du .env)"
curl -sk "https://$DOMAIN/status.php" && echo
