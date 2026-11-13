# M2 Orchestration - Table 3

Nextcloud sur Kubernetes (k3d) : Traefik devant (HTTPS), Nextcloud, MariaDB, Redis.

En ligne : https://ynov-orchestration-table3.duckdns.org
Branche de travail : `Mathias-Nextcloud`

## Contenu du dépôt

| Chemin | Rôle |
|---|---|
| `k8s/` | manifests Kubernetes + script de déploiement -> **voir [`k8s/README.md`](k8s/README.md)** |
| `image/` | Dockerfile de l'image Nextcloud du projet (non-root, Apache sur 8080) |
| `.github/workflows/ci.yml` | CI/CD : validation des manifests, build + scan + push de l'image, déploiement |
| `.env.example` | modèle des mots de passe pour un déploiement à la main (`.env` est gitignoré) |
| `.trivyignore` | CVE acceptées après analyse (vide pour l'instant) |

## Lancer

Tout est détaillé dans [`k8s/README.md`](k8s/README.md). En résumé, sur la VM :

```bash
k3d cluster create --config k8s/k3d-cluster.yaml     # une seule fois
cp .env.example .env && nano .env                     # une seule fois
sh k8s/deploy.sh
```

En temps normal, il suffit de pousser sur `Mathias-Nextcloud` : la CI build l'image, la scanne et déploie.

## CI/CD

| Job | Ce qu'il fait |
|---|---|
| `manifests` | `kubectl kustomize` + validation des schémas (kubeconform), manifests rendus en artefact |
| `image` | build `image/Dockerfile`, scan Trivy (bloquant sur CRITICAL corrigeables, rapport complet en artefact), push sur ghcr.io |
| `deploy` | SSH sur la VM, `git pull`, `k8s/deploy.sh` avec l'image du commit, test de `/status.php` |

Les mots de passe sont dans les **secrets GitHub** (`DB_ROOT_PASSWORD`, `DB_PASSWORD`, `ADMIN_PASSWORD`, `REDIS_PASSWORD`). Ils ne sont jamais dans le dépôt.

## Serveur Azure

- VM `DockerV2`, Debian 13, **B4as_v2** (4 vCPU / 16 Go), Norway East, groupe `TP-Orchestration-Table3`
- connexion avec la clé .pem générée par Azure (à mettre dans `~/.ssh/` sous WSL + `chmod 600`, sinon ssh la refuse) :
  `ssh -i ~/.ssh/DockerV2_key.pem azureuser@ynov-orchestration-table3.duckdns.org`
- la clé est dans le keepass, ne pas la partager : pour donner l'accès à quelqu'un, il envoie sa clé publique et on l'ajoute dans `~/.ssh/authorized_keys` sur la VM
- NSG : 80/443 ouverts à tous, 22 seulement nos IP
- arrêt auto le soir -> l'IP publique change au redémarrage, c'est pour ça qu'on a duckdns
- série B (burstable) : éviter d'enchaîner les tests de charge HPA juste avant une démo (crédits CPU)

DuckDNS : crontab de azureuser (`crontab -l`), met à jour l'IP toutes les 5 min et au reboot.
Le token est seulement dans la crontab de la VM, jamais dans le repo.

Après un redémarrage de la VM, le cluster k3d redémarre avec Docker. Vérifier : `kubectl get nodes` puis `kubectl -n nextcloud get pods`.

## Commandes utiles

```bash
kubectl -n nextcloud get pods,svc,ingress,pvc,hpa         # état général
kubectl -n nextcloud logs -f deploy/nextcloud             # installation, erreurs
kubectl -n nextcloud get events --sort-by=.lastTimestamp  # ce qui s'est passé récemment
kubectl -n nextcloud exec deploy/nextcloud -- php occ status
kubectl -n nextcloud exec deploy/nextcloud -- php occ user:resetpassword admin
k3d cluster stop table3 / k3d cluster start table3        # mettre en pause / relancer le cluster
```

## Historique

Le projet a d'abord été fait en Docker Compose (Caddy + Nextcloud + MariaDB, secrets dans Vault) pendant le TP d'initiation. Cette version reste dans l'historique git. La correspondance Compose -> Kubernetes est détaillée dans [`k8s/README.md`](k8s/README.md).
