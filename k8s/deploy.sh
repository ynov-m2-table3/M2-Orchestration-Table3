#!/bin/sh
# Déploie Nextcloud sur le cluster k3d. À lancer depuis la racine du dépôt :
#   sh k8s/deploy.sh                          -> image du tag "newTag" de kustomization.yaml
#   IMAGE_TAG=sha-1a2b3c4 sh k8s/deploy.sh    -> image d'un commit précis (utilisé par la CI)
#   IMAGE_REPO=ghcr.io/<owner>/nextcloud-table3   -> autre registre/propriétaire (optionnel)
# Les mots de passe sont lus dans ENV_FILE (.env par défaut). La CI fournit un fichier
# temporaire rempli depuis les secrets GitHub, supprimé juste après.
# 1) Secret des mots de passe (jamais écrits dans le dépôt)
# 2) Certificat TLS auto-signé (si absent)
# 3) Manifests (kubectl apply -k) puis attente que tout soit prêt
set -eu
ENV_FILE="${ENV_FILE:-.env}"
DOMAIN=$(grep -E '^NEXTCLOUD_DOMAIN=' k8s/config.env | cut -d= -f2-)
[ -f "$ENV_FILE" ] || { echo "Fichier $ENV_FILE introuvable (cp .env.example .env)"; exit 1; }

get() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true; }
DB_ROOT_PASSWORD=$(get DB_ROOT_PASSWORD)
DB_PASSWORD=$(get DB_PASSWORD)
ADMIN_PASSWORD=$(get ADMIN_PASSWORD)
REDIS_PASSWORD=$(get REDIS_PASSWORD)
for v in DB_ROOT_PASSWORD DB_PASSWORD ADMIN_PASSWORD; do
  eval "val=\${$v}"
  [ -n "$val" ] && [ "$val" != changeme ] || { echo "$v vide ou 'changeme' dans $ENV_FILE"; exit 1; }
done

kubectl create namespace nextcloud --dry-run=client -o yaml | kubectl apply -f -

# --- 1) Secret des mots de passe ---
# Redis n'existe pas dans le compose : on garde son mot de passe s'il existe déjà, sinon on en génère un
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

# --- 2) Certificat auto-signé (lab). En prod : cert-manager + Let's Encrypt ---
if ! kubectl -n nextcloud get secret nextcloud-tls >/dev/null 2>&1; then
  TMP=$(mktemp -d)
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "$TMP/tls.key" -out "$TMP/tls.crt" \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" 2>/dev/null
  kubectl -n nextcloud create secret tls nextcloud-tls --cert="$TMP/tls.crt" --key="$TMP/tls.key"
  rm -rf "$TMP"
fi

# --- 3) Manifests ---
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

echo
kubectl -n nextcloud get pods,svc,ingress,pvc,hpa
echo
echo "-> https://$DOMAIN  (login admin, mdp = ADMIN_PASSWORD du .env)"
curl -sk "https://$DOMAIN/status.php" && echo
