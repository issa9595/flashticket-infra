# FlashTicket : projet fil rouge

Branche `td2` : le TD1 (base sécurisée) et le TD2 (prise de commande asynchrone) dans le même dépôt.

| Jour | Sujet | Fichiers | Rapport |
|---|---|---|---|
| 1 | La base sécurisée | `vm/`, `network/`, `iam/`, `bin/`, `src/`, `scripts/verify-td1.sh` | `REPORT-j1.md` |
| 2 | La prise de commande asynchrone | `functions/`, `loadtest/`, `scripts/bootstrap.sh`, `scripts/deploy.sh`, `scripts/smoke.sh`, `scripts/partie-b.sh`, `scripts/partie-c.sh`, `Makefile`, `docker-compose.yml` | `REPORT-j2.md` |

## flashticket-infra : dépôt de départ du TD1

Projet fil rouge FlashTicket. Ce dépôt contient ce que le formateur fournit.
Tout ce que vous produisez pendant le TD est **versionné ici** (un commit par étape).

### Contenu

| Chemin | Rôle |
|---|---|
| `bin/ticketpdf` | Binaire statique x86-64 du service de billets PDF (`bin/ticketpdf-arm64` pour une VM ARM, Multipass sur Mac M1 à M4) |
| `src/ticketpdf/` | Code source (lecture seule, pour comprendre ; inutile de recompiler) |
| `vm/nftables.conf` | Pare-feu du cours, **à adapter** (réseaux source) |
| `vm/99-flashticket.conf` | Réglages noyau du cours, à copier dans `/etc/sysctl.d/` |
| `scripts/verify-td1.sh` | Auto-vérification à lancer dans la VM avant le point de contrôle |
| `vm/`, `network/`, `iam/` | Vos livrables (voir le sujet de TD) |

### Le service ticketpdf

- HTTPS sur le port **8443**, TLS 1.2 minimum.
- Sans certificat dans `/etc/ticketpdf/tls/` (`tls.crt` et `tls.key`), il en génère un auto-signé éphémère : normal en partie B, à remplacer en partie C.
- Écrit ses PDF dans `/var/lib/ticketpdf`.
- Réglable par variables d'environnement : `TICKETPDF_LISTEN`, `TICKETPDF_DATA_DIR`, `TICKETPDF_TLS_DIR`.

| Requête | Effet |
|---|---|
| `GET /healthz` | `ok` si le répertoire de données est inscriptible |
| `POST /tickets` avec `{"order_id":"o-1","event":"Concert","holder":"Ada","seat":"B12"}` | crée `/var/lib/ticketpdf/o-1.pdf` |
| `GET /tickets/o-1.pdf` | renvoie le PDF |
| `GET /debug/read?path=/chemin` | **lit n'importe quel fichier** (faille voulue) |

Exemple : `curl -k https://localhost:8443/healthz`

> **Avertissement.** `/debug/read` est volontairement trop permissif : c'est la cible du test
> d'évasion de la partie B. N'exécutez ce binaire que dans la VM du TD, jamais sur votre machine.

### Installation dans la VM (rappel)

```bash
sudo install -d -o root -g root /opt/ticketpdf/bin
sudo install -m 0755 bin/ticketpdf /opt/ticketpdf/bin/ticketpdf   # ou ticketpdf-arm64
```

### Avant de rendre

`sudo bash scripts/verify-td1.sh` puis complétez `REPORT-j1.md`.

## flashticket-flux : dépôt de départ du TD2

Fil rouge FlashTicket, jour 2 : prise de commande asynchrone.
Flux visé : API → `create-order` → file SQS → `process-order` → table `orders` → événement `OrderConfirmed`.

### Contenu

| Chemin | Rôle |
|---|---|
| `docker-compose.yml` | LocalStack 3.8.1, édition communautaire sans compte (SQS, DynamoDB, Kinesis, Lambda, IAM, CloudWatch Logs) |
| `functions/create-order/` | Squelette TypeScript (Node.js 20) avec des `TODO` à remplir |
| `functions/process-order/` | Squelette Python 3.12 avec des `TODO` à remplir |
| `loadtest/k6.js` | Charge : 50 requêtes/s pendant 60 s, une clé d'idempotence unique par requête |
| `scripts/smoke.sh` | Tests de fumée : 202/400, doublon, message empoisonné vers la DLQ |
| `Makefile` | `make up`, `make bootstrap`, `make deploy`, `make load`, `make smoke`, `make reset`, `make down` |
| `scripts/deploy.sh` | Fourni : construit et déploie `create-order` et `process-order`, relançable |
| `scripts/bootstrap.sh` | **À écrire** : création de toutes les ressources en ligne de commande |

### Prérequis sur votre poste

Docker (4 Go de RAM pour LocalStack), AWS CLI (`aws`, v1 ou v2), k6, Node.js 20+, zip.
Aucun compte LocalStack n'est nécessaire.
Variables : `source .env.example` (identifiants factices `test` / `test`, région `eu-west-3`).

**Poste Windows (WSL2) ou outil manquant** : voir `poste/README.md`. Vérification : `bash poste/check-poste.sh --td 2`.

### Démarrer

```bash
source .env.example         # identifiants factices ; `aws` vise désormais LocalStack
make up                     # docker compose up ; prêt quand aws sts get-caller-identity répond
make bootstrap              # après avoir écrit scripts/bootstrap.sh
make deploy                 # après avoir écrit le code des fonctions : relançable
```

`source .env.example` définit une petite fonction `aws` qui ajoute l'adresse de LocalStack à chaque commande de ce terminal (pas besoin de `awslocal`, déprécié). `unset -f aws` pour revenir à un vrai compte AWS. À refaire dans chaque nouveau terminal.
`make reset` repart d'un LocalStack vide ; ensuite `make bootstrap` puis `make deploy`.

La première création de fonction télécharge l'image d'exécution Lambda : prévoyez une minute et une bonne connexion.

### Rappels

- Les ressources sont créées en ligne de commande aujourd'hui ; elles seront reprises en Terraform au jour 3.
- `Idempotency-Key` obligatoire côté API, `ReportBatchItemFailures` côté consommateur.
- Tout est versionné dans ce dépôt, un commit par étape.
