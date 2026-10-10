#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/env.sh"

status=0
AUTOPILOT=0
CI_MODE=0

# 构建路径真正必需的工具；CI 模式下缺失才算致命。
# 其余（adb/fastboot/mkbootimg/avbtool/b4/zig/qemu-aarch64/git-send-email 等）
# 属于硬件或上游工具，CI 中降级为 warning。
CI_REQUIRED_TOOLS="git dtc make bc bison flex openssl rsync cpio xz python3 losetup kpartx curl clang"

is_ci_required() {
  local cmd="$1"
  local t
  for t in $CI_REQUIRED_TOOLS; do
    [ "$t" = "$cmd" ] && return 0
  done
  return 1
}

usage() {
  cat <<'USAGE'
Usage: check-host-tools.sh [options]

Check host tools and local hotdog workspace prerequisites.

Options:
  --autopilot  Treat the full automated dump/flash/SSH path as required.
  --ci         CI mode: hardware/upstream tools are reported but not fatal.
  -h, --help   Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --autopilot)
      AUTOPILOT=1
      ;;
    --ci)
      CI_MODE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

check_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "%-24s OK   %s\n" "$cmd" "$(command -v "$cmd")"
  elif [ "$CI_MODE" -eq 1 ] && ! is_ci_required "$cmd"; then
    printf "%-24s optional-missing (ci)\n" "$cmd"
  else
    printf "%-24s MISS\n" "$cmd"
    status=1
  fi
}

check_optional() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "%-24s OK   %s\n" "$cmd" "$(command -v "$cmd")"
  else
    printf "%-24s optional-missing\n" "$cmd"
  fi
}

check_readable() {
  local label="$1"
  local path="$2"
  if [ -r "$path" ]; then
    printf "%-24s OK   %s\n" "$label" "$path"
  elif [ "$CI_MODE" -eq 1 ]; then
    printf "%-24s optional-missing (ci) %s\n" "$label" "$path"
  else
    printf "%-24s MISS %s\n" "$label" "$path"
    status=1
  fi
}

check_executable_path() {
  local label="$1"
  local path="$2"
  if [ -x "$path" ]; then
    printf "%-24s OK   %s\n" "$label" "$path"
  elif [ "$CI_MODE" -eq 1 ]; then
    printf "%-24s optional-missing (ci) %s\n" "$label" "$path"
  else
    printf "%-24s MISS %s\n" "$label" "$path"
    status=1
  fi
}

check_sha256_file() {
  local label="$1"
  local dir="$2"

  if [ ! -s "$dir/SHA256SUMS" ]; then
    printf "%-24s MISS %s\n" "$label" "$dir/SHA256SUMS"
    status=1
    return 0
  fi

  if ( cd "$dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
    printf "%-24s OK   %s\n" "$label" "$dir/SHA256SUMS"
  else
    printf "%-24s FAIL %s\n" "$label" "$dir/SHA256SUMS"
    status=1
  fi
}

check_git_send_email() {
  if [ -x /usr/libexec/git-core/git-send-email ]; then
    printf "%-24s OK   %s\n" "git send-email" "/usr/libexec/git-core/git-send-email"
  elif git help -a 2>/dev/null | grep -q 'send-email'; then
    printf "%-24s OK   %s\n" "git send-email" "git subcommand"
  elif [ "$CI_MODE" -eq 1 ]; then
    printf "%-24s optional-missing (ci)\n" "git send-email"
  else
    printf "%-24s MISS\n" "git send-email"
    status=1
  fi
}

echo "== Paths =="
printf "HOTDOG_ROOT=%s\n" "$HOTDOG_ROOT"
printf "HOTDOG_SRC_ROOT=%s\n" "$HOTDOG_SRC_ROOT"
printf "HOTDOG_BIN_ROOT=%s\n" "$HOTDOG_BIN_ROOT"
printf "HOTDOG_PMBOOTSTRAP_CONFIG=%s\n" "$HOTDOG_PMBOOTSTRAP_CONFIG"
printf "HOTDOG_PMBOOTSTRAP_WORK=%s\n" "$HOTDOG_PMBOOTSTRAP_WORK"
echo

echo "== Required host tools =="
for cmd in git adb fastboot dtc make bc bison flex openssl rsync cpio xz python3 losetup kpartx curl; do
  check_cmd "$cmd"
done
echo

echo "== Android image helpers =="
for cmd in mkbootimg unpack_bootimg repack_bootimg avbtool mkdtboimg lpunpack simg2img img2simg; do
  check_cmd "$cmd"
done
echo

echo "== Kernel/upstream helpers =="
for cmd in clang b4 zig qemu-aarch64; do
  check_cmd "$cmd"
done
check_git_send_email
check_optional aarch64-linux-gnu-gcc
check_optional payload-dumper-go
if [ -x "$HOTDOG_BIN_ROOT/payload-dumper-go" ]; then
  printf "%-24s OK   %s\n" "payload-dumper-go-local" "$HOTDOG_BIN_ROOT/payload-dumper-go"
fi
if [ -x "$HOTDOG_BIN_ROOT/pmbootstrap" ]; then
  printf "%-24s OK   %s\n" "pmbootstrap-local" "$HOTDOG_BIN_ROOT/pmbootstrap"

  # work path 兜底：CI 下自动创建，本地仍报 MISS
  if [ ! -d "$HOTDOG_PMBOOTSTRAP_WORK" ]; then
    if [ "$CI_MODE" -eq 1 ]; then
      mkdir -p "$HOTDOG_PMBOOTSTRAP_WORK"
      printf "%-24s created (ci) %s\n" "pmbootstrap-work" "$HOTDOG_PMBOOTSTRAP_WORK"
    else
      printf "%-24s MISS %s\n" "pmbootstrap-work" "$HOTDOG_PMBOOTSTRAP_WORK"
      status=1
    fi
  fi

  if ! "$HOTDOG_BIN_ROOT/pmbootstrap" \
        -c "$HOTDOG_PMBOOTSTRAP_CONFIG" \
        -p "$HOTDOG_PMAPORTS_SM8150" \
        -w "$HOTDOG_PMBOOTSTRAP_WORK" \
        status; then
    if [ "$CI_MODE" -eq 1 ]; then
      printf "%-24s warning (ci) %s\n" "pmbootstrap-status" "work path not initialised"
    else
      status=1
    fi
  fi
else
  printf "%-24s optional-missing\n" "pmbootstrap-local"
fi
echo

echo "== Phone rescue/first-boot helpers =="
check_optional scrcpy
check_optional sshpass
check_optional picocom
check_optional minicom
check_optional tcpdump
check_optional nmap
if [ -x "$HOTDOG_BIN_ROOT/edl" ]; then
  printf "%-24s OK   %s\n" "edl-local" "$HOTDOG_BIN_ROOT/edl"
else
  printf "%-24s optional-missing\n" "edl-local"
fi
if [ -x "$HOTDOG_BIN_ROOT/fhloaderparse" ]; then
  printf "%-24s OK   %s\n" "fhloaderparse-local" "$HOTDOG_BIN_ROOT/fhloaderparse"
fi
if [ -x "$HOTDOG_BIN_ROOT/qdl" ]; then
  printf "%-24s OK   %s\n" "qdl-local" "$HOTDOG_BIN_ROOT/qdl"
  if [ -d "$HOTDOG_ROOT/src/qualcomm/qdl/.git" ]; then
    printf "%-24s OK   %s\n" "qdl-source-rev" "$(git -C "$HOTDOG_ROOT/src/qualcomm/qdl" rev-parse --short HEAD 2>/dev/null || true)"
  fi
else
  printf "%-24s optional-missing\n" "qdl-local"
fi
if [ -r "$HOTDOG_ROOT/src/qualcomm/edl/Loaders/oneplus/000a50e100514985_2acf3a85fde334e2_fhprg_op7t.bin" ]; then
  printf "%-24s OK   %s\n" "op7t-edl-loader" "$HOTDOG_ROOT/src/qualcomm/edl/Loaders/oneplus/000a50e100514985_2acf3a85fde334e2_fhprg_op7t.bin"
else
  printf "%-24s optional-missing\n" "op7t-edl-loader"
fi
echo

if [ "$AUTOPILOT" -eq 1 ]; then
  echo "== Autopilot hard requirements =="
  for cmd in adb fastboot lsusb udevadm ssh sshpass ping ip scrcpy pgrep timeout sha256sum cmp; do
    check_cmd "$cmd"
  done
  check_executable_path edl-local "$HOTDOG_BIN_ROOT/edl"
  check_readable op7t-edl-loader "$HOTDOG_ROOT/src/qualcomm/edl/Loaders/oneplus/000a50e100514985_2acf3a85fde334e2_fhprg_op7t.bin"
fi

# 显式消费 status；原脚本若靠外部 set -e 隐含退出，这里补上更稳。
# 注意：--autopilot 与 --ci 同时给出时，autopilot 的硬校验优先。
if [ "$AUTOPILOT" -eq 1 ]; then
  exit "$status"
fi
exit "$status"
