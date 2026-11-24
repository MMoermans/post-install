#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables below are read by lib/common.sh
# Post-install hardening for a fresh CachyOS (Arch-based) install.
# Run:  sudo ./cachyos/post-install.sh --dry-run   (preview)   then   sudo ./cachyos/post-install.sh
set -uo pipefail

PI_PROG="cachyos/post-install.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

ALL_MODULES=(mirrors updates ssh firewall fail2ban sysctl kernel_modules coredumps journald sudo
             auditd maintenance pacman_checks apparmor boot_params audit_tools)
DEFAULT_ON=(updates firewall fail2ban sysctl kernel_modules coredumps journald sudo
            auditd maintenance pacman_checks audit_tools)
declare -A MODULE_DESC=(
  [mirrors]="rank mirrors with cachyos-rate-mirrors (slow, needs network)"
  [updates]="pacman -Syu and flatpak update (always a full upgrade, never a partial one)"
  [ssh]="install OpenSSH server: no root login, keys only (if a key exists), modern algorithms, validated and rolled back on error"
  [firewall]="ufw: deny incoming, allow outgoing, rate-limited SSH rule when sshd runs"
  [fail2ban]="ban brute-forcing hosts via the journal (only if sshd exists)"
  [sysctl]="kernel pointer/dmesg/ptrace/bpf restrictions, network spoofing and redirect protection (keeps CachyOS performance tuning)"
  [kernel_modules]="block rare network protocols, filesystems and FireWire"
  [coredumps]="no core dumps (they can contain secrets)"
  [journald]="persistent journal"
  [sudo]="use_pty, 5 minute timeout, no visible passwords"
  [auditd]="audit daemon with rules for accounts, sudo, ssh, cron, modules"
  [maintenance]="paccache.timer (trim the package cache) and fstrim.timer"
  [pacman_checks]="warn about weakened pacman signature checks, .pacnew files and orphans"
  [apparmor]="install AppArmor and add the kernel parameters (GRUB automatic; other bootloaders shown)"
  [boot_params]="kernel command line: slab_nomerge, page_alloc.shuffle, randomize_kstack_offset, vsyscall=none, debugfs=off"
  [audit_tools]="lynis, and arch-audit to list packages with known CVEs"
)

AUDIT_PKGS="audit"
SSH_PKG="openssh"
SSH_SERVICE="sshd"
FAIL2BAN_PKGS="fail2ban python-systemd nftables"
# CachyOS ships performance tuning in /usr/lib/sysctl.d; only security keys are set here.
SYSCTL_EXTRA=("kernel.perf_event_paranoid = 2")

KERNEL_PARAMS="slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none debugfs=off"
APPARMOR_PARAMS="lsm=landlock,lockdown,yama,integrity,apparmor,bpf"

pkg_install() { run pacman -S --needed --noconfirm "$@"; }

check_distro() {
  local id="" like=""
  if [[ -r /etc/os-release ]]; then id="$(. /etc/os-release; echo "${ID:-}")"; like="$(. /etc/os-release; echo "${ID_LIKE:-}")"; fi
  have pacman || (( FORCE || DRY_RUN || SANDBOX )) || die "pacman not found; this script is for CachyOS and other Arch-based systems"
  if [[ "$id" != cachyos ]]; then
    if (( ! FORCE )); then
      if [[ "$like" == *arch* || "$id" == arch ]]; then
        die "this is '${id}', not CachyOS. It will mostly work on Arch, but use --force to confirm"
      fi
      die "not an Arch-based system (found '${id:-unknown}'). Use --force to continue anyway"
    fi
    warn "not CachyOS (${id:-unknown}); continuing because of --force"
  fi
}

mod_mirrors() {
  step "Rank mirrors"
  if have cachyos-rate-mirrors; then run cachyos-rate-mirrors; else warn "cachyos-rate-mirrors not found; skipping"; fi
}

mod_updates() {
  step "System updates"
  # -Syu always: Arch does not support partial upgrades.
  run pacman -Syu --noconfirm
  if have flatpak; then run flatpak update -y --noninteractive; fi
  if [[ ! -d "/usr/lib/modules/$(uname -r)" ]] && (( ! SANDBOX )); then
    manual "The running kernel was replaced during the update. Reboot soon"
  fi
}

mod_maintenance() {
  step "Package cache and SSD trim timers"
  pkg_install pacman-contrib
  svc_enable paccache.timer fstrim.timer
}

mod_pacman_checks() {
  step "Pacman configuration checks"
  local conf="$ROOT/etc/pacman.conf" n
  if [[ -f "$conf" ]] && grep -Eq '^[[:space:]]*SigLevel[[:space:]]*=.*(Never|TrustAll)' "$conf"; then
    warn "pacman.conf weakens package signature checking (SigLevel with Never or TrustAll)"
    manual "Review SigLevel in /etc/pacman.conf: packages are not being verified"
  else
    info "package signature checking is not weakened"
  fi
  n="$(find "$ROOT/etc" \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null | wc -l)"
  if (( n > 0 )); then manual "$n .pacnew/.pacsave file(s) in /etc. Merge them with: sudo pacdiff"; fi
  if have pacman && (( ! SANDBOX )); then
    n="$(pacman -Qdtq 2>/dev/null | wc -l)"
    if (( n > 0 )); then manual "$n orphaned package(s): pacman -Qdtq (remove with: sudo pacman -Rns \$(pacman -Qdtq))"; fi
  fi
}

# Add kernel parameters that are not there yet. GRUB is handled; other bootloaders get instructions.
_add_kernel_params() { # _add_kernel_params <params>
  local params="$1" missing="" p grub="$ROOT/etc/default/grub"
  if [[ -f "$grub" ]]; then
    for p in $params; do
      grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub" | grep -qF "${p%%=*}" || missing+=" $p"
    done
    missing="${missing# }"
    if [[ -z "$missing" ]]; then info "GRUB already has these parameters"; return 0; fi
    info "adding to GRUB_CMDLINE_LINUX_DEFAULT: $missing"
    if (( ! DRY_RUN )); then
      backup_file /etc/default/grub
      sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=[\"'][^\"']*)|\1 ${missing}|" "$grub"
    fi
    if have grub-mkconfig; then run grub-mkconfig -o /boot/grub/grub.cfg; fi
  elif [[ -f "$ROOT/etc/default/limine" ]]; then
    warn "Limine detected. Not editing it automatically"
    manual "Limine: add to KERNEL_CMDLINE in /etc/default/limine, then run limine-update: $params"
    return 0
  elif [[ -f "$ROOT/etc/kernel/cmdline" ]]; then
    warn "systemd-boot style /etc/kernel/cmdline detected. Not editing it automatically"
    manual "Append to /etc/kernel/cmdline, then regenerate your boot entries: $params"
    return 0
  else
    warn "could not tell which bootloader is used"
    manual "Add to the kernel command line: $params"
    return 0
  fi
  manual "Reboot to apply the new kernel command line"
}

mod_boot_params() {
  step "Kernel command line hardening"
  _add_kernel_params "$KERNEL_PARAMS"
  manual "debugfs=off hides /sys/kernel/debug from debuggers and some GPU tools. Remove it from the command line if something needs it"
}

mod_apparmor() {
  step "AppArmor"
  pkg_install apparmor
  svc_enable apparmor
  _add_kernel_params "$APPARMOR_PARAMS"
  manual "After the reboot check: sudo aa-enabled && sudo aa-status. Extra profile sets such as apparmor.d may ship in complain mode, which protects nothing. Check that profiles are enforcing before relying on them"
}

mod_audit_tools() {
  step "Audit tools"
  pkg_install lynis arch-audit
  if (( ! DRY_RUN && ! SANDBOX )); then
    local n
    n="$(arch-audit --upgradable 2>/dev/null | wc -l)"
    if (( n > 0 )); then manual "$n installed package(s) have known vulnerabilities with a fix available: arch-audit --upgradable (a full update usually fixes it)"; fi
  fi
  manual "Audit later with: sudo lynis audit system"
}

distro_report() {
  if (( ! SANDBOX )) && [[ ! -d "/usr/lib/modules/$(uname -r)" ]]; then
    manual "Reboot: the installed kernel no longer matches the running one"
  fi
  if have snapper || have timeshift; then :; else
    manual "No snapshot tool found. On Btrfs, snapper with snap-pac gives you a rollback after a bad update"
  fi
}

pi_main "$@"
