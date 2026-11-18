# Verifie le poste Windows avant un TD. Aucun droit administrateur requis.
# Usage (PowerShell) :
#   powershell -ExecutionPolicy Bypass -File poste\windows-check.ps1 -Td 3
#   ajouter -WriteWslConfig pour creer %USERPROFILE%\.wslconfig s'il n'existe pas
param(
  [ValidateSet(2, 3, 4)][int]$Td = 2,
  [switch]$WriteWslConfig
)
$ErrorActionPreference = 'Continue'
$script:ko = 0
$script:warn = 0
function Ok($m)        { Write-Host "  [OK] $m" -ForegroundColor Green }
function Ko($m, $fix)  { Write-Host "  [KO] $m" -ForegroundColor Red;    Write-Host "       -> $fix"; $script:ko++ }
function Warn($m, $fix){ Write-Host "  [!!] $m" -ForegroundColor Yellow; Write-Host "       -> $fix"; $script:warn++ }

Write-Host "== Windows"
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$build = [int]$os.BuildNumber
if ($build -ge 19041) { Ok "$($os.Caption) (build $build)" }
else { Ko "$($os.Caption) (build $build) trop ancien pour WSL2" "mettre Windows a jour (Windows 10 2004 ou plus, ou Windows 11)" }
if ($os.Caption -match 'Home|Famille') {
  Write-Host "  [i]  Edition Famille : Hyper-V est absent (Multipass/Hyper-V impossible). WSL2 et Docker Desktop fonctionnent."
}

$ram = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
if ($Td -eq 3) { $ramOk = 16; $ramMin = 8 } else { $ramOk = 8; $ramMin = 6 }
if ($ram -ge $ramOk) { Ok "memoire : $ram Go" }
elseif ($ram -ge $ramMin) { Warn "memoire : $ram Go (conseille : $ramOk Go pour le TD $Td)" "fermer navigateur et applications lourdes pendant le TD ; travailler en binome sur le poste le plus puissant" }
else { Ko "memoire : $ram Go (minimum : $ramMin Go pour le TD $Td)" "travailler en binome sur un autre poste" }

$disk = Get-PSDrive -Name C -ErrorAction SilentlyContinue
if ($disk) {
  $free = [math]::Round($disk.Free / 1GB, 0)
  if ($free -ge 30) { Ok "espace libre sur C: $free Go" }
  elseif ($free -ge 15) { Warn "espace libre sur C: $free Go (30 Go conseilles)" "liberer de l'espace avant le TD" }
  else { Ko "espace libre sur C: $free Go" "liberer au moins 15 Go" }
}

if ($cs.HypervisorPresent) { Ok "virtualisation active (hyperviseur present)" }
else {
  $vt = (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled
  if ($vt) { Ok "virtualisation activee dans le BIOS" }
  else { Ko "virtualisation desactivee" "l'activer dans le BIOS/UEFI (Intel VT-x ou AMD SVM) ; sur un portable gere, demander a l'administrateur" }
}

Write-Host "== WSL2"
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wsl) {
  Ko "WSL absent" "PowerShell : wsl --install -d Ubuntu-24.04 (puis redemarrer)"
} else {
  $prev = [Console]::OutputEncoding
  [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
  $list = (& wsl.exe -l -v 2>&1 | Out-String) -replace "`0", ''
  [Console]::OutputEncoding = $prev
  if ($list -match '(?m)^\s*\*?\s*Ubuntu\S*\s+\w+\s+2\s*$') { Ok "distribution Ubuntu en version 2" }
  elseif ($list -match 'Ubuntu') { Ko "Ubuntu present mais pas en version 2" "wsl --set-version Ubuntu-24.04 2" }
  else { Ko "aucune distribution Ubuntu" "wsl --install -d Ubuntu-24.04 (puis redemarrer)" }
}

Write-Host "== Docker Desktop"
$docker = Get-Command docker.exe -ErrorAction SilentlyContinue
if (-not $docker) {
  Ko "Docker Desktop absent" "winget install -e --id Docker.DockerDesktop (droits administrateur), puis redemarrer"
} else {
  $srv = (& docker.exe version --format '{{.Server.Version}}' 2>$null)
  if ($srv) { Ok "moteur Docker $srv en marche" }
  else { Ko "Docker installe mais le moteur ne repond pas" "lancer Docker Desktop et attendre 'Engine running'" }
}
Write-Host "  [i]  Puis : Docker Desktop > Settings > Resources > WSL integration > cocher Ubuntu."

Write-Host "== Memoire allouee a WSL2 (.wslconfig)"
$cfg = Join-Path $env:USERPROFILE '.wslconfig'
if ($ram -ge 16) { $mem = 8 } elseif ($ram -ge 12) { $mem = 6 } else { $mem = [math]::Max(4, [math]::Floor($ram - 3)) }
if ($Td -ne 3 -and $mem -gt 6) { $mem = 6 }
if (Test-Path $cfg) {
  Ok ".wslconfig existe : $cfg (verifier la ligne memory=)"
} elseif ($WriteWslConfig) {
  "[wsl2]`r`nmemory=${mem}GB`r`nswap=2GB`r`n" | Set-Content -Path $cfg -Encoding ASCII
  Ok ".wslconfig cree avec memory=${mem}GB. Appliquer : wsl --shutdown, puis relancer Docker Desktop."
} else {
  Warn "pas de .wslconfig : WSL2 prendra la moitie de la memoire par defaut" "relancer avec -WriteWslConfig (propose memory=${mem}GB) ou copier poste\wslconfig.example"
}

Write-Host ""
if ($script:ko -eq 0) { Write-Host "Poste Windows pret pour le TD $Td ($($script:warn) avertissement(s))." -ForegroundColor Green }
else { Write-Host "Poste Windows NON pret pour le TD $Td : $($script:ko) point(s) [KO]." -ForegroundColor Red }
Write-Host "Etape suivante : ouvrir Ubuntu, puis bash poste/install-outils.sh --td $Td et bash poste/check-poste.sh --td $Td"
Write-Host "Rapport a envoyer a l'enseignant : td=$Td windows=$build ram=${ram}Go ko=$($script:ko) warn=$($script:warn)"
