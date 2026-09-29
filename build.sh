#!/bin/bash
# Arise-Again Kernel Build Script
# Version 2.0

set -euo pipefail

# ── Global Config ──────────────────────────────────────────────────
SRC="$(cd "$(dirname "$0")" && pwd)"
PROTON_PATH="/home/itachi/proton"
KBUILD_BUILD_USER="Itachi"
KBUILD_BUILD_HOST="Konoha"
ANYKERNEL3_DIR="${SRC}/AnyKernel3"
DEVICE="RMX2061"
VERSION="$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
KERNEL_DEFCONFIG="atoll_defconfig"
LOG_FILE="${SRC}/build.log"
COMPILATION_LOG="${SRC}/compilation.log"
JOBS="$(nproc --all)"
FINAL_KERNEL_ZIP=""

# ── Defaults (overridden by flags) ────────────────────────────────
CLEAN=0
KSU=0
TELEGRAM=0
VERBOSE=0
CHAT_ID="${CHAT_ID:-}"
BOT_TOKEN="${BOT_TOKEN:-}"

# ── Colors ────────────────────────────────────────────────────────
red='\033[0;31m'  green='\033[0;32m'  yellow='\033[0;33m'
blue='\033[0;34m'  cyan='\033[0;36m'  bold='\033[1m'
nocol='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────
log()  { echo -e "${blue}[*]${nocol} $1" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${green}[✓]${nocol} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${yellow}[!]${nocol} $1" | tee -a "$LOG_FILE"; }
die()  { echo -e "${red}[✗]${nocol} $1" | tee -a "$LOG_FILE"; exit 1; }

banner() {
    echo -e "${cyan}${bold}"
    echo "╔══════════════════════════════════════════╗"
    echo "║        Arise-Again Kernel Builder        ║"
    echo "║             v2.0 · RMX2061               ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${nocol}"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -c, --clean       Full clean build (make clean && mrproper)
  -d, --dirty       Dirty build (skip cleaning, fastest rebuild)
  -k, --ksu         Build with KernelSU
  -t, --telegram    Upload zip + logs to Telegram after build
  -j N              Override parallel job count (default: $(nproc --all))
  -v, --verbose     Verbose make output (V=1)
  -h, --help        Show this help

Environment:
  CHAT_ID           Telegram chat ID (or set in SEND_TO_TG.txt)
  BOT_TOKEN         Telegram bot token (or set in SEND_TO_TG.txt)

Examples:
  ./build.sh -d              # Fast dirty rebuild
  ./build.sh -c -k -t        # Clean build + KernelSU + Telegram upload
  ./build.sh -j 8            # Use 8 parallel jobs
EOF
    exit 0
}

# ── Argument Parsing ──────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--clean)    CLEAN=1 ;;
            -d|--dirty)    CLEAN=0 ;;
            -k|--ksu)      KSU=1 ;;
            -t|--telegram) TELEGRAM=1 ;;
            -v|--verbose)  VERBOSE=1 ;;
            -j)            JOBS="${2:?'-j requires a number'}"; shift ;;
            -h|--help)     usage ;;
            *)             die "Unknown option: $1 (try --help)" ;;
        esac
        shift
    done
}

# ── Tool Check ────────────────────────────────────────────────────
check_tools() {
    local tools=(git curl make zip)
    for t in "${tools[@]}"; do
        command -v "$t" &>/dev/null || die "$t is required but not found"
    done
    ok "All required tools present"
}

# ── Telegram ──────────────────────────────────────────────────────
load_telegram_creds() {
    if [[ -z "$CHAT_ID" || -z "$BOT_TOKEN" ]]; then
        if [[ -f "${SRC}/SEND_TO_TG.txt" ]]; then
            CHAT_ID="$(grep '^CHAT_ID' "${SRC}/SEND_TO_TG.txt" | cut -d'=' -f2)"
            BOT_TOKEN="$(grep '^BOT_TOKEN' "${SRC}/SEND_TO_TG.txt" | cut -d'=' -f2)"
        fi
    fi
    if [[ -z "$CHAT_ID" || -z "$BOT_TOKEN" ]]; then
        warn "Telegram credentials missing — skipping upload"
        TELEGRAM=0
    else
        ok "Telegram credentials loaded"
    fi
}

sanitize_tg() {
    echo "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

tg_send_file() {
    local file="$1" caption="$2"
    curl -sS -F "document=@${file}" \
        --form-string "caption=${caption}" \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument?chat_id=${CHAT_ID}&parse_mode=HTML" \
        >/dev/null
}

send_failure_log() {
    [[ "$TELEGRAM" -eq 1 ]] || return 0
    local caption
    caption="$(printf '<b>❌ Build FAILED</b>\n<b>Branch:</b> %s\n<b>Commit:</b> %s' \
        "$(sanitize_tg "$VERSION")" \
        "$(sanitize_tg "$(git -C "$SRC" log -1 --format=%s)")")"
    tg_send_file "$COMPILATION_LOG" "$caption" || true
}

# ── Toolchain ─────────────────────────────────────────────────────
setup_toolchain() {
    if [[ ! -d "$PROTON_PATH" ]]; then
        log "Cloning Proton Clang..."
        git clone -q --depth=1 --single-branch \
            https://github.com/kdrag0n/proton-clang "$PROTON_PATH" \
            || die "Toolchain clone failed"
    fi
    export PATH="$PROTON_PATH/bin:$PATH"
    export ARCH=arm64 SUBARCH=arm64
    export KBUILD_COMPILER_STRING="$("$PROTON_PATH/bin/clang" --version | head -1 | sed 's/(http[^)]*)//g;s/  */ /g;s/ *$//')"
    ok "Toolchain: $KBUILD_COMPILER_STRING"
}

# ── Ccache ────────────────────────────────────────────────────────
setup_ccache() {
    if command -v ccache &>/dev/null; then
        export USE_CCACHE=1
        export CCACHE_DIR="${HOME}/ccache/.ccache"
        export CCACHE_EXEC="$(command -v ccache)"
        export CC="ccache clang"
        export CXX="ccache clang++"
        ccache -M 50G 2>/dev/null
        ok "ccache enabled ($(ccache -s 2>/dev/null | grep 'cache size' | head -1 || echo 'N/A'))"
    else
        warn "ccache not found — building without cache"
    fi
}

# ── Clean ─────────────────────────────────────────────────────────
do_clean() {
    log "Cleaning build tree..."
    rm -rf "${SRC}/out/arch/arm64/boot/Image.gz"
    rm -rf "${SRC}/KernelSU" "${SRC}/drivers/kernelsu"
    make -C "$SRC" clean 2>/dev/null || true
    make -C "$SRC" mrproper 2>/dev/null || true
    rm -f "${SRC}"/*.log
    ok "Clean complete"
}

# ── KernelSU ──────────────────────────────────────────────────────
setup_ksu() {
    log "Setting up KernelSU..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s v0.9.5
    if [[ -f "${SRC}/KSU.patch" ]]; then
        rm -f "${SRC}/KSU.patch"
    fi
    wget -q "https://raw.githubusercontent.com/neel0210/patches/main/KSU.patch" -O "${SRC}/KSU.patch"
    git -C "$SRC" apply ./KSU.patch || warn "KSU patch may already be applied"
    ok "KernelSU setup complete"
}

# ── Build ─────────────────────────────────────────────────────────
do_build() {
    log "Building kernel (${JOBS} jobs, defconfig=${KERNEL_DEFCONFIG})..."
    echo ""
    echo -e "${bold}${cyan}  ┌─────────────────────────────────────┐"
    echo "  │     BUILDING ARISE-AGAIN KERNEL     │"
    echo -e "  └─────────────────────────────────────┘${nocol}"
    echo ""

    make -C "$SRC" "$KERNEL_DEFCONFIG" O=out ARCH=arm64 CC=clang LD=ld.lld

    if ! make -C "$SRC" -j"$JOBS" O=out \
            ARCH=arm64 \
            CC=clang \
            LD=ld.lld \
            CROSS_COMPILE=aarch64-linux-gnu- \
            CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
            AR=llvm-ar NM=llvm-nm \
            OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump \
            STRIP=llvm-strip \
            V="$VERBOSE" 2>&1 | tee "$COMPILATION_LOG"; then
        die "Kernel compilation failed — check $COMPILATION_LOG"
    fi
}

# ── Verify ────────────────────────────────────────────────────────
verify_build() {
    local boot="${SRC}/out/arch/arm64/boot"
    for img in Image.gz Image.gz-dtb; do
        [[ -f "${boot}/${img}" ]] || die "${img} not found — build failed"
    done
    ok "All boot images verified"
}

# ── Package ───────────────────────────────────────────────────────
do_package() {
    log "Packaging kernel zip..."

    if [[ ! -d "$ANYKERNEL3_DIR" ]]; then
        git clone --depth=1 https://github.com/neel0210/AnyKernel3.git -b SATORU "$ANYKERNEL3_DIR"
    fi

    cp "${SRC}/out/arch/arm64/boot/Image.gz"      "$ANYKERNEL3_DIR/"
    cp "${SRC}/out/arch/arm64/boot/Image.gz-dtb"  "$ANYKERNEL3_DIR/"
    if [[ -f "${SRC}/out/arch/arm64/boot/dtb.img" ]]; then
        cp "${SRC}/out/arch/arm64/boot/dtb.img"   "$ANYKERNEL3_DIR/"
    fi
    rm -f "$ANYKERNEL3_DIR/dtbo.img"

    local prefix="Arise-Again"
    [[ "$KSU" -eq 1 ]] && prefix="${prefix}-KSU"
    FINAL_KERNEL_ZIP="${prefix}-${VERSION}-${DEVICE}-$(date +%Y%m%d-%H%M).zip"

    (cd "$ANYKERNEL3_DIR" && zip -r9 "${SRC}/${FINAL_KERNEL_ZIP}" . -x README .git/\*)

    local sha
    sha="$(sha1sum "${SRC}/${FINAL_KERNEL_ZIP}" | cut -d' ' -f1)"
    ok "Packaged: ${FINAL_KERNEL_ZIP}"
    ok "SHA1:     ${sha}"
}

# ── Upload ────────────────────────────────────────────────────────
do_upload() {
    log "Uploading to Telegram..."
    local caption
    caption="$(printf '<b>✅ %s</b>\n<b>Branch:</b> %s\n<b>Commit:</b> %s\n<b>Built in:</b> %s' \
        "$(sanitize_tg "$FINAL_KERNEL_ZIP")" \
        "$(sanitize_tg "$VERSION")" \
        "$(sanitize_tg "$(git -C "$SRC" log -1 --format=%s)")" \
        "$(sanitize_tg "$ELAPSED")")"
    tg_send_file "${SRC}/${FINAL_KERNEL_ZIP}" "$caption"
    tg_send_file "$COMPILATION_LOG" "<b>Build log</b>" || true
    ok "Upload complete"
}

# ── Cleanup ───────────────────────────────────────────────────────
do_cleanup() {
    rm -rf "$ANYKERNEL3_DIR"
}

# ══════════════════════════════════════════════════════════════════
# ██  MAIN
# ══════════════════════════════════════════════════════════════════
main() {
    parse_args "$@"
    banner

    # Truncate log
    : > "$LOG_FILE"

    check_tools
    [[ "$TELEGRAM" -eq 1 ]] && load_telegram_creds
    setup_toolchain
    setup_ccache

    # Clean if requested
    [[ "$CLEAN" -eq 1 ]] && do_clean

    # Remove old zips
    rm -f "${SRC}"/*.zip

    # KernelSU
    [[ "$KSU" -eq 1 ]] && setup_ksu

    # Build
    local start end
    start=$(date +%s)
    trap 'send_failure_log' ERR

    do_build
    verify_build
    do_package

    end=$(date +%s)
    ELAPSED="$(( (end - start) / 60 ))m $(( (end - start) % 60 ))s"

    echo ""
    echo -e "${green}${bold}  ┌─────────────────────────────────────┐"
    echo "  │   BUILD COMPLETE: ${ELAPSED}            │"
    echo -e "  └─────────────────────────────────────┘${nocol}"
    echo ""

    # Upload
    [[ "$TELEGRAM" -eq 1 ]] && do_upload

    do_cleanup
    ok "All done! Kernel zip: ${FINAL_KERNEL_ZIP}"
}

main "$@"
