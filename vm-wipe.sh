#!/bin/bash
#
# vm-wipe — Suppression complète et propre d'une VM libvirt/KVM (BIOS ou UEFI)
# Usage: vm-wipe <nom_vm>
#

# ===== Couleurs (ANSI-C quoting pour fonctionner aussi dans les heredocs) =====
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ===== Logging =====
log_info() { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_ok() { echo -e "${GREEN}[ OK ]${NC}  $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC}  $1"; }
log_crit() { echo -e "${RED}${BOLD}[CRIT]${NC}  $1"; }
log_step() { echo -e "${BLUE}${BOLD}==>${NC} ${BOLD}$1${NC}"; }
log_exit() { echo -e "${MAGENTA}[EXIT]${NC}  $1"; }

# ===== Aide =====
show_help() {
    cat <<EOF
${BOLD}vm-wipe${NC} — Suppression complète et propre d'une VM libvirt/KVM (BIOS ou UEFI)

${BOLD}USAGE${NC}
    vm-wipe <nom_vm>
    vm-wipe -h | --help

${BOLD}DESCRIPTION${NC}
    Supprime une VM et tous ses résidus :
      - arrêt forcé si la VM tourne
      - définition libvirt (virsh undefine)
      - disque(s) associé(s)
      - NVRAM/UEFI (si présent, détecté automatiquement)
      - état TPM virtuel (si présent, détecté automatiquement)
      - volumes orphelins dans tous les pools de stockage
      - logs résiduels (qemu, swtpm)
      - scan final par nom ET par UUID pour vérifier qu'il ne reste rien

${BOLD}OPTIONS${NC}
    -h, --help    Affiche cette aide et quitte

${BOLD}EXEMPLES${NC}
    vm-wipe ubuntu24.04
    vm-wipe windows11-test

${BOLD}PRÉREQUIS${NC}
    - virsh (libvirt-clients)
    - sudo (pour nettoyer certains fichiers système)
EOF
}

# ===== Vérifications préalables =====
check_prerequisites() {
    if ! command -v virsh >/dev/null 2>&1; then
        log_crit "La commande 'virsh' n'est pas installée (paquet libvirt-clients)."
        exit 1
    fi
}

check_vm_exists() {
    local vm="$1"
    if ! virsh dominfo "$vm" >/dev/null 2>&1; then
        log_crit "La VM '$vm' n'existe pas (ou déjà supprimée)."
        log_exit "Arrêt du script."
        exit 1
    fi
}

# ===== Détection matérielle =====
detect_uefi() {
    local vm="$1"
    if virsh dumpxml "$vm" 2>/dev/null | grep -q "OVMF\|nvram"; then
        log_info "Firmware détecté : UEFI (NVRAM présent)"
        return 0
    else
        log_info "Firmware détecté : BIOS (pas de NVRAM)"
        return 1
    fi
}

detect_tpm() {
    local vm="$1"
    if virsh dumpxml "$vm" 2>/dev/null | grep -q "<tpm "; then
        log_info "TPM virtuel détecté."
        return 0
    else
        log_info "Pas de TPM virtuel sur cette VM."
        return 1
    fi
}

# ===== Étape 1 : Arrêt forcé =====
step_stop_vm() {
    local vm="$1"
    log_step "Étape 1/6 — Arrêt forcé de la VM"
    if virsh domstate "$vm" 2>/dev/null | grep -qi "en cours\|running"; then
        if virsh destroy "$vm" >/dev/null 2>&1; then
            log_ok "VM arrêtée."
        else
            log_fail "Échec de l'arrêt."
        fi
    else
        log_info "VM déjà arrêtée."
    fi
}

# ===== Étape 2 : Suppression définition + disques + nvram + tpm =====
step_undefine() {
    local vm="$1" has_uefi="$2" has_tpm="$3"
    log_step "Étape 2/6 — Suppression définition, disques, NVRAM, TPM"

    local undef_args=(--remove-all-storage)
    [ "$has_uefi" -eq 1 ] && undef_args+=(--nvram)
    [ "$has_tpm" -eq 1 ] && undef_args+=(--tpm)

    local out
    if out=$(virsh undefine "$vm" "${undef_args[@]}" 2>&1); then
        log_ok "Domaine '$vm' supprimé (args: ${undef_args[*]})."
    else
        log_warn "Échec avec options complètes, tentative en mode dégradé..."
        echo -e "${YELLOW}        -> $out${NC}"
        if out=$(virsh undefine "$vm" --remove-all-storage 2>&1); then
            log_ok "Domaine supprimé (mode minimal)."
        else
            log_fail "Échec de la suppression du domaine."
            echo -e "${RED}        -> $out${NC}"
        fi
    fi
}

# ===== Étape 3 : Filet de sécurité TPM via UUID =====
step_cleanup_tpm_residue() {
    local uuid="$1"
    log_step "Étape 3/6 — Vérification résidus TPM (swtpm)"

    if [ -n "$uuid" ] && [ -d "/var/lib/libvirt/swtpm/$uuid" ]; then
        if sudo rm -rf "/var/lib/libvirt/swtpm/$uuid" 2>/dev/null; then
            log_ok "Répertoire TPM résiduel supprimé : /var/lib/libvirt/swtpm/$uuid"
        else
            log_fail "Impossible de supprimer /var/lib/libvirt/swtpm/$uuid"
        fi
    else
        log_info "Aucun résidu TPM trouvé."
    fi
}

# ===== Étape 3b : Filet de sécurité NVRAM =====
step_cleanup_nvram_residue() {
    local vm="$1"
    log_step "Étape 3b/6 — Vérification résidus NVRAM"

    local found=0 nf
    for nf in /var/lib/libvirt/qemu/nvram/*"$vm"*; do
        [ -e "$nf" ] || continue
        found=1
        if sudo rm -f "$nf" 2>/dev/null; then
            log_ok "NVRAM résiduel supprimé : $nf"
        else
            log_fail "Impossible de supprimer NVRAM : $nf"
        fi
    done
    [ "$found" -eq 0 ] && log_info "Aucun NVRAM résiduel trouvé."
}

# ===== Étape 4 : Volumes orphelins dans tous les pools =====
step_cleanup_orphan_volumes() {
    local vm="$1"
    log_step "Étape 4/6 — Recherche de volumes orphelins dans les pools"

    local found=0 pool vol
    for pool in $(virsh pool-list --all --name 2>/dev/null); do
        while read -r vol; do
            [ -z "$vol" ] && continue
            if [[ "$vol" == *"$vm"* ]]; then
                found=1
                log_warn "Volume orphelin trouvé dans pool '$pool' : $vol"
                if virsh vol-delete --pool "$pool" "$vol" >/dev/null 2>&1; then
                    log_ok "Volume '$vol' supprimé du pool '$pool'."
                else
                    log_fail "Impossible de supprimer le volume '$vol'."
                fi
            fi
        done < <(virsh vol-list "$pool" 2>/dev/null | awk 'NR>2 && NF>0 {print $1}')
    done
    [ "$found" -eq 0 ] && log_info "Aucun volume orphelin détecté."
}

# ===== Étape 5 : Nettoyage des logs résiduels =====
step_cleanup_logs() {
    local vm="$1"
    log_step "Étape 5/6 — Nettoyage des logs résiduels"

    local cleaned=0 f
    for f in /var/log/libvirt/qemu/"$vm".log* /var/log/swtpm/libvirt/qemu/"$vm"-swtpm.log*; do
        [ -e "$f" ] || continue
        if sudo rm -f "$f" 2>/dev/null; then
            log_ok "Log supprimé : $f"
            cleaned=1
        else
            log_fail "Impossible de supprimer : $f"
        fi
    done
    [ "$cleaned" -eq 0 ] && log_info "Aucun log résiduel trouvé."
}

# ===== Étape 6 : Vérification finale =====
step_final_scan() {
    local vm="$1" uuid="$2"
    log_step "Étape 6/6 — Vérification finale (scan global)"

    local results
    results=$(find / -iname "*$vm*" 2>/dev/null)
    if [ -n "$uuid" ]; then
        results="$results
$(find / -path "*$uuid*" 2>/dev/null)"
    fi
    results=$(echo "$results" | grep -v '^$')

    if [ -n "$results" ]; then
        log_warn "Des fichiers résiduels ont été trouvés :"
        echo -e "${YELLOW}$results${NC}"
        log_warn "Vérifiez et supprimez-les manuellement si nécessaire."
    else
        log_ok "Aucun résidu détecté. Wipe complet réussi."
    fi
}

# ===== Programme principal =====
main() {
    case "$1" in
    -h | --help)
        show_help
        exit 0
        ;;
    "")
        log_fail "Aucun nom de VM fourni."
        log_exit "Usage: vm-wipe <nom_vm>  (ou vm-wipe -h pour l'aide)"
        exit 1
        ;;
    esac

    local vm="$1"

    check_prerequisites
    check_vm_exists "$vm"

    log_step "Wipe de la VM : $vm"

    local has_uefi=0 has_tpm=0
    detect_uefi "$vm" && has_uefi=1
    detect_tpm "$vm" && has_tpm=1

    local uuid
    uuid=$(virsh domuuid "$vm" 2>/dev/null)
    [ -n "$uuid" ] && log_info "UUID récupéré : $uuid"

    step_stop_vm "$vm"
    step_undefine "$vm" "$has_uefi" "$has_tpm"
    step_cleanup_tpm_residue "$uuid"
    step_cleanup_nvram_residue "$vm"
    step_cleanup_orphan_volumes "$vm"
    step_cleanup_logs "$vm"
    step_final_scan "$vm" "$uuid"

    echo ""
    log_exit "Wipe de '$vm' terminé."
}

main "$@"
