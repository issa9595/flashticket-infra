#!/usr/bin/env bash
# Installe dans Ubuntu (WSL2) les outils du TD qui manquent. Idempotent : saute ce qui est déjà là.
# Usage : bash poste/install-outils.sh --td 2|3|4        (DRY_RUN=1 pour afficher sans exécuter)
# Docker n'est PAS installé ici : Docker Desktop se met en place côté Windows.
# Les versions ci-dessous sont épinglées ; l'enseignant les valide à l'essai à blanc.
set -uo pipefail

K6_VERSION="${K6_VERSION:-0.54.0}"
K3D_VERSION="${K3D_VERSION:-v5.7.4}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.30.5}"
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.9.8}"

TD=""
while [ $# -gt 0 ]; do
  case "$1" in --td) TD="${2:-}"; shift 2 ;; *) shift ;; esac
done
case "$TD" in 2|3|4) ;; *) echo "Usage : bash poste/install-outils.sh --td 2|3|4"; exit 2 ;; esac

have() { command -v "$1" >/dev/null 2>&1; }
run()  { if [ "${DRY_RUN:-0}" = 1 ]; then echo "+ $*"; else echo "+ $*"; bash -c "$*"; fi; }
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Architecture non prise en charge : $(uname -m)"; exit 1 ;;
esac
BIN="$HOME/.local/bin"; mkdir -p "$BIN"
case ":$PATH:" in *":$BIN:"*) ;; *) export PATH="$BIN:$PATH"; echo "Ajoutez à ~/.bashrc : export PATH=\"\$HOME/.local/bin:\$PATH\"" ;; esac

echo "== Paquets de base"
run "$SUDO apt-get update -y && $SUDO apt-get install -y git make curl zip unzip python3 python3-pip pipx"

echo "== AWS CLI (aws) : l'adresse de LocalStack est ajoutée par la fonction de .env.example"
have aws || run "pipx install awscli"
run "pipx ensurepath >/dev/null 2>&1 || true"

if [ "$TD" = 2 ]; then
  echo "== Node 20"
  need_node=1
  if have node && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 20 ]; then need_node=0; fi
  [ "$need_node" = 1 ] && run "curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO -E bash - && $SUDO apt-get install -y nodejs"
fi

if [ "$TD" = 2 ] || [ "$TD" = 4 ]; then
  echo "== k6 $K6_VERSION"
  have k6 || run "curl -fsSL https://github.com/grafana/k6/releases/download/v${K6_VERSION}/k6-v${K6_VERSION}-linux-${ARCH}.tar.gz | tar -xz -C /tmp && install /tmp/k6-v${K6_VERSION}-linux-${ARCH}/k6 $BIN/k6"
fi

if [ "$TD" = 3 ]; then
  echo "== k3d $K3D_VERSION et kubectl $KUBECTL_VERSION"
  have k3d     || run "curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | TAG=$K3D_VERSION USE_SUDO=false K3D_INSTALL_DIR=$BIN bash"
  have kubectl || run "curl -fsSL -o $BIN/kubectl https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl && chmod +x $BIN/kubectl"
fi

if [ "$TD" != 2 ]; then
  echo "== Terraform $TERRAFORM_VERSION"
  if ! have terraform && ! have tofu; then
    run "curl -fsSL -o /tmp/terraform.zip https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip && unzip -o /tmp/terraform.zip terraform -d $BIN"
  fi
fi

echo
echo "Terminé. Ouvrez un nouveau terminal puis lancez : bash poste/check-poste.sh --td $TD"
