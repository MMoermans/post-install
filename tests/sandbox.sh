#!/usr/bin/env bash
# Runs the file-writing modules against a throwaway root (PI_ROOT) and checks the results.
# Commands such as apt, systemctl and ufw are only printed in sandbox mode, so this is safe anywhere.
# Usage: tests/sandbox.sh debian|cachyos
set -uo pipefail
distro="${1:?usage: $0 debian|cachyos}"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/$distro/post-install.sh"
fails=0

check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok    $desc"; else echo "FAIL  $desc"; fails=$((fails + 1)); fi
}
newroot() { rm -rf "$root"; root="$(mktemp -d)"; export PI_ROOT="$root" PI_LOG="$root/log"; }
pi() { bash "$script" --force "$@" >"$root/out" 2>&1; }

root=""
trap 'rm -rf "$root"' EXIT

# --- default file-writing modules -------------------------------------------------------------
newroot
pi --only sysctl,kernel_modules,coredumps,journald,sudo,auditd
check "exit status 0" test $? -eq 0
check "sysctl file written"          grep -q '^kernel.kptr_restrict = 2' "$root/etc/sysctl.d/99-post-install-hardening.conf"
check "sysctl has distro extra key"  grep -q '^kernel.perf_event_paranoid' "$root/etc/sysctl.d/99-post-install-hardening.conf"
check "modules blacklist written"    grep -q '^install dccp /bin/false' "$root/etc/modprobe.d/99-post-install-blacklist.conf"
check "core dumps disabled"          grep -q '^Storage=none' "$root/etc/systemd/coredump.conf.d/10-post-install.conf"
check "journal persistent"           grep -q '^Storage=persistent' "$root/etc/systemd/journald.conf.d/10-post-install.conf"
check "sudoers use_pty"              grep -q '^Defaults use_pty' "$root/etc/sudoers.d/90-post-install"
check "sudoers mode 0440"            test "$(stat -c %a "$root/etc/sudoers.d/90-post-install")" = 440
check "audit rules written"          grep -q -- '-k sudoers' "$root/etc/audit/rules.d/50-post-install.rules"

# --- idempotent: a second run changes nothing ---------------------------------------------------
pi --only sysctl,kernel_modules,coredumps,journald,sudo,auditd
after="$(find "$root" -type f ! -name log ! -name out -exec md5sum {} + | grep -v '/var/backups/' | sort | md5sum)"
check "second run reports unchanged" grep -q 'unchanged: /etc/sysctl.d' "$root/out"
check "second run leaves files identical" test "$(find "$root" -type f ! -name log ! -name out ! -path '*/var/backups/*' -exec md5sum {} + | sort | md5sum)" = "$after"

# --- changed content is backed up -------------------------------------------------------------
echo "# tampered" >"$root/etc/sysctl.d/99-post-install-hardening.conf"
pi --only sysctl
check "tampered file is replaced"    grep -q '^kernel.kptr_restrict = 2' "$root/etc/sysctl.d/99-post-install-hardening.conf"
check "tampered file was backed up"  grep -rq '# tampered' "$root/var/backups/post-install"

# --- ssh: no key keeps password logins; a key turns them off ----------------------------------
newroot
mkdir -p "$root/etc/ssh"; printf 'Port 22\nUsePAM yes\n' >"$root/etc/ssh/sshd_config"
SUDO_USER=nobody pi --only ssh
check "Include added to the top of sshd_config" test "$(head -1 "$root/etc/ssh/sshd_config")" = 'Include /etc/ssh/sshd_config.d/*.conf'
check "root login disabled"                    grep -q '^PermitRootLogin no' "$root/etc/ssh/sshd_config.d/10-hardening.conf"
check "no key: password logins stay on"        grep -q '^PasswordAuthentication yes' "$root/etc/ssh/sshd_config.d/10-hardening.conf"
check "no key: warns about it"                 grep -q 'password logins stay enabled' "$root/out"
home="$(getent passwd nobody | cut -d: -f6)"
mkdir -p "$root$home/.ssh"; echo 'ssh-ed25519 AAAA test' >"$root$home/.ssh/authorized_keys"
SUDO_USER=nobody pi --only ssh
check "key present: password logins off"       grep -q '^PasswordAuthentication no' "$root/etc/ssh/sshd_config.d/10-hardening.conf"
check "key present: publickey only"            grep -q '^AuthenticationMethods publickey' "$root/etc/ssh/sshd_config.d/10-hardening.conf"
check "Include is not added twice"             test "$(grep -c '^Include /etc/ssh/sshd_config.d' "$root/etc/ssh/sshd_config")" = 1

# --- fail2ban ---------------------------------------------------------------------------------
newroot
pi --only fail2ban
check "fail2ban uses the journal"              grep -q '^backend = systemd' "$root/etc/fail2ban/jail.d/10-post-install.conf"
check "fail2ban sshd jail enabled"             grep -q '^enabled = true' "$root/etc/fail2ban/jail.d/10-post-install.conf"

# --- kernel command line ----------------------------------------------------------------------
newroot
if [[ "$distro" == cachyos ]]; then
  mkdir -p "$root/etc/default"
  printf 'GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
' >"$root/etc/default/grub"
  pi --only boot_params,apparmor
  check "grub: existing parameters kept"            grep -q '^GRUB_CMDLINE_LINUX_DEFAULT="quiet splash ' "$root/etc/default/grub"
  check "grub: hardening parameters added"          grep -q 'slab_nomerge.*debugfs=off"$' "$root/etc/default/grub"
  check "grub: apparmor lsm parameter added"        grep -q 'lsm=landlock,lockdown,yama,integrity,apparmor,bpf' "$root/etc/default/grub"
  check "grub: other lines untouched"                grep -q '^GRUB_CMDLINE_LINUX=""$' "$root/etc/default/grub"
  check "grub: backup is the true original"          grep -rqx 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' "$root/var/backups/post-install"
  cp "$root/etc/default/grub" "$root/grub.after"
  pi --only boot_params,apparmor
  check "grub: second run does not duplicate"        test "$(sha256sum <"$root/grub.after")" = "$(sha256sum <"$root/etc/default/grub")"
  newroot; mkdir -p "$root/etc/default"; : >"$root/etc/default/limine"
  pi --only boot_params
  check "limine: left alone, instructions given"     grep -q 'Limine' "$root/out"
else
  pi --only boot_params
  check "grub.d drop-in written"                     grep -q 'GRUB_CMDLINE_LINUX_DEFAULT=.*slab_nomerge' "$root/etc/default/grub.d/90-post-install-hardening.cfg"
fi

# --- option handling --------------------------------------------------------------------------
newroot
check "--list works"                           bash "$script" --list
check "unknown module is rejected"             bash -c "! bash '$script' --force --only nonsense"
check "unknown option is rejected"             bash -c "! bash '$script' --nonsense"
check "--dry-run writes nothing"               bash -c "PI_ROOT='$root' bash '$script' --force --dry-run --only sysctl >/dev/null 2>&1 && ! test -e '$root/etc/sysctl.d'"
check "--without drops a default module"       bash -c "! bash '$script' --force --dry-run --without sysctl 2>&1 | grep -q 'modules:.* sysctl'"

if (( fails )); then echo; echo "$fails check(s) failed"; echo "--- last output ---"; tail -20 "$root/out"; exit 1; fi
echo; echo "all checks passed ($distro)"
