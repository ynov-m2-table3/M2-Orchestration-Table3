#!/bin/sh
# Certificat auto-signé pour le lab (équivalent du "certif auto-signé" de Caddy en local).
# En prod : cert-manager + Let's Encrypt (comme Caddy le fait sur le serveur Azure).
# Usage (depuis la racine du dépôt) : sh k8s/scripts/create-tls.sh
set -eu
DOMAIN=$(grep -E '^NEXTCLOUD_DOMAIN=' k8s/config.env | cut -d= -f2-)
TMP=$(mktemp -d)
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout "$TMP/tls.key" -out "$TMP/tls.crt" \
  -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN"
kubectl create namespace nextcloud --dry-run=client -o yaml | kubectl apply -f -
kubectl -n nextcloud create secret tls nextcloud-tls --cert="$TMP/tls.crt" --key="$TMP/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -rf "$TMP"
echo "Secret nextcloud-tls OK pour $DOMAIN"
