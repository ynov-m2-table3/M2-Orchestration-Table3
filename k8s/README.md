# Nextcloud sur Kubernetes (k3d)

Même appli que le compose (Nextcloud 33 + MariaDB 11.4), déployée sur un cluster k3d local.
Tous les fichiers sont dans `k8s/`, appliqués en une commande avec kustomize (`kubectl apply -k k8s/`).

## Infra

Une seule VM suffit : **Debian 13, 4 vCPU, 8 Go RAM, 60 Go disque**, avec Docker (le même que pour le compose).

k3d fait tourner k3s dans des conteneurs Docker : `k3d-cluster.yaml` crée **3 nœuds** (1 server + 2 agents) dans cette VM.
k3s fournit déjà ce que demande le sujet :

| Besoin | Fourni par k3s |
|---|---|
| Ingress controller | Traefik |
| PVC | local-path-provisioner (StorageClass `local-path`) |
| HPA | metrics-server |
| NetworkPolicy | contrôleur kube-router intégré |

La VM Azure (B2als_v2 : 2 vCPU / 4 Go) est trop petite pour faire tourner k3d en plus du compose.

## Lancer

Depuis la racine du dépôt, sur la VM :

```bash
# 1. cluster (une seule fois)
docker compose down                       # le compose et k3d utilisent tous les deux 80/443
sh k8s/scripts/create-cluster.sh

# 2. adapter le domaine à l'IP de la VM
nano k8s/config.env                       # NEXTCLOUD_DOMAIN=nextcloud.<IP-VM>.nip.io

# 3. déployer (secrets depuis le .env + certificat auto-signé + manifests)
cp .env.example .env && nano .env         # si pas déjà fait (mêmes mdp que le compose)
sh k8s/scripts/deploy.sh
```

-> `https://nextcloud.<IP-VM>.nip.io` (certificat auto-signé), login `admin`, mdp = `ADMIN_PASSWORD` du `.env`.

Le premier démarrage prend 1 à 2 min (installation de Nextcloud). La `startupProbe` laisse jusqu'à 10 min avant de considérer le pod en échec.

Supprimer : `kubectl delete -k k8s/` (garde le cluster) ou `k3d cluster delete table3` (supprime tout, données comprises).

## Compose -> Kubernetes

| Compose | Kubernetes | Fichier |
|---|---|---|
| projet compose | `Namespace nextcloud` | namespace.yaml |
| service `proxy` (Caddy, ports 80/443) | `Ingress` servi par **Traefik** (inclus dans k3s) + Secret TLS | ingress.yaml, scripts/create-tls.sh |
| service `app` | `Deployment nextcloud` + `Service nextcloud` | nextcloud.yaml |
| service `db` | `StatefulSet mariadb` + `Service db` (headless) | mariadb.yaml |
| — (nouveau) | `Deployment redis` + `Service redis` | redis.yaml |
| `environment:` (valeurs non sensibles) | `ConfigMap nextcloud-config` | nextcloud.yaml |
| `.env` -> `NEXTCLOUD_DOMAIN` | `config.env` -> ConfigMap généré par kustomize, recopié dans l'Ingress | config.env, kustomization.yaml |
| `secrets:` + `*_FILE` | `Secret nextcloud-secrets` monté dans `/run/secrets` (mêmes chemins, mêmes `*_FILE`) | scripts/create-secrets.sh |
| volume `nextcloud` | `PVC nextcloud-html` | nextcloud.yaml |
| volume `db` | `volumeClaimTemplates` du StatefulSet (`data-mariadb-0`) | mariadb.yaml |
| volume `caddy_data` | plus besoin (pas de Let's Encrypt en lab) | — |
| `healthcheck:` de db | `readinessProbe` / `livenessProbe` (même commande `healthcheck.sh`) | mariadb.yaml |
| `depends_on: service_healthy` | pas d'équivalent : Nextcloud redémarre tant que la base ne répond pas, et il ne reçoit du trafic qu'une fois `Ready` | — |
| réseau `frontend` | NetworkPolicy : seul Traefik peut joindre Nextcloud | networkpolicy.yaml |
| réseau `backend` + `internal: true` | NetworkPolicy : seul Nextcloud joint MariaDB/Redis, et ils n'ont aucune sortie | networkpolicy.yaml |
| `restart: unless-stopped` | natif (le Deployment/StatefulSet recrée les pods) | — |
| `security_opt: no-new-privileges` | `allowPrivilegeEscalation: false` | tous |
| `cap_drop: [ALL]` (proxy seulement) | `capabilities.drop: [ALL]` sur **tous** les conteneurs | tous |
| — | `HorizontalPodAutoscaler` 1 -> 3 pods | hpa.yaml |
| — | ServiceAccount / Role / RoleBinding | rbac.yaml |

## Choix de sécurité

**Tout en non-root, même Nextcloud et MariaDB.**
Dans le compose, `cap_drop: ALL` cassait app et db, parce que leurs images démarrent en root pour faire des `chown` puis changer d'utilisateur.
Ici, on les démarre **directement** avec le bon utilisateur (`runAsUser: 33` = www-data, `999` = mysql), et `fsGroup` donne les droits sur les volumes. Il n'y a plus de `chown` ni de changement d'utilisateur, donc `drop: ALL` passe partout.

Apache doit écouter sur le port 80, ce qui est normalement réservé à root. On l'autorise avec le sysctl `net.ipv4.ip_unprivileged_port_start=0`. Ce sysctl est classé « safe » : il ne s'applique qu'au réseau du pod.

**Pod Security `restricted` sur le namespace.** Kubernetes refuse tout pod qui ne respecte pas ces règles (root, escalade de privilèges, capabilities, seccomp). Test : `kubectl -n nextcloud run test --image=nginx` est refusé.

**Secrets.** Ils restent hors du dépôt (`.env` est gitignoré). `create-secrets.sh` les met dans un Secret Kubernetes. Ils sont montés en fichiers, avec la même méthode `*_FILE` que le compose. Le mot de passe Redis est le seul passé en variable d'environnement (limite de l'image).

**RBAC.**
- Les comptes de service des applis ont `automountServiceAccountToken: false` : aucun accès à l'API Kubernetes.
- Le compte `deployer` (prévu pour la CI) peut mettre à jour les Deployments et lire l'état des pods, seulement dans le namespace `nextcloud`. Il ne peut **pas** lire les Secrets.

Démo :

```bash
SA=system:serviceaccount:nextcloud:deployer
kubectl auth can-i patch deployments -n nextcloud --as=$SA   # yes
kubectl auth can-i get secrets -n nextcloud --as=$SA         # no
kubectl auth can-i get pods -n default --as=$SA              # no
```

**NetworkPolicy.** Elles remplacent les réseaux `frontend` / `backend` du compose. Démo :

```bash
# un pod quelconque ne peut pas joindre la base -> timeout
kubectl -n nextcloud run netcheck --rm -it --image=busybox:1.37 --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"netcheck","image":"busybox:1.37","command":["nc","-zv","-w","3","db","3306"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
```

## HPA : démo

```bash
kubectl -n nextcloud get hpa nextcloud -w           # terminal 1
kubectl apply -f k8s/tests/load-generator.yaml       # terminal 2 : charge
kubectl -n nextcloud get pods -l app=nextcloud -w    # terminal 3 : les pods arrivent
kubectl delete -f k8s/tests/load-generator.yaml      # fin : retour à 1 pod au bout de ~2 min
```

Le HPA vise 60 % du `request` CPU (200m). Au-delà, il ajoute des pods, jusqu'à 3.

**Pourquoi Redis :** avec plusieurs pods Nextcloud, les sessions et les verrous de fichiers doivent être partagés. Sans Redis, un utilisateur est déconnecté quand le Service l'envoie vers un autre pod.

**Pourquoi ça marche avec un PVC RWO :** le volume `local-path` est attaché à un nœud. Kubernetes place donc tous les pods Nextcloud sur ce nœud, où ils partagent le même dossier. Dans un vrai cluster, il faudrait un volume RWX (NFS, CephFS) ou un stockage objet S3 (cf. limites).

## Limites lab -> prod

| Lab | Prod |
|---|---|
| k3d dans une VM : 3 « nœuds » qui sont en fait des conteneurs sur la même machine | Vrais nœuds, plan de contrôle HA (cf. TP kubeadm : 3 CP + etcd + VIP) |
| `local-path` : données sur un seul nœud, non répliquées | Stockage répliqué (Longhorn, Ceph) ; RWX ou S3 pour Nextcloud multi-pods |
| Pods Nextcloud tous sur le même nœud (contrainte du PVC RWO) | Pods répartis sur plusieurs nœuds |
| Certificat auto-signé | cert-manager + Let's Encrypt |
| MariaDB en 1 réplica | Galera / opérateur MariaDB, sauvegardes |
| Secret créé à la main depuis `.env` | Vault + External Secrets Operator |
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
| `forbidden: violates PodSecurity` | Un pod ne respecte pas `restricted` (voir le message) |
| Nextcloud `Permission denied` sur `/var/www/html` | Vérifier `fsGroup: 33` ; en dernier recours, retirer le label PodSecurity et tester en root pour isoler |
| Nextcloud reste `0/1` | `logs` : base injoignable ? Secret absent ? Install encore en cours ? |
| Pas d'`EXTERNAL-IP` sur Traefik / site injoignable | `docker ps` : le loadbalancer k3d publie-t-il 80/443 ? Le compose tourne-t-il encore ? |
| HPA `<unknown>/60%` | `kubectl top pods -n nextcloud` : metrics-server pas encore prêt (attendre 1 min) |
| Page « domaine non approuvé » | `NEXTCLOUD_TRUSTED_DOMAINS` n'est lu qu'à l'installation. Modifier avec `occ config:system:set trusted_domains 1 --value=<domaine>` ou réinstaller (`kubectl delete -k k8s/` + supprimer les PVC) |

Commandes `occ` : `kubectl -n nextcloud exec deploy/nextcloud -- php occ status`
