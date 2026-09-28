#!/bin/bash

# Script version
SCRIPT_VERSION="2.0-Arise-Again"

set -eo pipefail

# Trap ctrl-c to clean up gracefully
trap 'echo -e "\n\033[0;31m[!] Interrupted by user. Exiting...\033[0m"; exit 130' INT

# Color definitions
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
cyan='\033[0;36m'
nocol='\033[0m'

# Define global variables
SRC="$(pwd)"
DEVICE="RMX2061"
CODENAME="Arise-Again"
AUTHOR="Neel0210"
KERNEL_DEFCONFIG="atoll_defconfig"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "Arise-Again")"
LOG_FILE="${SRC}/build.log"
COMPILATION_LOG="${SRC}/compilation.log"
ANYKERNEL3_DIR="${SRC}/AnyKernel3"
FINAL_KERNEL_ZIP=""
BUILD_START=""

# Options with defaults
BUILD_CLEAN=""      # "y", "n", or "" (prompt)
BUILD_KSU=""        # "y", "n", or "" (prompt)
ENABLE_TG=""       # "y", "n", or "" (auto-detect)
TEST_MODE="n"       # "y" or "n" (flash via adb sideload and reboot)
JOBS="$(nproc --all)"
VERBOSE=0

# Usage helper
show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --clean           Perform clean build (removes out/, runs make mrproper)
  --dirty           Perform dirty/incremental build (fast, keeps out/)
  --ksu             Build with KernelSU integration
  --no-ksu          Build without KernelSU
  --tg              Upload build artifacts and logs to Telegram
  --no-tg           Do not upload to Telegram (offline / local build)
  --test            Test mode: reboot to recovery, flash via adb sideload, reboot
  -j, --jobs N      Use N parallel compilation threads (default: $JOBS)
  -v, --verbose     Verbose make output (V=1)
  -h, --help        Show this help message

Examples:
  ./build.sh --dirty --no-ksu --no-tg       # Fastest local incremental build
  ./build.sh --clean --ksu --tg             # Full clean release build to Telegram
  ./build.sh --dirty --no-ksu --test        # Build and flash to connected device
EOF
}

# Parse command line flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)
            BUILD_CLEAN="y"
            shift
            ;;
        --dirty)
            BUILD_CLEAN="n"
            shift
            ;;
        --ksu)
            BUILD_KSU="y"
            shift
            ;;
        --no-ksu)
            BUILD_KSU="n"
            shift
            ;;
        --tg)
            ENABLE_TG="y"
            shift
            ;;
        --no-tg)
            ENABLE_TG="n"
            shift
            ;;
        --test)
            TEST_MODE="y"
            shift
            ;;
        -j|--jobs)
            JOBS="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo -e "${red}Unknown option: $1${nocol}"
            show_usage
            exit 1
            ;;
    esac
done

# Function to log messages
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Function to check required tools
check_tools() {
    local tools=("git" "curl" "wget" "make" "zip")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log "$red Tool $tool is required but not installed. Aborting... $nocol"
            exit 1
        fi
    done
}

# Locate Clang toolchain dynamically (repo-local clang prioritized, fallback to clone)
find_toolchain() {
    if [[ -n "$CLANG_PATH" && -x "$CLANG_PATH/bin/clang" ]]; then
        TOOLCHAIN_PATH="$CLANG_PATH"
    elif [[ -x "${SRC}/clang/bin/clang" ]]; then
        TOOLCHAIN_PATH="${SRC}/clang"
    elif [[ -x "${SRC}/toolchain/bin/clang" ]]; then
        TOOLCHAIN_PATH="${SRC}/toolchain"
    elif [[ -x "${HOME}/toolchain/clang/host/linux-x86/clang-r383902/bin/clang" ]]; then
        TOOLCHAIN_PATH="${HOME}/toolchain/clang/host/linux-x86/clang-r383902"
    elif [[ -x "${HOME}/proton/bin/clang" ]]; then
        TOOLCHAIN_PATH="${HOME}/proton"
    elif command -v clang &> /dev/null; then
        TOOLCHAIN_PATH="$(dirname "$(dirname "$(command -v clang)")")"
    else
        TOOLCHAIN_PATH="${SRC}/clang"
        log "$yellow No toolchain found in ${SRC}/clang. Cloning Proton Clang... $nocol"
        if ! git clone -q https://github.com/kdrag0n/proton-clang.git --depth=1 "$TOOLCHAIN_PATH"; then
            log "$red Cloning failed! Aborting... $nocol"
            exit 1
        fi
    fi
    log "$green Using Clang from: $TOOLCHAIN_PATH $nocol"
}

# Setup build environment
set_env_variables() {
    # Ensure 'python' command resolves (Android kernel build scripts invoke python)
    local py_shim_dir="${SRC}/.py_bin"
    mkdir -p "$py_shim_dir"
    if ! command -v python &> /dev/null; then
        local target_py=""
        if [[ -x "$TOOLCHAIN_PATH/python3/bin/python3" ]]; then
            target_py="$TOOLCHAIN_PATH/python3/bin/python3"
        elif command -v python3 &> /dev/null; then
            target_py="$(command -v python3)"
        elif command -v python2 &> /dev/null; then
            target_py="$(command -v python2)"
        fi
        if [[ -n "$target_py" ]]; then
            ln -sf "$target_py" "${py_shim_dir}/python"
            ln -sf "$target_py" "${py_shim_dir}/python2" 2>/dev/null || true
            export PATH="${py_shim_dir}:$PATH"
            log "$green Symlinked python -> $target_py $nocol"
        fi
    fi

    export PATH="$TOOLCHAIN_PATH/bin:$PATH"
    export ARCH=arm64
    export SUBARCH=arm64
    export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-$(whoami)}"
    export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-$(hostname)}"
    export KBUILD_COMPILER_STRING="$("$TOOLCHAIN_PATH/bin/clang" --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"

    # Dynamic ccache detection (no hardcoded user paths)
    if command -v ccache &> /dev/null; then
        export USE_CCACHE=1
        if [[ -d "${HOME}/.ccache" ]]; then
            export CCACHE_DIR="${HOME}/.ccache"
        elif [[ -d "${HOME}/ccache/.ccache" ]]; then
            export CCACHE_DIR="${HOME}/ccache/.ccache"
        fi
        export CCACHE_EXEC="$(command -v ccache)"
        export CC="ccache clang"
        export CXX="ccache clang++"
        ccache -M 50G 2>/dev/null || true
        log "$green ccache enabled for accelerated compilation $nocol"
    else
        export CC="clang"
        export CXX="clang++"
    fi
}

# Function to check for Telegram credentials
check_telegram() {
    if [[ "$ENABLE_TG" == "n" ]]; then
        log "$yellow Telegram upload disabled by flag. $nocol"
        return
    fi

    if [[ -z "${CHAT_ID}" || -z "${BOT_TOKEN}" ]]; then
        if [[ -f "${SRC}/SEND_TO_TG.txt" ]]; then
            CHAT_ID=$(grep 'CHAT_ID' "${SRC}/SEND_TO_TG.txt" | cut -d '=' -f2 | tr -d ' "')
            BOT_TOKEN=$(grep 'BOT_TOKEN' "${SRC}/SEND_TO_TG.txt" | cut -d '=' -f2 | tr -d ' "')
        fi
    fi

    if [[ -n "${CHAT_ID}" && -n "${BOT_TOKEN}" ]]; then
        ENABLE_TG="y"
        log "$green Telegram credentials configured. $nocol"
    else
        if [[ "$ENABLE_TG" == "y" ]]; then
            log "$red Telegram upload requested but CHAT_ID/BOT_TOKEN missing in env or SEND_TO_TG.txt. Disabling. $nocol"
        fi
        ENABLE_TG="n"
    fi
}

# Clean build routine
perform_clean_build() {
    log "$blue Performing clean build... $nocol"
    rm -rf "${SRC}/out"
    rm -rf "${SRC}/KernelSU" "${SRC}/drivers/kernelsu"
    make HOSTCC="gcc -B/usr/bin/" clean
    make HOSTCC="gcc -B/usr/bin/" mrproper
    rm -f "${SRC}"/*.log "${SRC}"/*.zip
}

handle_clean_or_dirty() {
    if [[ -z "$BUILD_CLEAN" ]]; then
        read -p "Do you want to perform a clean build? (y/n, default: n): " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            BUILD_CLEAN="y"
        else
            BUILD_CLEAN="n"
        fi
    fi

    if [[ "$BUILD_CLEAN" == "y" ]]; then
        perform_clean_build
    else
        log "$green Performing dirty / incremental build (preserving out/)... $nocol"
        rm -f "${SRC}"/*.zip
    fi
}

# Function to build with KernelSU
build_with_kernelsu() {
    log "$blue Setting up KernelSU... $nocol"
    if [[ ! -d "${SRC}/KernelSU" ]]; then
        curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s v0.9.5
        if [[ -f "${SRC}/KSU.patch" ]]; then
            git apply "${SRC}/KSU.patch" 2>/dev/null || true
        else
            wget -q "https://raw.githubusercontent.com/neel0210/patches/main/KSU.patch" -O KSU.patch
            git apply "${SRC}/KSU.patch" 2>/dev/null || true
        fi
    else
        log "$green KernelSU already setup. $nocol"
    fi
}

handle_kernelsu() {
    if [[ -z "$BUILD_KSU" ]]; then
        read -p "Do you want to build with KernelSU? (y/n, default: n): " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            BUILD_KSU="y"
        else
            BUILD_KSU="n"
        fi
    fi

    if [[ "$BUILD_KSU" == "y" ]]; then
        build_with_kernelsu
    else
        log "Building standard non-KSU kernel."
    fi
}

# Function to build the kernel
build_kernel() {
    log "$blue **** Kernel defconfig: $KERNEL_DEFCONFIG **** $nocol"
    log "$cyan ******************************************************"
    log "     BUILDING ARISE-AGAIN KERNEL (RMX2061) - ${AUTHOR}       "
    log "****************************************************** $nocol"

    mkdir -p "${SRC}/out"
    if [[ ! -f "${SRC}/out/.config" || "$BUILD_CLEAN" == "y" ]]; then
        make HOSTCC="gcc -B/usr/bin/" $KERNEL_DEFCONFIG O=out
    fi

    if ! make -j"$JOBS" O=out \
                          ARCH=arm64 \
                          CC="clang" \
                          CXX="clang++" \
                          HOSTCC="gcc -B/usr/bin/" \
                          CROSS_COMPILE=aarch64-linux-gnu- \
                          CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
                          AR=llvm-ar \
                          NM=llvm-nm \
                          OBJCOPY=llvm-objcopy \
                          OBJDUMP=llvm-objdump \
                          STRIP=llvm-strip \
                          V=$VERBOSE 2>&1 | tee "$COMPILATION_LOG"; then
        send_logs_and_exit
    fi
}

# Telegram helper
sanitize_for_telegram() {
    local input="$1"
    echo "$input" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

send_logs_and_exit() {
    if [[ "$ENABLE_TG" == "y" ]]; then
        local caption
        caption=$(printf "<b>Kernel Build Failed!</b>\n<b>Branch:</b> %s\n<b>Last commit:</b> %s" \
            "$(sanitize_for_telegram "$BRANCH")" \
            "$(sanitize_for_telegram "$(git log -1 --format=%B | head -n 1)")")
        curl -s -F "document=@$COMPILATION_LOG" --form-string "caption=${caption}" \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument?chat_id=${CHAT_ID}&parse_mode=HTML" > /dev/null || true
    fi
    log "$red Build failed! Check $COMPILATION_LOG $nocol"
    exit 1
}

# Verify output images
verify_kernel_build() {
    log "$blue **** Verifying build artifacts **** $nocol"
    local missing=0
    for img in Image.gz dtbo.img dtb.img; do
        if [[ ! -f "${SRC}/out/arch/arm64/boot/$img" ]]; then
            log "$red Error: out/arch/arm64/boot/$img not found! $nocol"
            missing=1
        else
            log "$green Found $img $nocol"
        fi
    done

    if [[ $missing -ne 0 ]]; then
        send_logs_and_exit
    fi
}

# Package kernel using AnyKernel3
zip_kernel_files() {
    log "$blue **** Packaging AnyKernel3 **** $nocol"

    if [ ! -d "$ANYKERNEL3_DIR" ]; then
        git clone --depth=1 https://github.com/neel0210/AnyKernel3.git -b SATORU "$ANYKERNEL3_DIR"
    fi

    cp -f "${SRC}/out/arch/arm64/boot/Image.gz" "$ANYKERNEL3_DIR/"
    cp -f "${SRC}/out/arch/arm64/boot/dtbo.img" "$ANYKERNEL3_DIR/"
    cp -f "${SRC}/out/arch/arm64/boot/dtb.img" "$ANYKERNEL3_DIR/"

    local timestamp
    timestamp="$(date +"%Y%m%d-%H%M%S")"

    cd "$ANYKERNEL3_DIR"
    if [[ "$BUILD_KSU" == "y" ]]; then
        FINAL_KERNEL_ZIP="${CODENAME}-KSU-${DEVICE}-${AUTHOR}-${timestamp}.zip"
    else
        FINAL_KERNEL_ZIP="${CODENAME}-${DEVICE}-${AUTHOR}-${timestamp}.zip"
    fi

    log "$cyan Creating zip package: ${FINAL_KERNEL_ZIP}... $nocol"
    zip -r9 "${SRC}/${FINAL_KERNEL_ZIP}" ./* -x README .git\* "*.zip" > /dev/null
    cd "$SRC"
}

# Compute checksum
compute_checksum() {
    log "$yellow ***********************************************"
    log "         SHA1 Checksum:         "
    log "*********************************************** $nocol"
    if [[ -f "${SRC}/${FINAL_KERNEL_ZIP}" ]]; then
        sha1sum "${SRC}/${FINAL_KERNEL_ZIP}" | tee -a "$LOG_FILE"
    fi
}

# Upload kernel to Telegram
upload_kernel_to_telegram() {
    if [[ "$ENABLE_TG" != "y" ]]; then
        return
    fi

    log "$blue Uploading build to Telegram... $nocol"
    local caption
    caption=$(printf "<b>%s Build Successful!</b>\n<b>Device:</b> %s\n<b>Branch:</b> %s\n<b>Last commit:</b> %s" \
        "$CODENAME" "$DEVICE" \
        "$(sanitize_for_telegram "$BRANCH")" \
        "$(sanitize_for_telegram "$(git log -1 --format=%B | head -n 1)")")

    for zipfile in "${SRC}"/*.zip; do
        if [[ -f "$zipfile" ]]; then
            curl -s -F "document=@$zipfile" --form-string "caption=${caption}" \
                "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument?chat_id=${CHAT_ID}&parse_mode=HTML" > /dev/null || true
        fi
    done

    if [[ -f "$COMPILATION_LOG" ]]; then
        curl -s -F "document=@$COMPILATION_LOG" --form-string "caption=Compilation Log: ${caption}" \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument?chat_id=${CHAT_ID}&parse_mode=HTML" > /dev/null || true
    fi
}

# Flash kernel zip via adb sideload if --test requested
flash_and_test() {
    if [[ "$TEST_MODE" != "y" ]]; then
        return
    fi

    local zip_path="${SRC}/${FINAL_KERNEL_ZIP}"
    if [[ ! -f "$zip_path" ]]; then
        log "$red [!] Zip file $zip_path not found. Cannot test. $nocol"
        return 1
    fi

    if ! command -v adb &> /dev/null; then
        log "$red [!] adb command not found in PATH. Install android-tools-adb. $nocol"
        return 1
    fi

    log "$yellow *********************************************** $nocol"
    log "$yellow [*] Test Mode: Initiating sideload flash... $nocol"
    log "$yellow *********************************************** $nocol"

    # Check device state
    local state
    state="$(adb get-state 2>/dev/null || echo "offline")"
    log "$blue [*] Current ADB state: ${state} $nocol"

    if [[ "$state" != "sideload" && "$state" != "recovery" ]]; then
        log "$yellow [*] Rebooting device into recovery... $nocol"
        adb reboot recovery 2>/dev/null || true
        log "$yellow [*] Waiting for device to enter recovery / sideload mode... $nocol"
        local waited=0
        while [[ $waited -lt 60 ]]; do
            state="$(adb get-state 2>/dev/null || echo "offline")"
            if [[ "$state" == "recovery" || "$state" == "sideload" ]]; then
                break
            fi
            sleep 2
            waited=$((waited + 2))
        done
    fi

    # If in recovery mode, put into sideload mode
    if [[ "$state" == "recovery" ]]; then
        log "$blue [*] Device in recovery. Starting sideload server... $nocol"
        adb shell twrp sideload 2>/dev/null || adb reboot sideload 2>/dev/null || true
    fi

    # Wait until adb state is explicitly 'sideload'
    log "$yellow [*] Waiting for sideload mode to become ready... $nocol"
    local waited=0
    while [[ $waited -lt 40 ]]; do
        state="$(adb get-state 2>/dev/null || echo "offline")"
        if [[ "$state" == "sideload" ]]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    # Give recovery daemon a moment to open socket
    sleep 3

    log "$green [*] Sending sideload: $(basename "$zip_path")... $nocol"
    local retries=3
    local success=0
    while [[ $retries -gt 0 ]]; do
        if adb sideload "$zip_path"; then
            success=1
            break
        fi
        retries=$((retries - 1))
        if [[ $retries -gt 0 ]]; then
            log "$yellow [!] Sideload socket closed/busy, waiting 3s to retry ($retries left)... $nocol"
            sleep 3
        fi
    done

    if [[ $success -eq 1 ]]; then
        log "$green [*] Sideload succeeded! Waiting 5s for install scripts... $nocol"
        sleep 5
        adb reboot 2>/dev/null || adb reboot system 2>/dev/null || true
        log "$green [*] Device rebooted. Test flash complete! $nocol"
    else
        log "$red [!] Sideload failed! Check device screen or adb connection. $nocol"
        return 1
    fi
}

# Cleanup
clean_up() {
    rm -rf "${SRC}/.py_bin"
    log "$cyan All done! $nocol"
}

# Main execution flow
check_tools
find_toolchain
set_env_variables
check_telegram
handle_clean_or_dirty
BUILD_START=$(date +"%s")
handle_kernelsu
build_kernel
verify_kernel_build
zip_kernel_files
compute_checksum
upload_kernel_to_telegram
flash_and_test

BUILD_END=$(date +"%s")
DIFF=$((BUILD_END - BUILD_START))
log "$green Build completed successfully in $((DIFF / 60)) minute(s) and $((DIFF % 60)) seconds. $nocol"
clean_up
