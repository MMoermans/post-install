#!/usr/bin/env bash
# Picks the right post-install script for this machine and passes all options on.
#   sudo ./post-install.sh --dry-run
set -uo pipefail
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
id=""; like=""
if [[ -r /etc/os-release ]]; then
  id="$(. /etc/os-release; echo "${ID:-}")"; like="$(. /etc/os-release; echo "${ID_LIKE:-}")"
fi
case "$id" in
  cachyos) exec bash "$dir/cachyos/post-install.sh" "$@" ;;
  debian)  exec bash "$dir/debian/post-install.sh" "$@" ;;
esac
case " $like " in
  *" debian "*) echo "'$id' is Debian-based but not Debian. Run debian/post-install.sh --force if you want to try it." >&2 ;;
  *" arch "*)   echo "'$id' is Arch-based but not CachyOS. Run cachyos/post-install.sh --force if you want to try it." >&2 ;;
  *)            echo "Unsupported system '${id:-unknown}'. Supported: Debian 12/13 and CachyOS." >&2 ;;
esac
exit 1
