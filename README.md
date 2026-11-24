# post-install

Hardening and start scripts for a fresh install of **Debian 12/13** and **CachyOS**. Each one updates the
system and then applies the settings that are worth having on any machine, without turning a
desktop or laptop into something you can't use.

```bash
git clone https://github.com/MMoermans/post-install.git && cd post-install
sudo ./post-install.sh --dry-run     # preview: shows every command and file, changes nothing
sudo ./post-install.sh               # apply
```

`post-install.sh` picks `debian/post-install.sh` or `cachyos/post-install.sh` from `/etc/os-release`.
You can also run those directly. Read the scripts first; they are short, and you are running them as root.

## How it behaves

- **Dry run first.** `--dry-run` works without root and prints every command and every file it would write.
- **No lock-outs.** SSH password logins are only switched off when your user already has a key in
  `authorized_keys`. Firewall rules for SSH go in *before* the firewall is enabled. The new `sshd`
  configuration is validated with `sshd -t` and rolled back if it is rejected.
- **Backups.** Every file that is replaced is first copied to `/var/backups/post-install/<timestamp>/`.
- **Safe to rerun.** Files are only rewritten when their content changes.
- **Modules.** Every step is a module. `--list` shows them, `--with a,b` adds opt-in ones,
  `--without a,b` skips default ones, and `--only a,b` runs exactly those.
- **One failing module does not stop the rest.** The summary lists what failed and what is still up to you.
- Log: `/var/log/post-install.log`.

```bash
sudo ./debian/post-install.sh --list
sudo ./debian/post-install.sh --with ssh,aide --without passwords
sudo ./cachyos/post-install.sh --with apparmor,boot_params
```

## What it does

Modules marked **opt-in** only run with `--with`.

| Module | Debian | CachyOS | What it does |
|---|:-:|:-:|---|
| `updates` | on | on | Full system upgrade (and Flatpak). On CachyOS always `pacman -Syu`, never a partial upgrade |
| `firewall` | on | on | `ufw`: deny incoming, allow outgoing, rate-limited SSH rule when an SSH server is running. Skipped if `firewalld` is active |
| `sysctl` | on | on | Hide kernel pointers, restrict `dmesg`, `ptrace` and unprivileged BPF, disable `kexec`, protect hard/symlinks and FIFOs, no ICMP redirects or source routing, SYN-flood protection. CachyOS performance tuning is left alone |
| `kernel_modules` | on | on | Block DCCP, SCTP, RDS, TIPC, AX.25, NetRom, Rose, cramfs, freevxfs, jffs2, hfs and FireWire |
| `coredumps` | on | on | No core dumps; they can contain passwords and keys |
| `journald` | on | on | Persistent journal, so logs survive a reboot |
| `sudo` | on | on | `use_pty`, 5 minute timeout, no visible passwords. Validated with `visudo` before it is installed |
| `auditd` | on | on | Audit daemon with rules for accounts, sudo, PAM, SSH config, cron and kernel module loading |
| `fail2ban` | on | on | SSH jail that reads the **journal**, with incremental ban times. Only when an SSH server exists |
| `apparmor` | on | opt-in | Debian: install profiles and start the service. CachyOS: install and add the `lsm=` kernel parameter |
| `auto_updates` | on | n/a | `unattended-upgrades` for security updates, never reboots by itself |
| `passwords` | on | n/a | `libpam-pwquality`: 12+ characters, dictionary and username checks |
| `maintenance` | n/a | on | `paccache.timer` and `fstrim.timer` |
| `pacman_checks` | n/a | on | Warns about a weakened `SigLevel`, unmerged `.pacnew` files and orphaned packages |
| `audit_tools` | on | on | `lynis` plus `debsums` (Debian) or `arch-audit` (CachyOS), and a list of vulnerable packages on CachyOS |
| `ssh` | opt-in | opt-in | Installs the OpenSSH server with root login off, key-only logins (when a key exists), post-quantum key exchange where supported, modern ciphers and MACs, `LogLevel VERBOSE` |
| `boot_params` | opt-in | opt-in | Kernel command line: `slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none debugfs=off` |
| `aide` | opt-in | n/a | File integrity database. The first run takes minutes and AIDE mails a daily report |
| `openscap` | opt-in | n/a | OpenSCAP scanner and Debian security guide content where packaged |
| `mirrors` | n/a | opt-in | `cachyos-rate-mirrors` |

After the modules run, a report shows Secure Boot and disk encryption state, firewall and AppArmor
status, everything listening on the network and failed services. Anything that needs a person is
repeated under **Still up to you**.

## What this script cannot do for you

- **Disk encryption** has to be chosen at install time. The report tells you if none was found.
- **Secure Boot, a firmware password and the boot order** are set in the firmware.
- **Backups.** Hardening does not help against a dead disk. On Btrfs, `snapper` with `snap-pac` gives you a rollback after a bad update.
- **SSH keys.** Put one on the machine (`ssh-copy-id`), then rerun with `--with ssh` to turn passwords off.
- **The `root` password.** Once sudo works for your user: `sudo passwd -l root`.

## Things worth knowing

- **Debian 13 has no `/var/log/auth.log`** unless `rsyslog` is installed. The old script's fail2ban
  config pointed at that file, so the jail would fail to start or watch nothing. The new one uses the journal.
- **The old script wrote SSH settings at the end of `sshd_config`.** `sshd` uses the first value it
  sees and Debian includes `sshd_config.d` at the top, so those lines could be ignored. The new
  settings go in `/etc/ssh/sshd_config.d/10-hardening.conf`, which wins. The old `PermitEmptyPasswords`
  line was also missing a redirect, and the `unattended-upgrades` block was commented out.
- **Docker publishes ports around `ufw`.** A container started with `-p 8080:80` is reachable even
  if `ufw` denies it. Bind to `127.0.0.1` (`-p 127.0.0.1:8080:80`) or manage rules in `DOCKER-USER`.
- **`rp_filter` is set to loose (2)**, not strict, so VPNs and multi-homed setups keep working.
- **User namespaces stay enabled.** Flatpak, browsers and Steam need them.
- **`debugfs=off`** (opt-in `boot_params`) hides `/sys/kernel/debug` from some debuggers and GPU tools.
- **CachyOS and AppArmor:** a forum report says the `apparmor.d` profile set ships in complain mode,
  which protects nothing. Check that `sudo aa-status` shows enforcing profiles before you rely on it. The script edits GRUB for you;
  for Limine and systemd-boot it prints the exact parameters to add instead.
- **CachyOS has no unattended upgrades on purpose.** Arch-based systems should be upgraded fully and
  deliberately, not in the background.

## Undo

Each module writes only files it names itself. Remove the file and reload the service:

| Remove | Then |
|---|---|
| `/etc/sysctl.d/99-post-install-hardening.conf` | `sysctl --system` (full effect after a reboot) |
| `/etc/modprobe.d/99-post-install-blacklist.conf` | nothing |
| `/etc/systemd/coredump.conf.d/10-post-install.conf`, `/etc/security/limits.d/10-post-install-nocore.conf` | nothing |
| `/etc/systemd/journald.conf.d/10-post-install.conf` | `systemctl restart systemd-journald` |
| `/etc/sudoers.d/90-post-install` | nothing |
| `/etc/audit/rules.d/50-post-install.rules` | `augenrules --load` |
| `/etc/ssh/sshd_config.d/10-hardening.conf` | `systemctl reload ssh` (`sshd` on CachyOS) |
| `/etc/fail2ban/jail.d/10-post-install.conf` | `systemctl restart fail2ban` |
| `/etc/apt/apt.conf.d/20auto-upgrades`, `52post-install-unattended` (Debian) | nothing |
| `/etc/security/pwquality.conf.d/10-post-install.conf` (Debian) | nothing |
| `/etc/default/grub.d/90-post-install-hardening.cfg` (Debian) | `update-grub` |
| `/etc/default/grub` edits (CachyOS) | restore from `/var/backups/post-install/`, then `grub-mkconfig -o /boot/grub/grub.cfg` |
| firewall | `ufw disable` |

## Development

```bash
tests/sandbox.sh debian      # or: cachyos
```

The sandbox test runs the real modules against a throwaway root directory (`PI_ROOT`). Files are
written for real, but `apt`, `pacman`, `systemctl` and `ufw` are only printed, so it is safe on any
machine. It checks the generated files, idempotence, backups, the SSH key logic, the GRUB editing
and option handling. CI runs it inside `debian:trixie`, `debian:bookworm` and `archlinux`
containers, plus `shellcheck`.

The scripts have been previewed with `--dry-run` and run in the sandbox, but they cannot be fully
exercised without a real machine and a reboot. Try them on a fresh install or a VM first.

## Sources

- [CachyOS wiki: post install](https://wiki.cachyos.org/configuration/post_install_setup/) (ufw, AppArmor)
- [Debian's fail2ban 1.1.0-8 patch](https://sources.debian.org/src/fail2ban/1.1.0-8/debian/patches/update_backend_system.diff) (systemd backend instead of auth.log)
- [ssh-audit](https://github.com/jtesta/ssh-audit): Debian 13 hardening policy and ML-KEM key exchange
- [OpenSSH 10.0 release notes](https://www.openssh.com/txt/release-10.0)
- [Kernel Self Protection Project: recommended settings](https://kspp.github.io/Recommended_Settings)
