#!/bin/bash

#set -e

 #
 # Script For Building Android Kernel
 #

##----------------------------------------------------------##

SRC="$(pwd)"

# Cache
export CCACHE_EXEC="/usr/bin/ccache"
export USE_CCACHE=1
ccache -M 5G
export CCACHE_COMPRESS=1
export CCACHE_DIR=$(whoami)/ccache/.ccache

# Config
KERNEL_DEFCONFIG=atoll_defconfig

# Kernel version
DEVICE=RMX2061
VERSION=MUICHIRO-M1

# Zipping
DATE=$(TZ=Asia/Kolkata date +"%Y%m%d-%T")
TANGGAL=$(date +"%F%S")
ANYKERNEL3_DIR=AnyKernel3
FINAL_KERNEL_ZIP=KKRT-${VERSION}-${DEVICE}-${TANGGAL}.zip

##----------------------------------------------------------##

# Exports
export PATH="$SRC/proton/bin:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_COMPILER_STRING="$($SRC/proton/bin/clang --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"

if ! [ -d "$SRC/proton" ]; then
echo "Proton clang not found! Cloning..."
if ! git clone -q https://github.com/kdrag0n/proton-clang --depth=1 --single-branch $SRC/proton; then
echo "Cloning failed! Aborting..."
exit 1
fi
fi

# General cleanup
make clean
rm -rf *.zip
rm -rf *.log
##----------------------------------------------------------##

# Start build
BUILD_START=$(date +"%s")
blue='\033[0;34m'
cyan='\033[0;36m'
yellow='\033[0;33m'
red='\033[0;31m'
nocol='\033[0m'

# Clean build always lol
echo -e "$red***********************************************"
echo "          STARTING THE ENGINE         "
echo -e "***********************************************$nocol"

echo "**** Kernel defconfig is set to $KERNEL_DEFCONFIG ****"
echo -e "$blue***********************************************"
echo "          BUILDING KAKAROT KERNEL          "
echo -e "***********************************************$nocol"
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

##----------------------------------------------------------##

# Verify Files

echo "**** Verify Image.gz & dtbo.img ****"
ls $PWD/out/arch/arm64/boot/Image.gz
ls $PWD/out/arch/arm64/boot/dtbo.img
ls $PWD/out/arch/arm64/boot/dtb.img

       if ! [ -a "$SRC/out/arch/arm64/boot/Image.gz" ];
          then
              echo -e "$blue***********************************************"
              echo "          BUILD THROWS ERRORS         "
              echo -e "***********************************************$nocol"
              for i in *.log
              do
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

##----------------------------------------------------------##

echo "**** Verifying AnyKernel3 Directory ****"

if [ ! -d "$SRC/AnyKernel3" ];
then
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
zip -r9 "../$FINAL_KERNEL_ZIP" * -x README $FINAL_KERNEL_ZIP

echo -e "$yellow***********************************************"
echo "         Done, here is your sha1         "
echo -e "***********************************************$nocol"
cd ..

sha1sum $FINAL_KERNEL_ZIP

##----------------------------------------------------------##
##----------------------------------------------------------##
##----------------------------------------------------------##

BUILD_END=$(date +"%s")
DIFF=$(($BUILD_END - $BUILD_START))
echo -e "$yellow Build completed in $(($DIFF / 60)) minute(s) and $(($DIFF % 60)) seconds.$nocol"

##----------------------------------------------------------##
##----------------------------------------------------------##
##----------------------------------------------------------##

echo -e "$red***********************************************"
echo "         Uploading to telegram         "
echo -e "***********************************************$nocol"

# Upload Time!!
for i in *.zip
do
curl -F "document=@$i" --form-string "caption=" "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument?chat_id=${CHAT_ID}&parse_mode=HTML"
done

echo -e "$cyan***********************************************"
echo "          All done !!!         "
echo -e "***********************************************$nocol"
rm -rf $ANYKERNEL3_DIR
##----------------------------------------------------------##
##----------------------------------------------------------##
##----------------------------------------------------------##
