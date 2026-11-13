# Image Nextcloud du projet : l'officielle, adaptée pour tourner en non-root sur Kubernetes.
ARG NEXTCLOUD_VERSION=33-apache
FROM nextcloud:${NEXTCLOUD_VERSION}

# 1) Mises à jour de sécurité Debian : l'image officielle peut avoir du retard
#    (ex. : CVE-2026-119618 sur apache2, détectée par le scan Trivy de la CI)
RUN apt-get update \
 && apt-get -y upgrade \
 && rm -rf /var/lib/apt/lists/*

# 2) Apache sur 8080 : un utilisateur non-root ne peut pas ouvrir un port < 1024
RUN sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf \
 && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-available/000-default.conf \
 && grep -q '^Listen 8080$' /etc/apache2/ports.conf

# 3) Le script de démarrage écrit la config des sessions Redis dans un dossier qui appartient
#    à root. On crée le fichier ici (en root, au build) et on le donne à www-data :
#    au démarrage, il peut le réécrire sans aucun privilège.
RUN touch /usr/local/etc/php/conf.d/redis-session.ini \
 && chown www-data:www-data /usr/local/etc/php/conf.d/redis-session.ini

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