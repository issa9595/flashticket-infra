#!/usr/bin/env bash
# Vérification automatique du point de contrôle TD1 (à lancer DANS la VM du binôme).
# Usage : sudo bash scripts/verify-td1.sh [chemin_du_depot]
# Le script ne modifie rien. Il aide l'enseignant (5 min par binôme) mais ne remplace
# ni la lecture du REPORT-j1.md ni la vérification manuelle du refus SSH par mot de passe.
set -u
REPO="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
ok=0; ko=0
check() { # check "libellé" commande...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  [OK] %s\n' "$label"; ok=$((ok+1))
  else printf '  [KO] %s\n' "$label"; ko=$((ko+1)); fi
}
[ "$(id -u)" -eq 0 ] || { echo "À lancer avec sudo."; exit 2; }

echo "== SSH (3 pts)"
check "PasswordAuthentication no"  bash -c "sshd -T | grep -qi '^passwordauthentication no'"
check "PermitRootLogin no"         bash -c "sshd -T | grep -qi '^permitrootlogin no'"
check "AllowUsers deploy"          bash -c "sshd -T | grep -qi '^allowusers deploy'"
check "MaxAuthTries <= 3"          bash -c "[ \$(sshd -T | awk '/^maxauthtries/{print \$2}') -le 3 ]"
check "Clé autorisée pour deploy"  test -s /home/deploy/.ssh/authorized_keys

echo "== Surface minimale (2 pts)"
echo "  (à juger par l'enseignant) ports en écoute :"
ss -tlnH | awk '{print "     " $4}'
check "unattended-upgrades actif"  bash -c "systemctl is-enabled unattended-upgrades"
check "nftables : 8443 ouvert, politique drop" bash -c "nft list ruleset | grep -q 'dport 8443' && nft list ruleset | grep -q 'policy drop'"
check "sysctl : rp_filter / syncookies" bash -c "[ \$(sysctl -n net.ipv4.tcp_syncookies) = 1 ]"

echo "== Unité systemd (3 pts)"
check "ticketpdf actif"            systemctl is-active ticketpdf
check "tourne sous l'utilisateur ticketpdf" bash -c "ps -o user= -C ticketpdf | grep -qx ticketpdf"
score=$(systemd-analyze security ticketpdf.service --no-pager 2>/dev/null | awk '/Overall exposure level/{print $(NF-1)}')
echo "  score d'exposition systemd : ${score:-inconnu} (cible <= 4)"
check "score <= 4" bash -c "awk -v s='${score:-99}' 'BEGIN{exit !(s+0<=4)}'"
check "/healthz répond (le service sait écrire)" bash -c "curl -sk --max-time 5 https://localhost:8443/healthz | grep -q ok"

echo "== AppArmor (3 pts)"
check "profil en mode enforce" bash -c "grep -q '^/opt/ticketpdf/bin/ticketpdf (enforce)' /sys/kernel/security/apparmor/profiles"
code=$(curl -sk --max-time 5 -o /tmp/shadow.out -w '%{http_code}' 'https://localhost:8443/debug/read?path=/etc/shadow')
check "/etc/shadow refusé (code $code, aucun contenu)" bash -c "! grep -q 'root:' /tmp/shadow.out"
rm -f /tmp/shadow.out
check "test.pdf lisible"  bash -c "curl -sk --max-time 5 'https://localhost:8443/debug/read?path=/var/lib/ticketpdf/test.pdf' | head -c4 | grep -q '%PDF'"
check "refus tracé (journal ou dmesg)" bash -c "journalctl -k --no-pager -n 400 2>/dev/null | grep -qi 'apparmor=\"DENIED\".*ticketpdf' || dmesg 2>/dev/null | grep -qi 'apparmor=\"DENIED\".*ticketpdf'"

echo "== TLS (2 pts avec IAM)"
check "certificat fourni dans /etc/ticketpdf/tls" test -s /etc/ticketpdf/tls/tls.crt
check "TLS 1.2 ou 1.3 accepté" bash -c "echo | openssl s_client -connect localhost:8443 2>/dev/null | grep -Eq 'TLSv1\.[23]'"
check "TLS 1.1 refusé" bash -c "! (echo | openssl s_client -tls1_1 -connect localhost:8443 2>&1 | grep -q 'Cipher is [^(]')"

echo "== Dépôt : réseau et IAM (4 pts avec TLS)"
for f in vm/10-hardening.conf vm/nftables.conf vm/99-flashticket.conf vm/ticketpdf.service network/network.tf REPORT-j1.md; do
  check "présent : $f" test -s "$REPO/$f"
done
ls "$REPO"/vm/*apparmor* "$REPO"/vm/opt.ticketpdf* >/dev/null 2>&1 && echo "  [OK] profil AppArmor présent" || echo "  [KO] profil AppArmor absent de vm/"
if command -v terraform >/dev/null; then
  check "terraform validate" bash -c "cd '$REPO/network' && terraform init -backend=false -input=false >/dev/null && terraform validate"
else
  echo "  [--] terraform absent : valider à la main"
fi
for j in "$REPO"/iam/*.json; do
  [ -e "$j" ] || { echo "  [KO] aucun fichier iam/*.json"; ko=$((ko+1)); break; }
  check "$(basename "$j") : JSON valide" python3 -m json.tool "$j"
  if grep -Eq '"(Action|Resource)"[[:space:]]*:[[:space:]]*(\[[^]]*)?"\*"' "$j" || grep -Eq '"[a-z0-9]+:\*"' "$j"; then
    echo "  [!!] $(basename "$j") contient un * : exiger la justification écrite"
  fi
done

echo; echo "Résultat : $ok OK, $ko KO (la note finale reste à l'appréciation de l'enseignant)."
