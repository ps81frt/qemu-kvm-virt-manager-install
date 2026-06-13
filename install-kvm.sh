#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
fail()  { echo -e "${RED}[FAILED]${NC} $1"; }
ok()    { echo -e "${GREEN}[INFO]${NC} $1"; }

info "Detection de la distribution..."
DISTRO=$(lsb_release -is 2>/dev/null || echo "Inconnu")
VERSION=$(lsb_release -rs 2>/dev/null || echo "Inconnue")
info "Distribution detectee: $DISTRO $VERSION"

info "Verification du support de la virtualisation materielle (CPU)..."
if grep -E -q '(vmx|svm)' /proc/cpuinfo; then
  ok "CPU compatible virtualisation (VT-x/AMD-V detecte)"
else
  fail "Le CPU ne semble pas supporter VT-x/AMD-V. La virtualisation materielle ne fonctionnera pas."
fi

info "Mise a jour du systeme..."
sudo apt update && sudo apt upgrade -y

info "Detection du paquet QEMU adapte..."
if apt-cache show qemu-kvm 2>/dev/null | grep -q "^Version:"; then
  QEMU_PKG="qemu-kvm"
else
  QEMU_PKG="qemu-system-x86"
fi

PACKAGES="$QEMU_PKG qemu-utils libvirt-daemon-system libvirt-clients virt-manager virtinst virt-viewer dnsmasq-base bridge-utils ovmf cpu-checker"

info "Installation des paquets: $PACKAGES"
sudo apt install -y $PACKAGES

info "Verification de l'installation des paquets..."
for pkg in $PACKAGES; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    ok "$pkg installe correctement"
  else
    error "$pkg ne semble pas installe"
  fi
done

info "Verification du support KVM (kvm-ok)..."
if command -v kvm-ok >/dev/null 2>&1; then
  kvm-ok || warn "KVM ne semble pas active sur ce systeme (verifier le BIOS/UEFI)"
else
  error "kvm-ok introuvable"
fi

info "Activation du service libvirtd..."
if sudo systemctl enable --now libvirtd; then
  ok "libvirtd active avec succes"
else
  fail "Impossible d'activer libvirtd"
fi

info "Verification de l'etat du service libvirtd..."
if systemctl is-active --quiet libvirtd; then
  ok "libvirtd est actif"
else
  fail "libvirtd n'est pas actif"
fi

info "Ajout de l'utilisateur '$USER' aux groupes libvirt et kvm..."
sudo usermod -aG libvirt,kvm $USER

info "Verification des groupes ajoutes..."
for grp in libvirt kvm; do
  if id -nG "$USER" | grep -qw "$grp"; then
    ok "Utilisateur deja dans le groupe $grp (ou ajoute, effectif apres reconnexion)"
  else
    warn "Groupe $grp non detecte pour $USER"
  fi
done

info "Verification de /dev/kvm..."
if [ -e /dev/kvm ]; then
  ls -l /dev/kvm
  ok "/dev/kvm present"
else
  error "/dev/kvm introuvable - verifier le BIOS/UEFI (VT-x/AMD-V) et redemarrer si necessaire"
fi

info "Verification du reseau libvirt par defaut..."
sudo virsh net-list --all

info "Activation du reseau par defaut..."
sudo virsh net-start default 2>/dev/null || warn "Le reseau default est peut-etre deja actif"
sudo virsh net-autostart default

info "Verification finale du reseau..."
sudo virsh net-list --all | grep -q "default" && ok "Reseau 'default' present" || error "Reseau 'default' absent"

ok "Installation terminee."
warn "Deconnecte-toi/reconnecte-toi (ou redemarre) pour que les groupes libvirt/kvm soient actifs avant de lancer virt-manager."
