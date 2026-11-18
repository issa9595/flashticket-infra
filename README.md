# flashticket-flux : dépôt de départ du TD2

Fil rouge FlashTicket, jour 2 : prise de commande asynchrone.
Flux visé : API → `create-order` → file SQS → `process-order` → table `orders` → événement `OrderConfirmed`.

## Contenu

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

## Prérequis sur votre poste

Docker (4 Go de RAM pour LocalStack), AWS CLI (`aws`, v1 ou v2), k6, Node.js 20+, zip.
Aucun compte LocalStack n'est nécessaire.
Variables : `source .env.example` (identifiants factices `test` / `test`, région `eu-west-3`).

**Poste Windows (WSL2) ou outil manquant** : voir `poste/README.md`. Vérification : `bash poste/check-poste.sh --td 2`.

## Démarrer

```bash
source .env.example         # identifiants factices ; `aws` vise désormais LocalStack
make up                     # docker compose up ; prêt quand aws sts get-caller-identity répond
make bootstrap              # après avoir écrit scripts/bootstrap.sh
make deploy                 # après avoir écrit le code des fonctions : relançable
```

`source .env.example` définit une petite fonction `aws` qui ajoute l'adresse de LocalStack à chaque commande de ce terminal (pas besoin de `awslocal`, déprécié). `unset -f aws` pour revenir à un vrai compte AWS. À refaire dans chaque nouveau terminal.
`make reset` repart d'un LocalStack vide ; ensuite `make bootstrap` puis `make deploy`.

La première création de fonction télécharge l'image d'exécution Lambda : prévoyez une minute et une bonne connexion.

## Rappels

- Les ressources sont créées en ligne de commande aujourd'hui ; elles seront reprises en Terraform au jour 3.
- `Idempotency-Key` obligatoire côté API, `ReportBatchItemFailures` côté consommateur.
- Tout est versionné dans ce dépôt, un commit par étape.
