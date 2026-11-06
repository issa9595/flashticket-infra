# flashticket-infra : dépôt de départ du TD1

Projet fil rouge FlashTicket. Ce dépôt contient ce que le formateur fournit.
Tout ce que vous produisez pendant le TD est **versionné ici** (un commit par étape).

## Contenu

| Chemin | Rôle |
|---|---|
| `bin/ticketpdf` | Binaire statique x86-64 du service de billets PDF (`bin/ticketpdf-arm64` pour une VM ARM, Multipass sur Mac M1 à M4) |
| `src/ticketpdf/` | Code source (lecture seule, pour comprendre ; inutile de recompiler) |
| `vm/nftables.conf` | Pare-feu du cours, **à adapter** (réseaux source) |
| `vm/99-flashticket.conf` | Réglages noyau du cours, à copier dans `/etc/sysctl.d/` |
| `scripts/verify-td1.sh` | Auto-vérification à lancer dans la VM avant le point de contrôle |
| `vm/`, `network/`, `iam/` | Vos livrables (voir le sujet de TD) |

## Le service ticketpdf

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

## Installation dans la VM (rappel)

```bash
sudo install -d -o root -g root /opt/ticketpdf/bin
sudo install -m 0755 bin/ticketpdf /opt/ticketpdf/bin/ticketpdf   # ou ticketpdf-arm64
```

## Avant de rendre

`sudo bash scripts/verify-td1.sh` puis complétez `REPORT-j1.md`.
