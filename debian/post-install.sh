#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables below are read by lib/common.sh
# Post-install hardening for a fresh Debian 12 (bookworm) or 13 (trixie) install.
# Run:  sudo ./debian/post-install.sh --dry-run   (preview)   then   sudo ./debian/post-install.sh
set -uo pipefail

PI_PROG="debian/post-install.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

ALL_MODULES=(updates ssh firewall fail2ban sysctl kernel_modules coredumps journald sudo passwords
             apparmor auditd auto_updates boot_params aide openscap audit_tools)
DEFAULT_ON=(updates firewall fail2ban sysctl kernel_modules coredumps journald sudo passwords
            apparmor auditd auto_updates audit_tools)
declare -A MODULE_DESC=(
  [updates]="apt full-upgrade, flatpak update, autoremove"
  [ssh]="install OpenSSH server: no root login, keys only (if a key exists), modern algorithms, validated and rolled back on error"
  [firewall]="ufw: deny incoming, allow outgoing, rate-limited SSH rule when sshd runs"
  [fail2ban]="ban brute-forcing hosts; uses the journal because trixie has no auth.log (only if sshd exists)"
  [sysctl]="kernel pointer/dmesg/ptrace/bpf restrictions, network spoofing and redirect protection"
  [kernel_modules]="block rare network protocols, filesystems and FireWire"
  [coredumps]="no core dumps (they can contain secrets)"
  [journald]="persistent journal"
  [sudo]="use_pty, 5 minute timeout, no visible passwords"
  [passwords]="libpam-pwquality: 12+ characters, dictionary and username checks"
  [apparmor]="make sure AppArmor and extra profiles are installed and running"
  [auditd]="auditd with rules for accounts, sudo, ssh, cron, modules"
  [auto_updates]="unattended-upgrades for security updates (no automatic reboot)"
  [boot_params]="kernel command line: slab_nomerge, page_alloc.shuffle, randomize_kstack_offset, vsyscall=none, debugfs=off"
  [aide]="file integrity database (slow first run, daily cron mail noise)"
  [openscap]="OpenSCAP scanner and security guide content, if packaged for this release"
  [audit_tools]="lynis and debsums for later audits"
)

AUDIT_PKGS="auditd"
SSH_PKG="openssh-server"
SSH_SERVICE="ssh"
FAIL2BAN_PKGS="fail2ban python3-systemd nftables"
# Debian carries a patch that allows perf_event_paranoid=3
SYSCTL_EXTRA=("kernel.perf_event_paranoid = 3")

pkg_install() { run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }

check_distro() {
  local id="" ver=""
  if [[ -r /etc/os-release ]]; then id="$(. /etc/os-release; echo "${ID:-}")"; ver="$(. /etc/os-release; echo "${VERSION_ID:-}")"; fi
  if [[ "$id" != debian ]]; then
    (( FORCE )) || die "this script is for Debian (found '${id:-unknown}'). Use --force to continue anyway, or cachyos/post-install.sh for CachyOS/Arch"
    warn "not Debian (${id:-unknown}); continuing because of --force"
  elif [[ "$ver" != 12 && "$ver" != 13 ]]; then
    (( FORCE )) || die "tested on Debian 12 and 13, found '${ver:-testing/sid}'. Use --force to continue anyway"
    warn "untested Debian release (${ver:-testing/sid}); continuing because of --force"
  fi
}

mod_updates() {
  step "System updates"
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
  if have flatpak; then run flatpak update -y --noninteractive; fi
  run apt-get -y autoremove --purge
}

mod_passwords() {
  step "Password quality rules"
  pkg_install libpam-pwquality
  write_file /etc/security/pwquality.conf.d/10-post-install.conf 0644 <<'EOF'
# Managed by post-install. Length beats complexity rules.
minlen = 12
dictcheck = 1
usercheck = 1
maxrepeat = 3
retry = 3
EOF
}

mod_apparmor() {
  step "AppArmor"
  pkg_install apparmor apparmor-utils apparmor-profiles apparmor-profiles-extra
  svc_enable apparmor
  if (( ! DRY_RUN && ! SANDBOX )) && ! aa-status --enabled 2>/dev/null; then
    warn "AppArmor is installed but not active in the running kernel"
    manual "Check that the kernel was started with AppArmor enabled (cat /sys/module/apparmor/parameters/enabled)"
  fi
}

mod_auto_updates() {
  step "Automatic security updates"
  pkg_install unattended-upgrades apt-listchanges
  write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
// Managed by post-install
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  # The packaged 50unattended-upgrades already allows only the Debian and Debian-Security origins.
  write_file /etc/apt/apt.conf.d/52post-install-unattended 0644 <<'EOF'
// Managed by post-install
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  svc_enable unattended-upgrades
  manual "Automatic updates never reboot. Reboot when /var/run/reboot-required exists"
}

mod_boot_params() {
  step "Kernel command line hardening"
  local params="slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none debugfs=off"
  if [[ ! -x /usr/sbin/update-grub ]] && (( ! SANDBOX )); then
    warn "GRUB not found. Add these to your bootloader's kernel command line yourself: $params"
    manual "Add to the kernel command line: $params"
    return 0
  fi
  write_file /etc/default/grub.d/90-post-install-hardening.cfg 0644 <<EOF
# Managed by post-install
GRUB_CMDLINE_LINUX_DEFAULT="\${GRUB_CMDLINE_LINUX_DEFAULT:+\$GRUB_CMDLINE_LINUX_DEFAULT }$params"
EOF
  if (( WROTE )); then run update-grub; fi
  manual "Reboot to apply the kernel command line. debugfs=off hides /sys/kernel/debug from debuggers and some GPU tools"
}

mod_aide() {
  step "AIDE file integrity database (this takes several minutes)"
  pkg_install aide aide-common
  if [[ -f "$ROOT/var/lib/aide/aide.db" ]]; then
    info "AIDE database already exists; leaving it. Rebuild it after intended changes: aideinit -y -f"
    return 0
  fi
  run aideinit --yes --force
  run mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
  manual "After upgrades, check the daily AIDE report, then refresh the baseline: sudo aideinit -y -f && sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db"
}

mod_openscap() {
  step "OpenSCAP"
  local p avail=()
  for p in openscap-scanner ssg-debderived ssg-debian; do
    if (( SANDBOX || DRY_RUN )) || apt-cache show "$p" >/dev/null 2>&1; then avail+=("$p"); else info "package $p is not available on this release; skipping it"; fi
  done
  (( ${#avail[@]} )) || { warn "no OpenSCAP packages available"; return 0; }
  pkg_install "${avail[@]}"
  manual "Scan with: oscap info /usr/share/xml/scap/ssg/content/*.xml, then oscap xccdf eval --profile <id> --report report.html <datastream>"
}

mod_audit_tools() {
  step "Audit tools"
  pkg_install lynis debsums
  manual "Audit later with: sudo lynis audit system   and   sudo debsums -s"
}

distro_report() {
  if [[ -e /var/run/reboot-required ]]; then manual "A reboot is needed to finish updates (/var/run/reboot-required exists)"; fi
}

pi_main "$@"
