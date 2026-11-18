#!/usr/bin/env bash
# Vérifie le poste avant un TD. À lancer dans le terminal Ubuntu (WSL2), Linux ou macOS.
# Usage : bash poste/check-poste.sh --td 2|3|4
# Code de sortie : 0 si aucun [KO], 1 sinon. Les [!!] sont des avertissements.
set -uo pipefail

TD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --td) TD="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
case "$TD" in 2|3|4) ;; *) echo "Usage : bash poste/check-poste.sh --td 2|3|4"; exit 2 ;; esac

nko=0; nwarn=0
pass() { printf '  [OK] %s\n' "$1"; }
warn() { printf '  [!!] %s\n       -> %s\n' "$1" "$2"; nwarn=$((nwarn + 1)); }
fail() { printf '  [KO] %s\n       -> %s\n' "$1" "$2"; nko=$((nko + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }

# Mémoire minimale (KO en dessous) et recommandée (!! en dessous), en Gio, pour Docker.
case "$TD" in
  2) mem_min=3; mem_rec=4 ;;
  3) mem_min=6; mem_rec=8 ;;
  4) mem_min=4; mem_rec=6 ;;
esac

echo "== Environnement"
os="$(uname -s)"
kernel="$(uname -r)"
wsl="non"
if [ "$os" = "Linux" ] && grep -qi microsoft /proc/version 2>/dev/null; then
  if echo "$kernel" | grep -qi 'microsoft-standard'; then
    wsl="2"; pass "WSL2 détecté (noyau $kernel)"
  else
    wsl="1"; fail "WSL1 détecté" "dans PowerShell : wsl --set-version <nom-de-la-distribution> 2"
  fi
elif [ "$os" = "Linux" ]; then
  pass "Linux natif"
elif [ "$os" = "Darwin" ]; then
  pass "macOS"
else
  fail "système inattendu : $os" "utilisez WSL2 (Ubuntu) sur Windows"
fi

here="$(pwd -P)"
case "$here" in
  /mnt/[a-z]/*) fail "le dossier de travail est sur le disque Windows ($here)" "copiez le kit dans votre dossier personnel Ubuntu : cp -r $here ~/ puis cd ~/$(basename "$here")" ;;
  *) pass "dossier de travail dans le système de fichiers Linux ($here)" ;;
esac

crlf="$(grep -rIl --include='*.sh' --include='Makefile' --exclude-dir=node_modules --exclude-dir=.git $'\r' . 2>/dev/null | head -5)"
if [ -n "$crlf" ]; then
  fail "fins de ligne Windows (CRLF) dans des scripts : $(echo "$crlf" | tr '\n' ' ')" "sed -i 's/\\r\$//' <fichier> ; puis git config --global core.autocrlf false"
else
  pass "fins de ligne des scripts : LF"
fi

echo "== Outils"
need() { # need <commande> <aide>
  if have "$1"; then pass "$1 : $("$1" --version 2>&1 | head -1 | cut -c1-60)"; else fail "$1 absent" "$2"; fi
}
inst="bash poste/install-outils.sh --td $TD"
need git  "sudo apt install -y git"
need make "sudo apt install -y make"
need curl "sudo apt install -y curl"
need docker "installer Docker Desktop (Windows) et activer l'intégration WSL pour votre distribution"
need aws "$inst"
if have aws; then
  if [ "$(type -t aws)" = "function" ] && [ -n "${AWS_ENDPOINT_URL:-}" ]; then
    pass "aws vise LocalStack ($AWS_ENDPOINT_URL), via la fonction de .env.example"
  else
    warn "aws n'est pas redirigé vers LocalStack dans ce terminal" "source .env.example (dépôt du TD2) avant de travailler, dans chaque terminal"
  fi
fi
case "$TD" in
  2)
    need zip "sudo apt install -y zip"
    need python3 "sudo apt install -y python3"
    need k6 "$inst"
    if have node; then
      major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
      if [ "$major" -ge 20 ] 2>/dev/null; then pass "node $major"; else fail "node $major : version 20 ou plus requise" "$inst"; fi
    else
      fail "node absent" "$inst"
    fi
    ;;
  3)
    need k3d "$inst"
    need kubectl "$inst"
    ;;
  4)
    need k6 "$inst"
    ;;
esac
if [ "$TD" != 2 ]; then
  if have terraform; then pass "terraform : $(terraform version 2>&1 | head -1)"
  elif have tofu; then pass "tofu : $(tofu version 2>&1 | head -1)"
  else fail "terraform (ou tofu) absent" "$inst"; fi
fi
if [ "$TD" = 4 ]; then
  if date -u -d @0 >/dev/null 2>&1; then pass "date GNU (option -d) : les scripts de chronologie fonctionneront"
  else fail "date ne comprend pas -d (macOS ?)" "brew install coreutils puis utiliser gdate, ou travailler sous Linux/WSL"; fi
fi

echo "== Docker"
if have docker; then
  if docker info >/dev/null 2>&1; then
    pass "le démon Docker répond"
    if docker compose version >/dev/null 2>&1; then pass "docker compose : $(docker compose version --short 2>/dev/null)"
    else fail "docker compose absent" "mettre Docker Desktop à jour"; fi
    mem_b="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
    mem_g="$(awk -v b="$mem_b" 'BEGIN{printf "%.1f", b/1073741824}')"
    if awk -v g="$mem_g" -v m="$mem_min" 'BEGIN{exit !(g<m)}'; then
      fail "mémoire disponible pour Docker : $mem_g Gio (minimum $mem_min)" "créer %USERPROFILE%\\.wslconfig (modèle : poste/wslconfig.example), puis : wsl --shutdown et relancer Docker Desktop"
    elif awk -v g="$mem_g" -v m="$mem_rec" 'BEGIN{exit !(g<m)}'; then
      warn "mémoire disponible pour Docker : $mem_g Gio (recommandé $mem_rec)" "modèle de réglage : poste/wslconfig.example"
    else
      pass "mémoire disponible pour Docker : $mem_g Gio"
    fi
  else
    fail "le démon Docker ne répond pas" "lancer Docker Desktop, attendre « Engine running », vérifier Settings > Resources > WSL integration"
  fi
fi

echo "== Disque et réseau"
free_g="$(df -Pk . 2>/dev/null | awk 'NR==2{printf "%.0f", $4/1048576}')"
if [ -n "${free_g:-}" ]; then
  if [ "$free_g" -ge 15 ]; then pass "espace libre : $free_g Gio"; else warn "espace libre : $free_g Gio (15 Gio conseillés pour les images)" "libérer de l'espace (docker system prune)"; fi
fi
case "$TD" in
  3) hosts="registry-1.docker.io quay.io ghcr.io registry.k8s.io github.com" ;;
  *) hosts="registry-1.docker.io github.com" ;;
esac
for h in $hosts; do
  code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "https://$h/" 2>/dev/null || true)"
  if [ -n "$code" ] && [ "$code" != "000" ]; then pass "$h joignable"; else fail "$h injoignable" "pare-feu ou proxy du réseau : changer de réseau ou me prévenir avant le TD"; fi
done

echo
if [ "$nko" -eq 0 ]; then
  echo "Poste prêt pour le TD $TD ($nwarn avertissement(s))."
else
  echo "Poste NON prêt pour le TD $TD : $nko point(s) [KO] à corriger."
fi
echo "Rapport à envoyer à l'enseignant : td=$TD os=$os wsl=$wsl ko=$nko warn=$nwarn"
[ "$nko" -eq 0 ]
