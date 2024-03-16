#!/bin/bash

# Script version
SCRIPT_VERSION="1.0"

set -e

# Define global variables
SRC="$(pwd)"
PROTON_PATH="/home/itachi/proton"
ANYKERNEL3_DIR=AnyKernel3
FINAL_KERNEL_ZIP=""
BUILD_START=""
DEVICE=RMX2061
VERSION=MUICHIRO-M1
KERNEL_DEFCONFIG=atoll_defconfig

# Function to clone Proton clang if not found
clone_proton_clang() {
    if [ ! -d "$PROTON_PATH" ]; then
        echo "Proton clang not found at $PROTON_PATH! Cloning..."
        if ! git clone -q https://github.com/kdrag0n/proton-clang --depth=1 --single-branch "$PROTON_PATH"; then
            echo "Cloning failed! Aborting..."
            exit 1
        fi
    else
        echo "Proton clang found at $PROTON_PATH"
    fi
}

# Function to set environment variables
set_env_variables() {
    export PATH="$PROTON_PATH/bin:$PATH"
    export ARCH=arm64
    export SUBARCH=arm64
    export KBUILD_COMPILER_STRING="$($PROTON_PATH/bin/clang --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"
}

# Function to perform clean build
perform_clean_build() {
    echo "Performing clean build..."
    make clean
    make mrproper
    rm -rf *.zip
    rm -rf *.log
}

# Function to build with KernelSU
build_with_kernelsu() {
    echo "Building with KernelSU..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash
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
    echo "**** Kernel defconfig is set to $KERNEL_DEFCONFIG ****"
    echo -e "$blue***********************************************"
    echo "          BUILDING KAKAROT KERNEL          "
    echo -e "***********************************************$nocol"
#    make mrproper && make clean
    make $KERNEL_DEFCONFIG O=out
    make -j$(nproc --all) O=out \
                          ARCH=arm64 \
                          CC=clang \
                          CROSS_COMPILE=aarch64-linux-gnu- \
                          CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
                          NM=llvm-nm \
                          OBJCOPY=llvm-objcopy \
                          OBJDUMP=llvm-objdump \
                          STRIP=llvm-strip \
                          V=$VERBOSE 2>&1 | tee error.log
}

# Function to verify kernel build
verify_kernel_build() {
    echo "**** Verify Image.gz & dtbo.img ****"
    ls $PWD/out/arch/arm64/boot/Image.gz
    ls $PWD/out/arch/arm64/boot/dtbo.img
    ls $PWD/out/arch/arm64/boot/dtb.img

    if ! [ -a "$SRC/out/arch/arm64/boot/Image.gz" ]; then
        echo -e "$blue***********************************************"
        echo "          BUILD THROWS ERRORS         "
        echo -e "***********************************************$nocol"
        for i in *.log; do
            curl -F "document=@$i" --form-string "caption=" "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument?chat_id=${CHAT_ID}&parse_mode=HTML"
        done
        rm -rf error.log
        exit 1
    else
        echo -e "$blue***********************************************"
        echo "    KERNEL COMPILATION FINISHED, STARTING ZIPPING         "
        echo -e "***********************************************$nocol"
        rm -rf error.log
    fi
}

# Function to zip kernel files
zip_kernel_files() {
    echo "**** Verifying AnyKernel3 Directory ****"

    if [ ! -d "$SRC/AnyKernel3" ]; then
        git clone --depth=1 https://github.com/neel0210/AnyKernel3.git -b MUICHIRO AnyKernel3
    else
        echo " "
    fi

    # Anykernel 3 time!!
    ls $ANYKERNEL3_DIR

    echo "**** Copying Image.gz & dtbo.img ****"
    cp $PWD/out/arch/arm64/boot/Image.gz $ANYKERNEL3_DIR/
    cp $PWD/out/arch/arm64/boot/dtbo.img $ANYKERNEL3_DIR/
    cp $PWD/out/arch/arm64/boot/dtb.img $ANYKERNEL3_DIR/

    echo -e "$cyan***********************************************"
    echo "          Time to zip up!          "
    echo -e "***********************************************$nocol"
    cd $ANYKERNEL3_DIR/
    FINAL_KERNEL_ZIP=KKRT-${VERSION}-${DEVICE}-$(date +"%F%S").zip
    zip -r9 "../$FINAL_KERNEL_ZIP" * -x README $FINAL_KERNEL_ZIP
}

# Function to compute SHA1 checksum
compute_checksum() {
    echo -e "$yellow***********************************************"
    echo "         Done, here is your sha1         "
    echo -e "***********************************************$nocol"
    cd ..
    sha1sum $FINAL_KERNEL_ZIP
}

# Function to upload kernel to Telegram
upload_kernel_to_telegram() {
    echo -e "$red***********************************************"
    echo "         Uploading to telegram         "
    echo -e "***********************************************$nocol"

    # Upload Time!!
    for i in *.zip; do
        curl -F "document=@$i" --form-string "caption=" "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument?chat_id=${CHAT_ID}&parse_mode=HTML"
    done
}

# Function to clean up
clean_up() {
    echo -e "$cyan***********************************************"
    echo "          All done !!!         "
    echo -e "***********************************************$nocol"
    rm -rf $ANYKERNEL3_DIR
}

# Function to ask whether to perform a clean build
ask_clean_build() {
    read -p "Do you want to perform a clean build? (y/n): " clean_build
    if [[ $clean_build =~ ^[Yy]$ ]]; then
        perform_clean_build
    else
        echo "Skipping clean build..."
    fi
}

# Main function
main() {
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
    clean_up

    BUILD_END=$(date +"%s")
    DIFF=$(($BUILD_END - $BUILD_START))
    echo -e "$yellow Build completed in $(($DIFF / 60)) minute(s) and $(($DIFF % 60)) seconds.$nocol"
}

# Call main function
main

