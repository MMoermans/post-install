#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for the Debian and CachyOS post-install scripts. Sourced, not executed.
#
# A distro script defines:
#   ALL_MODULES (run order), DEFAULT_ON, MODULE_DESC[name], mod_<name> functions,
#   pkg_install, check_distro, SYSCTL_EXTRA, SSH_PKG, SSH_SERVICE, AUDIT_PKGS, FAIL2BAN_PKGS
# and finishes with:  pi_main "$@"

PI_VERSION="2.0.0"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

DRY_RUN=0
FORCE=0
HELP=0
LIST=0
ONLY=""
WITH=""
WITHOUT=""
ROOT="${PI_ROOT:-}"        # test sandbox: files are written below this directory, commands are only printed
SANDBOX=0
[[ -n "$ROOT" ]] && SANDBOX=1
LOG_FILE="${PI_LOG:-/var/log/post-install.log}"
BACKUP_DIR="${ROOT}/var/backups/post-install/$(date +%Y%m%d-%H%M%S)-$$"
WROTE=0                    # set by write_file: 1 when the file changed
STATE_DIR=""
SELECTED=()

if [[ -t 2 ]]; then
  C_B=$'\e[1m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_0=$'\e[0m'
else
  C_B=""; C_R=""; C_Y=""; C_0=""
fi

# --------------------------------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------------------------------
_log() { if (( ! DRY_RUN && ! SANDBOX )) && [[ -n "$LOG_FILE" ]]; then printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; fi; }
info() { printf '  %s\n' "$*" >&2; _log "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0" >&2; _log "==> $*"; }
warn() { printf '  %sWARNING:%s %s\n' "$C_Y" "$C_0" "$*" >&2; _log "WARNING: $*"; [[ -n "$STATE_DIR" ]] && printf '%s\n' "$*" >>"$STATE_DIR/warnings"; return 0; }
die()  { printf '%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
# Something the script cannot or should not do for you; repeated in the summary.
manual() { [[ -n "$STATE_DIR" ]] && printf '%s\n' "$*" >>"$STATE_DIR/manual"; return 0; }

have() { command -v "$1" >/dev/null 2>&1; }

in_list() { # in_list <needle> <items...>
  local n="$1" i; shift
  for i in "$@"; do [[ "$i" == "$n" ]] && return 0; done
  return 1
}

# Run a command (output also goes to the log). In dry-run and sandbox mode it is only printed.
run() {
  if (( DRY_RUN || SANDBOX )); then info "[dry-run] $*"; return 0; fi
  _log "+ $*"
  if [[ -n "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]]; then "$@" 2>&1 | tee -a "$LOG_FILE"; else "$@"; fi
}

svc_enable() { run systemctl enable --now "$@"; }

# --------------------------------------------------------------------------------------------------
# Files
# --------------------------------------------------------------------------------------------------
backup_file() { # backup_file </absolute/path>
  local src="$ROOT$1"
  [[ -e "$src" ]] || return 0
  (( DRY_RUN )) && return 0
  # Keep the first copy: if two modules edit one file, the backup must be the true original.
  [[ -e "$BACKUP_DIR$1" ]] && return 0
  mkdir -p "$BACKUP_DIR$(dirname "$1")"
  cp -a "$src" "$BACKUP_DIR$1"
}

# Write stdin to a file if the content changed. Existing files are backed up first.
# Sets WROTE=1 when the file was created or changed. Usage: write_file /etc/x 0644 <<'EOF' ... EOF
write_file() {
  local path="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  WROTE=0
  if [[ -f "$ROOT$path" ]] && [[ "$(sha256sum <"$tmp")" == "$(sha256sum <"$ROOT$path")" ]]; then
    rm -f "$tmp"; info "unchanged: $path"; return 0
  fi
  WROTE=1
  if (( DRY_RUN )); then rm -f "$tmp"; info "[dry-run] would write $path"; return 0; fi
  backup_file "$path"
  mkdir -p "$(dirname "$ROOT$path")"
  if (( SANDBOX )); then install -m "$mode" "$tmp" "$ROOT$path"; else install -m "$mode" -o root -g root "$tmp" "$path"; fi
  rm -f "$tmp"
  info "wrote $path"
  _log "wrote $path"
}

# --------------------------------------------------------------------------------------------------
# Argument handling and module selection
# --------------------------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: ${PI_PROG:-post-install.sh} [options]

Options:
  -n, --dry-run        show what would change, change nothing (works without root)
      --with a,b       also run opt-in modules (see --list)
      --without a,b    skip modules that are on by default
      --only a,b       run exactly these modules
      --list           list modules and whether they run by default
      --force          continue on an unsupported distro or release
  -h, --help           this help
  -V, --version        print the version

Every file that is replaced is first copied to ${BACKUP_DIR%/*}/<timestamp>/.
The log is written to ${LOG_FILE}.
EOF
}

_need_value() { [[ $# -ge 2 && -n "$2" ]] || die "option $1 needs a value"; }

parse_args() {
  while (( $# )); do
    case "$1" in
      -n|--dry-run) DRY_RUN=1 ;;
      # shellcheck disable=SC2034  # FORCE is read by the distro scripts
      --force) FORCE=1 ;;
      --list) LIST=1 ;;
      -h|--help) HELP=1 ;;
      -V|--version) echo "post-install ${PI_VERSION}"; exit 0 ;;
      --only)    _need_value "$@"; ONLY="$2"; shift ;;
      --only=*)  ONLY="${1#*=}" ;;
      --with)    _need_value "$@"; WITH="$2"; shift ;;
      --with=*)  WITH="${1#*=}" ;;
      --without) _need_value "$@"; WITHOUT="$2"; shift ;;
      --without=*) WITHOUT="${1#*=}" ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
}

_split() { local IFS=,; read -r -a "$2" <<<"$1"; }

_validate_names() { # _validate_names <option> <comma list>
  local m names=()
  [[ -n "$2" ]] || return 0
  _split "$2" names
  for m in "${names[@]}"; do
    in_list "$m" "${ALL_MODULES[@]}" || die "unknown module '$m' in $1 (see --list)"
  done
}

select_modules() {
  local m with=() without=() only=()
  _validate_names --only "$ONLY"; _validate_names --with "$WITH"; _validate_names --without "$WITHOUT"
  _split "$WITH" with; _split "$WITHOUT" without; _split "$ONLY" only
  SELECTED=()
  for m in "${ALL_MODULES[@]}"; do
    if [[ -n "$ONLY" ]]; then
      in_list "$m" "${only[@]}" && SELECTED+=("$m")
      continue
    fi
    if in_list "$m" "${DEFAULT_ON[@]}" || in_list "$m" "${with[@]}"; then
      in_list "$m" "${without[@]}" || SELECTED+=("$m")
    fi
  done
}

list_modules() {
  local m flag
  printf '%-16s %-8s %s\n' MODULE DEFAULT DESCRIPTION
  for m in "${ALL_MODULES[@]}"; do
    if in_list "$m" "${DEFAULT_ON[@]}"; then flag=on; else flag="opt-in"; fi
    printf '%-16s %-8s %s\n' "$m" "$flag" "${MODULE_DESC[$m]:-}"
  done
}

# --------------------------------------------------------------------------------------------------
# Modules shared by both distros
# --------------------------------------------------------------------------------------------------
mod_sysctl() {
  step "Kernel and network hardening (sysctl)"
  local content
  content="$(cat <<'EOF'
# Managed by post-install. Remove this file and run `sysctl --system` to undo.

# --- Kernel: hide addresses, restrict debugging interfaces ---
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.kexec_load_disabled = 1
kernel.randomize_va_space = 2
dev.tty.ldisc_autoload = 0
vm.mmap_min_addr = 65536
vm.unprivileged_userfaultfd = 0

# --- Filesystem: protect against link, FIFO and setuid-dump tricks ---
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0

# --- Network: no redirects or source routing, SYN-flood and spoofing protection ---
# rp_filter 2 (loose) keeps VPNs and multi-homed setups working.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
EOF
)"
  if (( ${#SYSCTL_EXTRA[@]} )); then
    content+=$'\n\n# --- Distribution specific ---\n'"$(printf '%s\n' "${SYSCTL_EXTRA[@]}")"
  fi
  write_file /etc/sysctl.d/99-post-install-hardening.conf 0644 <<<"$content"
  if (( WROTE )); then run sysctl --system >/dev/null || warn "sysctl reported errors; some keys may not exist on this kernel"; fi
}

mod_kernel_modules() {
  step "Disable rarely used kernel modules"
  write_file /etc/modprobe.d/99-post-install-blacklist.conf 0644 <<'EOF'
# Managed by post-install. Remove this file to allow these modules again.
# Rare network protocols that have had local privilege escalation bugs
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
install ax25 /bin/false
install netrom /bin/false
install rose /bin/false
# Rare filesystems that nobody mounts by accident
install cramfs /bin/false
install freevxfs /bin/false
install jffs2 /bin/false
install hfs /bin/false
# FireWire allows DMA from attached devices
install firewire-core /bin/false
EOF
}

mod_coredumps() {
  step "Disable core dumps"
  write_file /etc/systemd/coredump.conf.d/10-post-install.conf 0644 <<'EOF'
# Managed by post-install. A crashing program can leave passwords and keys in a core file.
# Remove this file to get core dumps back for debugging.
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
  write_file /etc/security/limits.d/10-post-install-nocore.conf 0644 <<'EOF'
# Managed by post-install
*  hard  core  0
EOF
}

mod_journald() {
  step "Keep the journal across reboots"
  write_file /etc/systemd/journald.conf.d/10-post-install.conf 0644 <<'EOF'
# Managed by post-install. Logs that vanish at reboot are useless after an incident.
[Journal]
Storage=persistent
SystemMaxUse=1G
Compress=yes
ForwardToSyslog=no
EOF
  if (( WROTE )); then run systemctl restart systemd-journald; fi
}

mod_sudo() {
  step "sudo defaults"
  local content tmp
  content="$(cat <<'EOF'
# Managed by post-install
Defaults use_pty
Defaults !visiblepw
Defaults passwd_tries=3
Defaults timestamp_timeout=5
EOF
)"
  if have visudo; then
    tmp="$(mktemp)"; printf '%s\n' "$content" >"$tmp"
    if ! visudo -cqf "$tmp"; then rm -f "$tmp"; die "generated sudoers file did not validate; not installing it"; fi
    rm -f "$tmp"
  fi
  write_file /etc/sudoers.d/90-post-install 0440 <<<"$content"
}

mod_auditd() {
  step "Audit daemon with rules for identity, sudo, ssh and module changes"
  # shellcheck disable=SC2086  # AUDIT_PKGS is a space separated package list
  pkg_install $AUDIT_PKGS
  write_file /etc/audit/rules.d/50-post-install.rules 0640 <<'EOF'
# Managed by post-install
## Accounts and authentication
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/pam.d/ -p wa -k pam
-w /etc/security/ -p wa -k pam
## SSH server configuration
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
## Scheduled jobs (a common persistence spot)
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
-w /var/spool/cron/ -p wa -k cron
## Kernel modules and the clock
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules
-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time-change
EOF
  svc_enable auditd
  if (( WROTE )); then run augenrules --load || warn "could not load audit rules now; they apply at next boot"; fi
}

mod_firewall() {
  step "Firewall (ufw): deny incoming, allow outgoing"
  if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "firewalld is active; leaving the firewall alone to avoid two firewalls fighting"
    return 0
  fi
  local ports=() p
  mapfile -t ports < <(ssh_ports)
  if (( ${#ports[@]} == 0 )) && in_list ssh "${SELECTED[@]}"; then ports=(22); fi
  pkg_install ufw
  run ufw default deny incoming
  run ufw default allow outgoing
  # Rules go in before enabling, so an SSH session survives the switch. "limit" rate-limits brute force.
  for p in "${ports[@]}"; do
    [[ -n "$p" ]] && run ufw limit "$p/tcp" comment 'SSH'
  done
  run ufw logging low
  run ufw --force enable
  run systemctl enable ufw
  if (( ${#ports[@]} == 0 )); then info "no SSH server found, so no inbound rule was added"; fi
}

# Ports that sshd listens on, plus the one this session came in on.
ssh_ports() {
  {
    ss -Hltnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }'
    if [[ -n "${SSH_CONNECTION:-}" ]]; then awk '{ print $4 }' <<<"$SSH_CONNECTION"; fi
  } | sort -un
}

user_has_ssh_key() {
  local u="${SUDO_USER:-}" home
  [[ -n "$u" && "$u" != root ]] || return 1
  home="$(getent passwd "$u" | cut -d: -f6)"
  [[ -n "$home" ]] || return 1
  [[ -s "$ROOT$home/.ssh/authorized_keys" ]]
}

# Keep only the preferred algorithms this OpenSSH build supports, in preference order.
_supported() { # _supported <kex|cipher|mac> <preferred...>
  local type="$1" a have_list out=()
  shift
  have ssh || return 0
  have_list="$(ssh -Q "$type" 2>/dev/null)" || return 0
  for a in "$@"; do grep -qxF "$a" <<<"$have_list" && out+=("$a"); done
  (IFS=,; printf '%s' "${out[*]}")
}

mod_ssh() {
  step "OpenSSH server with hardened settings"
  pkg_install "$SSH_PKG"
  local cfg="$ROOT/etc/ssh/sshd_config" target=/etc/ssh/sshd_config.d/10-hardening.conf
  local pw=yes kex ciphers macs prev="" content

  # The first value wins in sshd_config, so the drop-in must be included before anything else.
  if [[ -f "$cfg" ]] && ! grep -Eqi '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$cfg"; then
    info "adding the sshd_config.d Include at the top of sshd_config"
    if (( ! DRY_RUN )); then backup_file /etc/ssh/sshd_config; sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$cfg"; fi
  fi

  if user_has_ssh_key; then
    pw=no
  else
    warn "no SSH key found for '${SUDO_USER:-root}', so password logins stay enabled to avoid locking you out"
    manual "Add an SSH key (ssh-copy-id) for your user, then rerun with --with ssh to turn password logins off"
  fi

  kex="$(_supported kex mlkem768x25519-sha256 sntrup761x25519-sha512 sntrup761x25519-sha512@openssh.com curve25519-sha256 curve25519-sha256@libssh.org)"
  ciphers="$(_supported cipher chacha20-poly1305@openssh.com aes256-gcm@openssh.com aes128-gcm@openssh.com)"
  macs="$(_supported mac hmac-sha2-512-etm@openssh.com hmac-sha2-256-etm@openssh.com)"

  content="# Managed by post-install. Remove this file and reload sshd to undo.
PermitRootLogin no
PasswordAuthentication ${pw}
KbdInteractiveAuthentication ${pw}
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:60
X11Forwarding no
AllowAgentForwarding no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE"
  [[ "$pw" == no ]] && content+=$'\nAuthenticationMethods publickey'
  [[ -n "$kex" ]] && content+=$'\n'"KexAlgorithms ${kex}"
  [[ -n "$ciphers" ]] && content+=$'\n'"Ciphers ${ciphers}"
  [[ -n "$macs" ]] && content+=$'\n'"MACs ${macs}"

  if [[ -f "$ROOT$target" ]]; then prev="$(mktemp)"; cp -a "$ROOT$target" "$prev"; fi
  write_file "$target" 0644 <<<"$content"

  if (( WROTE && ! DRY_RUN && ! SANDBOX )); then
    install -d -m 0755 /run/sshd
    if ! "$(command -v sshd || echo /usr/sbin/sshd)" -t; then
      if [[ -n "$prev" ]]; then cp -a "$prev" "$target"; else rm -f "$target"; fi
      rm -f "$prev"
      die "sshd rejected the new configuration; it was rolled back"
    fi
  fi
  rm -f "$prev"
  svc_enable "$SSH_SERVICE"
  if (( WROTE )); then run systemctl reload "$SSH_SERVICE"; fi
  if [[ "$pw" == no ]]; then info "SSH: root login off, keys only, modern algorithms only"; else info "SSH: root login off, password logins still on (no key yet), modern algorithms only"; fi
}

mod_fail2ban() {
  step "fail2ban for SSH (reads the systemd journal)"
  if ! have sshd && ! in_list ssh "${SELECTED[@]}" && (( ! SANDBOX )); then
    info "no SSH server installed; fail2ban would have nothing to protect. Skipping."
    return 0
  fi
  # shellcheck disable=SC2086
  pkg_install $FAIL2BAN_PKGS
  local ports port
  mapfile -t ports < <(ssh_ports)
  port="$(IFS=,; echo "${ports[*]:-ssh}")"
  [[ -n "$port" ]] || port=ssh
  write_file /etc/fail2ban/jail.d/10-post-install.conf 0644 <<EOF
# Managed by post-install. The journal is used because there is no /var/log/auth.log
# unless rsyslog is installed.
[DEFAULT]
backend = systemd
banaction = nftables
bantime = 1h
findtime = 10m
maxretry = 4
bantime.increment = true
bantime.maxtime = 1w

[sshd]
enabled = true
port = ${port}
mode = aggressive
EOF
  svc_enable fail2ban
  if (( WROTE )); then run systemctl restart fail2ban; fi
}

# --------------------------------------------------------------------------------------------------
# Report: what the script cannot fix, and the state of the machine afterwards
# --------------------------------------------------------------------------------------------------
pi_report() {
  step "Security posture"
  local line

  if [[ -d /sys/firmware/efi ]]; then
    if have mokutil; then line="$(mokutil --sb-state 2>/dev/null | head -1)"
    elif have bootctl; then line="$(bootctl status 2>/dev/null | grep -i 'secure boot' | head -1 | sed 's/^ *//')"
    else line="UEFI system, Secure Boot state unknown (install mokutil or sbctl to check)"; fi
    info "Secure Boot: ${line:-unknown}"
    if [[ "${line,,}" == *disabled* ]]; then manual "Secure Boot is disabled; enable it in the firmware setup if your setup supports it"; fi
  else
    info "Secure Boot: not a UEFI system"
  fi

  if lsblk -rno TYPE 2>/dev/null | grep -q '^crypt$'; then
    info "Disk encryption: LUKS volume present"
  else
    info "Disk encryption: none detected"
    manual "Disk encryption can only be set up at install time. Without it, a stolen laptop is an open book"
  fi

  if have ufw; then info "Firewall: $(ufw status 2>/dev/null | head -1)"; elif have firewall-cmd; then info "Firewall: firewalld $(firewall-cmd --state 2>/dev/null)"; else info "Firewall: none"; fi
  if have aa-status; then
    if aa-status --enabled 2>/dev/null; then info "AppArmor: enabled"; else info "AppArmor: not enabled"; fi
  fi
  if [[ "$(passwd -S root 2>/dev/null | awk '{print $2}')" == P ]]; then
    manual "root has a password set. Once sudo works for your user: sudo passwd -l root"
  fi
  info "Listening on the network:"
  ss -Htulpn 2>/dev/null | awk '{ printf "    %-5s %-28s %s\n", $1, $5, $7 }' >&2 || true
  line="$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
  if (( line > 0 )); then warn "$line systemd unit(s) failed: systemctl --failed"; fi
  if declare -F distro_report >/dev/null; then distro_report; fi
}

# --------------------------------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------------------------------
run_module() {
  local m="$1" rc
  ( set -e; "mod_$m" )
  rc=$?
  if (( rc == 0 )); then
    echo "$m" >>"$STATE_DIR/ok"
  else
    echo "$m" >>"$STATE_DIR/failed"
    warn "module '$m' failed (exit $rc); continuing with the rest"
  fi
}

_print_list() { # _print_list <file> <prefix>
  [[ -s "$1" ]] && sed "s/^/  $2 /" "$1" >&2
  return 0
}

pi_main() {
  parse_args "$@"
  if (( HELP )); then usage; exit 0; fi
  if (( LIST )); then list_modules; exit 0; fi
  select_modules
  (( ${#SELECTED[@]} )) || die "no modules selected"

  if (( ! DRY_RUN && ! SANDBOX )) && [[ "${EUID}" -ne 0 ]]; then
    die "must run as root (use sudo), or add --dry-run to preview"
  fi
  check_distro

  STATE_DIR="$(mktemp -d)"
  trap 'rm -rf "$STATE_DIR"' EXIT
  if (( ! DRY_RUN && ! SANDBOX )); then ( umask 077; : >>"$LOG_FILE" ) 2>/dev/null || true; fi

  (( DRY_RUN )) && info "DRY RUN: nothing will be changed"
  info "modules: ${SELECTED[*]}"

  local m
  for m in "${SELECTED[@]}"; do run_module "$m"; done
  pi_report

  step "Summary"
  [[ -s "$STATE_DIR/ok" ]] && info "done:   $(paste -sd' ' "$STATE_DIR/ok")"
  if [[ -s "$STATE_DIR/failed" ]]; then
    printf '  %sfailed: %s%s\n' "$C_R" "$(paste -sd' ' "$STATE_DIR/failed")" "$C_0" >&2
  fi
  if [[ -s "$STATE_DIR/manual" ]]; then
    printf '\n%sStill up to you:%s\n' "$C_B" "$C_0" >&2
    sort -u "$STATE_DIR/manual" | sed 's/^/  - /' >&2
  fi
  if (( ! DRY_RUN && ! SANDBOX )) && [[ -d "$BACKUP_DIR" ]]; then info "backups of replaced files: $BACKUP_DIR"; fi
  if (( ! DRY_RUN && ! SANDBOX )); then info "log: $LOG_FILE"; fi
  [[ ! -s "$STATE_DIR/failed" ]]
}
