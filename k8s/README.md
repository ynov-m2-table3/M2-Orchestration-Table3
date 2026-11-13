# Nextcloud sur Kubernetes (k3d)

Nextcloud 33 + MariaDB 11.4 + Redis, sur un cluster k3d qui tourne sur la VM Azure.
Accès : https://ynov-orchestration-table3.duckdns.org

## Fichiers

| Fichier | Contenu |
|---|---|
| `../image/Dockerfile` | image Nextcloud du projet (non-root, Apache sur 8080) |
| `k3d-cluster.yaml` | définition du cluster local (1 server + 2 agents) |
| `config.env` | le domaine (seule valeur à adapter) |
| `kustomization.yaml` | liste des manifests + image/tag déployés, appliqués en une commande |
| `namespace.yaml` | namespace + comptes de service + RBAC |
| `mariadb.yaml` | base de données |
| `redis.yaml` | cache sessions / verrous |
| `nextcloud.yaml` | config, volume, Deployment, Service, HPA, Ingress |
| `networkpolicy.yaml` | cloisonnement réseau |
| `deploy.sh` | crée les Secrets puis applique le tout |
| `load-test.yaml` | générateur de charge pour la démo du HPA |

## Infra

VM Azure `DockerV2`, **B4as_v2 (4 vCPU, 16 Go)**, Debian 13, avec Docker.

k3d fait tourner k3s dans des conteneurs Docker : `k3d-cluster.yaml` crée **3 nœuds** (1 server + 2 agents) sur la VM.
k3s fournit déjà :

| Besoin | Fourni par k3s |
|---|---|
| Ingress controller | Traefik |
| PVC | local-path-provisioner (StorageClass `local-path`) |
| HPA | metrics-server |
| NetworkPolicy | contrôleur kube-router intégré |

Ports 80/443 : ouverts à tous dans le NSG Azure, publiés par le loadbalancer k3d vers Traefik.

```
Internet ──► VM Azure :443 ──► loadbalancer k3d ──► Traefik (Ingress, TLS)
                                                        │
                                                        ▼
                                            Service nextcloud (:80)
                                                        │
                                          ┌─────────────┴─────────────┐
                                          ▼                           ▼
                                 pods nextcloud (1 à 3, HPA)    PVC nextcloud-html
                                    │                │
                                    ▼                ▼
                           Service db (:3306)   Service redis (:6379)
                                    │                │
                                    ▼                ▼
                            mariadb-0 + PVC       redis
```

## Première installation (une seule fois, sur la VM)

```bash
# 1. outils
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | sudo bash
sudo curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo chmod +x /usr/local/bin/kubectl

# 2. cluster (sans sudo : la config kubectl va dans ~/.kube de l'utilisateur)
k3d cluster create --config k8s/k3d-cluster.yaml
kubectl get nodes
kubectl -n kube-system get pods          # attendre traefik + metrics-server Running
```

**Accès de la CI au cluster.** La CI se connecte en SSH avec l'utilisateur `deploy` (variable `DEPLOY_USER`) et lance `k8s/deploy.sh` dans `APP_DIR`. Cet utilisateur a besoin du dépôt, de Docker et de la config du cluster :

```bash
sudo usermod -aG docker deploy
sudo -u deploy git clone -b Mathias-Nextcloud https://github.com/ynov-m2-table3/M2-Orchestration-Table3.git /home/deploy/M2-Orchestration-Table3
sudo mkdir -p /home/deploy/.kube
k3d kubeconfig get table3 | sudo tee /home/deploy/.kube/config >/dev/null
sudo chown -R deploy:deploy /home/deploy/.kube && sudo chmod 600 /home/deploy/.kube/config
sudo -u deploy kubectl get nodes          # doit répondre
```

Si la CI utilise un autre utilisateur ou un autre dossier, renseigner les variables GitHub `DEPLOY_USER` et `APP_DIR`.

**Secrets GitHub** (*Settings > Secrets and variables > Actions > Secrets*) :

| Secret | Rôle |
|---|---|
| `DB_ROOT_PASSWORD`, `DB_PASSWORD`, `ADMIN_PASSWORD` | mots de passe MariaDB et admin Nextcloud |
| `REDIS_PASSWORD` | optionnel : généré au premier déploiement s'il est absent |
| `SSH_PRIVATE_KEY_MATHIAS` + variable `SSH_KNOWN_HOSTS` | connexion SSH à la VM (déjà en place) |

**Image publique sur ghcr.io.** Après le premier passage de la CI, l'image apparaît dans *Packages* (profil ou organisation GitHub). La passer en **public** (*Package settings > Change visibility*), sinon k3d ne peut pas la télécharger (`ImagePullBackOff`).

## Déployer

**Automatique** : chaque push sur `Mathias-Nextcloud` lance la CI :

1. `manifests` : rendu kustomize + validation des schémas (kubeconform)
2. `image` : build de `image/Dockerfile` -> scan Trivy -> push `ghcr.io/<owner>/nextcloud-table3:sha-<commit>` et `:<version>`
3. `deploy` : SSH sur la VM -> `git pull` -> `k8s/deploy.sh` avec l'image du commit -> test de `status.php`

Les mots de passe passent des secrets GitHub à la VM par l'entrée standard de `ssh`, dans un fichier temporaire (`.env.ci`) supprimé juste après. Ils n'apparaissent ni dans le dépôt, ni dans les logs, ni sur la ligne de commande.

**À la main**, depuis la racine du dépôt sur la VM :

```bash
cp .env.example .env && nano .env       # une fois (gitignoré)
sh k8s/deploy.sh                        # image = newTag de kustomization.yaml
IMAGE_TAG=sha-1a2b3c4 sh k8s/deploy.sh  # ou l'image d'un commit précis
```

Le premier démarrage prend 1 à 3 min (installation de Nextcloud). La `startupProbe` laisse jusqu'à 10 min.

Supprimer : `kubectl delete -k k8s/` (garde le cluster) ou `k3d cluster delete table3` (supprime tout, données comprises).

## Image et tags

`image/Dockerfile` part de l'image officielle `nextcloud:33-apache` et change une seule chose : **Apache écoute sur 8080**. Un utilisateur non-root ne peut pas ouvrir un port inférieur à 1024. Avec 8080, le conteneur tourne entièrement en `www-data` (uid 33), sans privilège ni réglage spécial.

| Tag | Quand | Usage |
|---|---|---|
| `sha-<7 caractères>` | chaque build | déployé par la CI : on sait exactement quel commit tourne |
| `1.0.0` (= `newTag` de `kustomization.yaml`) | chaque build | version par défaut d'un déploiement à la main ; à augmenter à chaque changement de l'image |

Les labels OCI de l'image contiennent le commit et la date de build : `docker inspect ghcr.io/.../nextcloud-table3:<tag>`.

**Scan.** Trivy bloque la CI sur les vulnérabilités **CRITICAL qui ont un correctif**. Le rapport complet (HIGH + CRITICAL) est publié en artefact `trivy-report` de chaque run. Une CVE acceptée après analyse va dans `.trivyignore`, avec la raison en commentaire.

## Depuis la version Docker (TP d'initiation)

| Docker Compose | Kubernetes | Fichier |
|---|---|---|
| projet compose | `Namespace nextcloud` | namespace.yaml |
| service `proxy` (Caddy, ports 80/443) | `Ingress` servi par **Traefik** (inclus dans k3s) + Secret TLS | nextcloud.yaml, deploy.sh |
| service `app` (`nextcloud:33-apache`) | `Deployment nextcloud` (image du projet) + `Service nextcloud` | nextcloud.yaml, image/Dockerfile |
| service `db` | `StatefulSet mariadb` + `Service db` (headless) | mariadb.yaml |
| — | `Deployment redis` + `Service redis` | redis.yaml |
| `environment:` | `ConfigMap nextcloud-config` | nextcloud.yaml |
| `.env` -> `NEXTCLOUD_DOMAIN` | `config.env` -> ConfigMap généré, recopié dans l'Ingress | config.env, kustomization.yaml |
| `secrets:` + `*_FILE` | `Secret nextcloud-secrets` monté dans `/run/secrets` (mêmes `*_FILE`) | deploy.sh |
| volumes `nextcloud`, `db` | `PVC nextcloud-html`, `volumeClaimTemplates` (`data-mariadb-0`) | nextcloud.yaml, mariadb.yaml |
| `healthcheck:` | `readinessProbe` / `livenessProbe` (même `healthcheck.sh`) | mariadb.yaml |
| `depends_on: service_healthy` | pas d'équivalent : Nextcloud ne reçoit du trafic qu'une fois `Ready` | — |
| réseaux `frontend` / `backend` (`internal: true`) | NetworkPolicy | networkpolicy.yaml |
| `restart: unless-stopped` | natif (Deployment / StatefulSet) | — |
| `no-new-privileges`, `cap_drop` | `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` | tous |
| — | `HorizontalPodAutoscaler` 1 -> 3 pods | nextcloud.yaml |
| — | ServiceAccount / Role / RoleBinding | namespace.yaml |

## Choix de sécurité

**Tout en non-root, avec `capabilities: drop ALL` partout.**
En Docker, `cap_drop: ALL` cassait Nextcloud et MariaDB : leurs images démarrent en root pour faire des `chown`, puis changent d'utilisateur.
Ici, on les démarre **directement** avec le bon utilisateur (`runAsUser: 33` = www-data, `999` = mysql), et `fsGroup` donne les droits sur les volumes. Il n'y a plus de `chown` ni de changement d'utilisateur, donc plus besoin de capabilities.

**Pod Security `restricted` sur le namespace.** Kubernetes refuse tout pod root, privilégié, ou sans profil seccomp. Test : `kubectl -n nextcloud run test --image=nginx` est refusé.

**Secrets.** Ils restent hors du dépôt : secrets GitHub pour la CI, `.env` gitignoré pour un déploiement à la main. `deploy.sh` les met dans un Secret Kubernetes, monté en fichiers. Le mot de passe Redis est le seul passé en variable d'environnement (limite de l'image).

**RBAC.**
- Les comptes de service des applis ont `automountServiceAccountToken: false` : aucun accès à l'API Kubernetes.
- Le compte `deployer` peut mettre à jour les Deployments et lire l'état des pods, seulement dans le namespace `nextcloud`. Il ne peut **pas** lire les Secrets.

```bash
SA=system:serviceaccount:nextcloud:deployer
kubectl auth can-i patch deployments -n nextcloud --as=$SA   # yes
kubectl auth can-i get secrets -n nextcloud --as=$SA         # no
kubectl auth can-i get pods -n default --as=$SA              # no
```

**NetworkPolicy.**
- Par défaut, rien n'entre dans le namespace.
- Nextcloud n'est joignable que par Traefik (et par le générateur de charge).
- MariaDB et Redis ne sont joignables que par Nextcloud, et n'ont aucune sortie.

```bash
# un pod quelconque ne peut pas joindre la base -> timeout
kubectl -n nextcloud run netcheck --rm -it --image=busybox:1.37 --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"netcheck","image":"busybox:1.37","command":["nc","-zv","-w","3","db","3306"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
```

## HPA : démo

```bash
kubectl -n nextcloud get hpa nextcloud -w            # terminal 1
kubectl apply -f k8s/load-test.yaml                   # terminal 2 : charge
kubectl -n nextcloud get pods -l app=nextcloud -w     # terminal 3 : les pods arrivent
kubectl delete -f k8s/load-test.yaml                  # fin : retour à 1 pod au bout de ~2 min
```

Le HPA vise 60 % du `request` CPU (200m). Au-delà, il ajoute des pods, jusqu'à 3.
La VM est burstable (série B) : éviter d'enchaîner les tests de charge juste avant une démo, pour ne pas épuiser les crédits CPU.

**Pourquoi Redis :** avec plusieurs pods Nextcloud, les sessions et les verrous de fichiers doivent être partagés. Sans Redis, un utilisateur est déconnecté quand le Service l'envoie vers un autre pod.

**Pourquoi ça marche avec un PVC RWO :** le volume `local-path` est attaché à un nœud. Kubernetes place donc tous les pods Nextcloud sur ce nœud, où ils partagent le même dossier. Dans un vrai cluster, il faudrait un volume RWX (NFS, CephFS) ou un stockage objet S3.

## Option : vrai certificat Let's Encrypt

Le domaine DuckDNS pointe vers la VM, donc cert-manager peut obtenir un vrai certificat :

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.3/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager-webhook
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: letsencrypt-staging}
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef: {name: letsencrypt-staging}
    solvers:
      - http01: {ingress: {ingressClassName: traefik}}
EOF
kubectl -n nextcloud annotate ingress nextcloud cert-manager.io/cluster-issuer=letsencrypt-staging --overwrite
kubectl -n nextcloud get certificate -w
```

Toujours tester en **staging** d'abord : Let's Encrypt bloque après 5 échecs par heure. Ensuite, créer le même ClusterIssuer avec l'URL de production (`https://acme-v02.api.letsencrypt.org/directory`), et mettre l'annotation dans `nextcloud.yaml` pour qu'elle survive au prochain déploiement.

## Limites lab -> prod

| Lab | Prod |
|---|---|
| k3d sur une VM : 3 « nœuds » qui sont des conteneurs sur la même machine | Vrais nœuds, plan de contrôle HA (3 control-planes + etcd + VIP) |
| `local-path` : données sur un seul nœud, non répliquées | Stockage répliqué (Longhorn, Ceph) ; RWX ou S3 pour Nextcloud multi-pods |
| Pods Nextcloud tous sur le même nœud (contrainte du PVC RWO) | Pods répartis sur plusieurs nœuds |
| Certificat auto-signé (ou Let's Encrypt via cert-manager) | cert-manager + Let's Encrypt de production |
| MariaDB en 1 réplica, pas de sauvegarde | Galera / opérateur MariaDB, sauvegardes |
| La CI utilise la config admin du cluster | Kubeconfig du compte `deployer` (droits limités), Secrets gérés par un opérateur (External Secrets + Vault) |
| Mot de passe Redis en variable d'env | Fichier ou ACL Redis |
| Pas de cron Nextcloud | `CronJob` qui lance `cron.php` toutes les 5 min |

## Si ça ne démarre pas

```bash
kubectl -n nextcloud get pods
kubectl -n nextcloud describe pod <pod> | tail -20
kubectl -n nextcloud logs <pod>
kubectl -n nextcloud get events --sort-by=.lastTimestamp | tail -20
```

| Symptôme | Piste |
|---|---|
| `ImagePullBackOff` sur nextcloud | Image ghcr.io encore privée (la passer en public), ou nom/owner différent de `newName` |
| `forbidden: violates PodSecurity` | Un pod ne respecte pas `restricted` (voir le message) |
| Nextcloud `Permission denied` sur `/var/www/html` | Vérifier `fsGroup: 33` |
| Nextcloud reste `0/1` | `logs` : base injoignable ? Secret absent ? Installation encore en cours ? |
| Site injoignable | `docker ps` : le loadbalancer k3d publie-t-il 80/443 ? Un autre service les occupe-t-il ? |
| HPA `<unknown>/60%` | `kubectl top pods -n nextcloud` : metrics-server pas encore prêt (attendre 1 min) |
| Page « domaine non approuvé » | `NEXTCLOUD_TRUSTED_DOMAINS` n'est lu qu'à l'installation : `kubectl -n nextcloud exec deploy/nextcloud -- php occ config:system:set trusted_domains 1 --value=<domaine>` |
| CI : `deploy` échoue sur `kubectl get nodes` | L'utilisateur `deploy` n'a pas `~/.kube/config` (voir « Première installation ») |

Commandes `occ` : `kubectl -n nextcloud exec deploy/nextcloud -- php occ status`
