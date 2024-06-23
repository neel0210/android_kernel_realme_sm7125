#!/bin/bash

# Script version
SCRIPT_VERSION="1.3"

set -e

# Define global variables
SRC="$(pwd)"
PROTON_PATH="/home/itachi/proton"
KBUILD_BUILD_USER="Itachi"
KBUILD_BUILD_HOST="Konoha"
ANYKERNEL3_DIR=AnyKernel3
FINAL_KERNEL_ZIP=""
BUILD_START=""
DEVICE=RMX2061
VERSION=$(git rev-parse --abbrev-ref HEAD)  # Get the current branch name
KERNEL_DEFCONFIG=atoll_defconfig
LOG_FILE="${SRC}/build.log"
COMPILATION_LOG="${SRC}/compilation.log"
USER=$(whoami)

# Remove old kernel zip files
rm -rf *.zip

# Color definitions
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
cyan='\033[0;36m'
nocol='\033[0m'

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

# Function to prompt for Telegram credentials
prompt_for_telegram_credentials() {
    read -p "Do you want to add Telegram credentials to SEND_TO_TG.txt? (y/n): " add_creds
    if [[ $add_creds =~ ^[Yy]$ ]]; then
        read -p "Enter CHAT_ID: " chat_id
        read -p "Enter BOT_TOKEN: " bot_token
        echo -e "CHAT_ID=${chat_id}\nBOT_TOKEN=${bot_token}" > "${SRC}/SEND_TO_TG.txt"
        log "$green Telegram credentials added to SEND_TO_TG.txt $nocol"
        CHAT_ID=$chat_id
        BOT_TOKEN=$bot_token
    else
        log "$red Aborting... $nocol"
    fi
}

# Function to check for Telegram credentials
check_telegram_credentials() {
    if [[ -z "${CHAT_ID}" || -z "${BOT_TOKEN}" ]]; then
        if [[ -f "${SRC}/SEND_TO_TG.txt" ]]; then
            log "$yellow Using Telegram credentials from SEND_TO_TG.txt $nocol"
            CHAT_ID=$(grep 'CHAT_ID' "${SRC}/SEND_TO_TG.txt" | cut -d '=' -f2)
            BOT_TOKEN=$(grep 'BOT_TOKEN' "${SRC}/SEND_TO_TG.txt" | cut -d '=' -f2)

            # Check if credentials are still empty
            if [[ -z "${CHAT_ID}" || -z "${BOT_TOKEN}" ]]; then
                prompt_for_telegram_credentials
            fi
        else
            log "$red CHAT_ID and BOT_TOKEN are not set and SEND_TO_TG.txt is missing. $nocol"
            prompt_for_telegram_credentials
        fi
    else
        log "$green Telegram credentials found in environment variables. $nocol"
    fi
}

# Function to clone Proton clang if not found
clone_proton_clang() {
    if [ ! -d "$PROTON_PATH" ]; then
        log "$blue Proton clang not found at $PROTON_PATH! Cloning... $nocol"
        if ! git clone -q https://github.com/kdrag0n/proton-clang --depth=1 --single-branch "$PROTON_PATH"; then
            log "$red Cloning failed! Aborting... $nocol"
            exit 1
        fi
    else
        log "$green Proton clang found at $PROTON_PATH $nocol"
    fi
}

# Function to set environment variables
set_env_variables() {
    export PATH="$PROTON_PATH/bin:$PATH"
    export ARCH=arm64
    export SUBARCH=arm64
    export KBUILD_COMPILER_STRING="$($PROTON_PATH/bin/clang --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"
    
    # Use ccache if the user is itachi
    if [ "$USER" == "itachi" ]; then
        export USE_CCACHE=1
        export CCACHE_DIR=/home/itachi/ccache/.ccache
        export CCACHE_EXEC=$(command -v ccache)
        export CC="ccache clang"
        export CXX="ccache clang++"
        ccache -M 50G
        log "$green Using ccache for faster builds $nocol"
    fi
}

# Function to perform clean build
perform_clean_build() {
    log "$blue Performing clean build... $nocol"
    rm -rf $PWD/out/arch/arm64/boot/Image.gz
    rm -rf KernelSU
    rm -rf drivers/kernelsu
    git checkout -- .
    make clean
    make mrproper
    rm -rf *.log
}

# Function to build with KernelSU
build_with_kernelsu() {
    log "$blue Building with KernelSU... $nocol"
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s v0.9.5
    wget -q "https://raw.githubusercontent.com/neel0210/patches/main/KSU.patch" -O KSU.patch
    git apply ./KSU.patch
}

# Function to ask whether to build with KernelSU
ask_build_with_kernelsu() {
    read -p "Do you want to build with KernelSU? (y/n): " build_kernelsu
    if [[ $build_kernelsu =~ ^[Yy]$ ]]; then
        build_with_kernelsu
    fi
}

# Function to build the kernel
build_kernel() {
    log "$blue **** Kernel defconfig is set to $KERNEL_DEFCONFIG **** $nocol"
    log "$blue ***********************************************"
    log "          BUILDING KAKAROT KERNEL          "
    log "*********************************************** $nocol"
    make $KERNEL_DEFCONFIG O=out
    make -j$(nproc --all) O=out \
                          ARCH=arm64 \
                          CC=clang \
                          CROSS_COMPILE=aarch64-linux-gnu- \
                          CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
                          AR=llvm-ar \
                          NM=llvm-nm \
                          OBJCOPY=llvm-objcopy \
                          OBJDUMP=llvm-objdump \
                          STRIP=llvm-strip \
                          V=$VERBOSE 2>&1 | tee $COMPILATION_LOG
}

# Function to verify kernel build
verify_kernel_build() {
    log "$blue **** Verify Image.gz & dtbo.img **** $nocol"
    ls $PWD/out/arch/arm64/boot/Image.gz
    ls $PWD/out/arch/arm64/boot/dtbo.img
    ls $PWD/out/arch/arm64/boot/dtb.img

    if ! [ -a "$SRC/out/arch/arm64/boot/Image.gz" ]; then
        log "$blue ***********************************************"
        log "          BUILD THROWS ERRORS         "
        log "*********************************************** $nocol"
        curl -F "document=@$COMPILATION_LOG" --form-string "caption=<b>Branch Name:</b> $(git rev-parse --abbrev-ref HEAD)$'\n'<b>Last commit:</b> $(git log -1 --format=%B)" "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument?chat_id=${CHAT_ID}&parse_mode=HTML"
        exit 1
    else
        log "$blue ***********************************************"
        log "    KERNEL COMPILATION FINISHED, STARTING ZIPPING         "
        log "*********************************************** $nocol"
    fi
}

# Function to zip kernel files
zip_kernel_files() {
    log "$blue **** Verifying AnyKernel3 Directory **** $nocol"

    if [ ! -d "$SRC/AnyKernel3" ]; then
        git clone --depth=1 https://github.com/neel0210/AnyKernel3.git -b SATORU AnyKernel3
    else
        log "$green AnyKernel3 directory found $nocol"
    fi

    # Anykernel 3 time!!
    ls $ANYKERNEL3_DIR

    log "$blue **** Copying Image.gz & dtbo.img **** $nocol"
    cp $PWD/out/arch/arm64/boot/Image.gz $ANYKERNEL3_DIR/
    cp $PWD/out/arch/arm64/boot/dtbo.img $ANYKERNEL3_DIR/
    cp $PWD/out/arch/arm64/boot/dtb.img $ANYKERNEL3_DIR/

    log "$cyan ***********************************************"
    log "          Time to zip up!          "
    log "*********************************************** $nocol"

    if [ -d "KernelSU" ]; then
        log "Packing KSU Build"
        cd $ANYKERNEL3_DIR/
        FINAL_KERNEL_ZIP=KKRT-KSU-${VERSION}-${DEVICE}-$(date +"%F%S").zip
        zip -r9 "../$FINAL_KERNEL_ZIP" * -x README "$FINAL_KERNEL_ZIP"
    else
        log "Packing NON-KSU Build"
        cd $ANYKERNEL3_DIR/
        FINAL_KERNEL_ZIP=KKRT-${VERSION}-${DEVICE}-$(date +"%F%S").zip
        zip -r9 "../$FINAL_KERNEL_ZIP" * -x README "$FINAL_KERNEL_ZIP"
    fi
}

# Function to compute SHA1 checksum
compute_checksum() {
    log "$yellow ***********************************************"
    log "         Done, here is your sha1         "
    log "*********************************************** $nocol"
    cd ..
    sha1sum $FINAL_KERNEL_ZIP
}

# Function to upload kernel to Telegram
upload_kernel_to_telegram() {
    log "$red ***********************************************"
    log "         Uploading to telegram         "
    log "*********************************************** $nocol"
    
    # Create the caption text
    caption=$(printf "<b>Branch Name:</b> %s\n\n<b>Last commit:</b> %s" "$(git rev-parse --abbrev-ref HEAD)" "$(git log -1 --format=%B)")

    # Upload Time!!
    for i in *.zip; do
        curl -F "document=@$i" --form-string "caption=" "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument?chat_id=${CHAT_ID}&parse_mode=HTML"
    done
    # Upload log file with branch name and last commit
    curl -F "document=@$COMPILATION_LOG" \
    --form-string "caption=${caption}" \
    "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument?chat_id=${CHAT_ID}&parse_mode=HTML"
}

# Function to clean up
clean_up() {
    log "$cyan ***********************************************"
    log "          All done !!!         "
    log "*********************************************** $nocol"
    rm -rf $ANYKERNEL3_DIR
}

# Function to ask whether to perform a clean build
ask_clean_build() {
    read -p "Do you want to perform a clean build? (y/n): " clean_build
    if [[ $clean_build =~ ^[Yy]$ ]]; then
        perform_clean_build
    else
        log "Skipping clean build..."
    fi
}

# Main script execution
check_tools
check_telegram_credentials
clone_proton_clang
set_env_variables
ask_clean_build
BUILD_START=$(date +"%s")
ask_build_with_kernelsu
build_kernel
verify_kernel_build
zip_kernel_files
compute_checksum
upload_kernel_to_telegram

BUILD_END=$(date +"%s")
DIFF=$(($BUILD_END - $BUILD_START))
log "$yellow Build completed in $(($DIFF / 60)) minute(s) and $(($DIFF % 60)) seconds. $nocol"

