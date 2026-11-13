#!/bin/sh
# Déploie tout sur le cluster k3d. À lancer depuis la racine du dépôt :
#   sh k8s/deploy.sh                          -> image du tag "newTag" de kustomization.yaml
#   IMAGE_TAG=sha-1a2b3c4 sh k8s/deploy.sh    -> image d'un commit précis (utilisé par la CI)
#   IMAGE_REPO=ghcr.io/<owner>/nextcloud-table3   -> autre registre/propriétaire (optionnel)
# Les mots de passe sont lus dans ENV_FILE (.env par défaut). La CI fournit un fichier
# temporaire rempli depuis les secrets GitHub, supprimé juste après.
#
# 1) cert-manager + émetteurs Let's Encrypt (installés seulement s'ils manquent)
# 2) Secret des mots de passe Nextcloud
# 3) Manifests Nextcloud (kubectl apply -k) puis attente que tout soit prêt
# 4) Monitoring Prometheus + Grafana (si helm et GRAFANA_ADMIN_PASSWORD sont présents)
set -eu
ENV_FILE="${ENV_FILE:-.env}"
CERT_MANAGER_VERSION=v1.21.3
DOMAIN=$(grep -E '^NEXTCLOUD_DOMAIN=' k8s/config.env | cut -d= -f2-)
[ -f "$ENV_FILE" ] || { echo "Fichier $ENV_FILE introuvable (cp .env.example .env)"; exit 1; }

get() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true; }
DB_ROOT_PASSWORD=$(get DB_ROOT_PASSWORD)
DB_PASSWORD=$(get DB_PASSWORD)
ADMIN_PASSWORD=$(get ADMIN_PASSWORD)
REDIS_PASSWORD=$(get REDIS_PASSWORD)
GRAFANA_ADMIN_PASSWORD=$(get GRAFANA_ADMIN_PASSWORD)
for v in DB_ROOT_PASSWORD DB_PASSWORD ADMIN_PASSWORD; do
  eval "val=\${$v}"
  [ -n "$val" ] && [ "$val" != changeme ] || { echo "$v vide ou 'changeme' dans $ENV_FILE"; exit 1; }
done

# applique un fichier en réessayant : les webhooks (cert-manager...) mettent quelques secondes à répondre
apply_retry() {
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kubectl apply -f "$1" && return 0
    echo "webhook pas encore prêt, nouvel essai ($i/10)"; sleep 6
  done
  return 1
}

# --- 1) cert-manager + émetteurs Let's Encrypt ---
if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
  echo "== Installation de cert-manager $CERT_MANAGER_VERSION"
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml"
fi
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
apply_retry k8s/cert-manager/issuers.yaml

# --- 2) Secret des mots de passe Nextcloud ---
kubectl create namespace nextcloud --dry-run=client -o yaml | kubectl apply -f -
# Redis : on garde son mot de passe s'il existe déjà, sinon on en génère un
if [ -z "$REDIS_PASSWORD" ]; then
  REDIS_PASSWORD=$(kubectl -n nextcloud get secret nextcloud-secrets -o jsonpath='{.data.redis_password}' 2>/dev/null | base64 -d || true)
  [ -n "$REDIS_PASSWORD" ] || REDIS_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
fi
# --dry-run + apply : rejouable sans erreur "already exists"
kubectl -n nextcloud create secret generic nextcloud-secrets \
  --from-literal=db_root_password="$DB_ROOT_PASSWORD" \
  --from-literal=db_password="$DB_PASSWORD" \
  --from-literal=admin_password="$ADMIN_PASSWORD" \
  --from-literal=redis_password="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- 3) Manifests Nextcloud ---
TARGET=k8s
if [ -n "${IMAGE_TAG:-}" ]; then
  # petit overlay temporaire qui change seulement le tag de l'image (gitignoré)
  IMAGE_NAME=$(grep -E '^\s*newName:' k8s/kustomization.yaml | head -1 | awk '{print $2}')
  mkdir -p .deploy
  cat > .deploy/kustomization.yaml <<EOT
resources: [../k8s]
images:
  - name: $IMAGE_NAME
    newName: ${IMAGE_REPO:-$IMAGE_NAME}
    newTag: "$IMAGE_TAG"
EOT
  TARGET=.deploy
fi
kubectl apply -k "$TARGET"
kubectl -n nextcloud rollout status statefulset/mariadb --timeout=300s
kubectl -n nextcloud rollout status deployment/redis --timeout=120s
kubectl -n nextcloud rollout status deployment/nextcloud --timeout=600s

# --- 4) Monitoring : Prometheus + Grafana (kube-prometheus-stack) ---
if ! command -v helm >/dev/null 2>&1; then
  echo "== helm absent : monitoring ignoré (voir k8s/README.md)"
elif [ -z "$GRAFANA_ADMIN_PASSWORD" ]; then
  echo "== GRAFANA_ADMIN_PASSWORD absent : monitoring ignoré"
else
  echo "== Monitoring"
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community >/dev/null
  # --version : épingler après la 1re install (helm list -n monitoring) pour des déploiements reproductibles
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring ${MONITORING_CHART_VERSION:+--version "$MONITORING_CHART_VERSION"} \
    -f k8s/monitoring/values.yaml \
    --set "grafana.ingress.hosts[0]=grafana.$DOMAIN" \
    --set "grafana.ingress.tls[0].hosts[0]=grafana.$DOMAIN" \
    --wait --timeout 10m
  kubectl apply -f k8s/monitoring/traefik-podmonitor.yaml
  kubectl apply -f k8s/monitoring/dashboard-nextcloud.yaml
  echo "-> https://grafana.$DOMAIN  (login admin, mdp = GRAFANA_ADMIN_PASSWORD)"
fi

echo
kubectl -n nextcloud get pods,svc,ingress,pvc,hpa,certificate
echo
echo "-> https://$DOMAIN  (login admin, mdp = ADMIN_PASSWORD)"
curl -fsS "https://$DOMAIN/status.php" && echo || echo "(pas encore joignable : certificat Let's Encrypt en cours d'émission ?)"
