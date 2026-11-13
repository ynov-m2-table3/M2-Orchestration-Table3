#!/bin/sh
# Crée le Secret "nextcloud-secrets" à partir du .env (le même que pour le compose).
# Le Secret n'est jamais écrit dans le dépôt : il ne vit que dans le cluster.
# Usage (depuis la racine du dépôt) : sh k8s/scripts/create-secrets.sh
set -eu
ENV_FILE="${1:-.env}"
[ -f "$ENV_FILE" ] || { echo "Fichier $ENV_FILE introuvable (cp .env.example .env)"; exit 1; }

get() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true; }
DB_ROOT_PASSWORD=$(get DB_ROOT_PASSWORD)
DB_PASSWORD=$(get DB_PASSWORD)
ADMIN_PASSWORD=$(get ADMIN_PASSWORD)
REDIS_PASSWORD=$(get REDIS_PASSWORD)
# Redis n'existe pas dans le compose : on génère son mot de passe s'il manque
[ -n "$REDIS_PASSWORD" ] || REDIS_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')

for v in DB_ROOT_PASSWORD DB_PASSWORD ADMIN_PASSWORD; do
  eval "val=\${$v}"
  [ -n "$val" ] && [ "$val" != changeme ] || { echo "$v vide ou 'changeme' dans $ENV_FILE"; exit 1; }
done

kubectl create namespace nextcloud --dry-run=client -o yaml | kubectl apply -f -
# --dry-run + apply : rejouable sans erreur "already exists"
kubectl -n nextcloud create secret generic nextcloud-secrets \
  --from-literal=db_root_password="$DB_ROOT_PASSWORD" \
  --from-literal=db_password="$DB_PASSWORD" \
  --from-literal=admin_password="$ADMIN_PASSWORD" \
  --from-literal=redis_password="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret nextcloud-secrets OK"
