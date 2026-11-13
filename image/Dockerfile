# Image Nextcloud du projet : l'officielle, adaptée pour tourner en non-root sur Kubernetes.
# Différence avec l'officielle : Apache écoute sur 8080 au lieu de 80.
# Un utilisateur non-root ne peut pas ouvrir un port < 1024 : sans ce changement, il faudrait
# soit démarrer en root, soit un sysctl dans le pod.
ARG NEXTCLOUD_VERSION=33-apache
FROM nextcloud:${NEXTCLOUD_VERSION}

RUN sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf \
 && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-available/000-default.conf \
 && grep -q '^Listen 8080$' /etc/apache2/ports.conf

# Traçabilité : la CI renseigne la révision git et la date de build
ARG REVISION=dev
ARG CREATED=unknown
LABEL org.opencontainers.image.title="nextcloud-table3" \
      org.opencontainers.image.description="Nextcloud 33 (Apache) non-root, port 8080" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}"

# www-data, en numérique : Kubernetes peut vérifier runAsNonRoot sans connaître les noms
USER 33:33
EXPOSE 8080
