# Poste de travail Windows (WSL2) pour les TD 2 à 4

Principe : **tout se fait dans le terminal Ubuntu (WSL2)**, pas dans PowerShell ni cmd. Les commandes des sujets sont écrites pour bash. Docker Desktop reste côté Windows et se branche sur Ubuntu.

## Une seule fois, avant le TD

1. **PowerShell** : `wsl --install -d Ubuntu-24.04`, puis redémarrer et créer l'utilisateur Ubuntu.
2. **Docker Desktop** : l'installer (`winget install -e --id Docker.DockerDesktop`), le lancer, puis *Settings > Resources > WSL integration* et cocher Ubuntu-24.04.
3. **Vérification Windows** (PowerShell, dans le dossier du kit) :
   `powershell -ExecutionPolicy Bypass -File poste\windows-check.ps1 -Td 3 -WriteWslConfig`
   Appliquer ensuite la mémoire : `wsl --shutdown`, puis relancer Docker Desktop.
4. **Ouvrir Ubuntu** et copier le kit dans votre dossier personnel Linux (`~`), **pas** sous `C:\` ni `/mnt/c` : c'est lent et les droits des fichiers sont faussés.
5. **Installer les outils** : `bash poste/install-outils.sh --td 3`
6. **Vérifier** : `bash poste/check-poste.sh --td 3` : tout doit être `[OK]` (les `[!!]` sont des avertissements).

Remplacez `3` par le numéro du TD (2, 3 ou 4).

**Avant chaque séance** : `source .env.example` dans le terminal Ubuntu (identifiants factices ; une petite fonction `aws` envoie les commandes vers LocalStack ; à refaire dans chaque nouveau terminal).

## Éditeur

Dans VS Code, installez l'extension **WSL**, puis dans le terminal Ubuntu : `code .` dans le dossier du kit. Les fichiers restent côté Linux, avec les bonnes fins de ligne.

## Problèmes fréquents

| Symptôme | Cause et remède |
|---|---|
| `bad interpreter: /bin/bash^M` ou `$'\r': command not found` | Fins de ligne Windows. `sed -i 's/\r$//' scripts/*.sh`, et `git config --global core.autocrlf false` |
| `docker: command not found` dans Ubuntu | Intégration WSL non cochée dans Docker Desktop |
| `Cannot connect to the Docker daemon` | Docker Desktop n'est pas lancé ou n'a pas fini de démarrer |
| LocalStack ou k3d lent, conteneurs tués | Mémoire insuffisante : `.wslconfig` (voir `wslconfig.example`) |
| Le navigateur Windows n'ouvre pas `localhost:8080` (Argo CD) | `kubectl port-forward` doit tourner dans Ubuntu ; relancer `wsl --shutdown` si le renvoi de ports est bloqué |
| `make: command not found` | `sudo apt install -y make` (ou relancer `install-outils.sh`) |
| Pull d'images impossible | Pare-feu ou proxy du réseau : changer de réseau (partage de connexion) |
| Commandes copiées depuis un PDF ou une slide avec des guillemets « courbes » | Retaper les guillemets, ou copier depuis le fichier du kit |
