flowchart LR
    user(["👤 Utilisateur"])
    dns["DuckDNS<br/>nextcloud.ynov-table3-k3s.duckdns.org"]
    gh["GitHub Actions<br/>scan Trivy → bootstrap → deploy"]

    user -->|HTTPS| dns
    dns -->|IP publique de k3s-1| traefik

    subgraph NO["🇳🇴 Norvège · 172.16.0.0/16"]
        direction TB
        subgraph K1["k3s-1 · master · 8 Go"]
            traefik["Traefik<br/>ingress + HTTPS"]
            nc1["Nextcloud pod 1"]
            db[("MariaDB")]
            lh1[["copie Longhorn"]]
        end
        subgraph DV["dockerv2 · worker · 8 Go"]
            nc2["Nextcloud pod 2"]
            redis[("Redis<br/>sessions + verrous")]
            lh2[["copie Longhorn"]]
            vault{{"Vault<br/>(Docker)"}}
        end
    end

    subgraph SE["🇸🇪 Suède · 10.10.0.0/16"]
        subgraph K2["k3s-2 · master · 8 Go"]
            nc3["Nextcloud pod 3"]
            lh3[["copie Longhorn"]]
        end
    end

    subgraph PL["🇵🇱 Pologne · 10.11.0.0/16"]
        K3["k3s-3 · master · 4 Go<br/>vote etcd"]
        WP["worker-pl · worker · 4 Go"]
    end

    traefik -->|répartit les requêtes| nc1 & nc2 & nc3
    nc1 & nc2 & nc3 --> db
    nc1 & nc2 & nc3 --> redis

    lh1 <-.->|réplication synchrone| lh2
    lh2 <-.->|réplication synchrone| lh3

    K1 <==>|"etcd (quorum 2/3)"| K2
    K2 <==>|etcd| K3
    K1 <==>|etcd| K3

    gh -->|SSH| K1 & DV & K2 & K3 & WP
    K1 -->|"secrets (réseau privé)"| vault
