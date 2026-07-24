#!/bin/bash

# Ensure the script exits on error
set -e

TOOLCHAIN_PATH=$HOME/zyc-clang/bin
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
TARGET_DEVICE=umi

if [ ! -d $TOOLCHAIN_PATH ]; then
    echo "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist."
    echo "Please ensure the toolchain is there, or change TOOLCHAIN_PATH in the script to your toolchain path."
    exit 1
fi

echo "TOOLCHAIN_PATH: [$TOOLCHAIN_PATH]"
export PATH="$TOOLCHAIN_PATH:$PATH"

if ! command -v aarch64-linux-gnu-ld >/dev/null 2>&1; then
    echo "[aarch64-linux-gnu-ld] does not exist, please check your environment."
    exit 1
fi

if ! command -v arm-linux-gnueabi-ld >/dev/null 2>&1; then
    echo "[arm-linux-gnueabi-ld] does not exist, please check your environment."
    exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "[clang] does not exist, please check your environment."
    exit 1
fi


# Enable ccache for speed up compiling 
export CCACHE_DIR="$HOME/.cache/ccache_mikernel" 
export CC="clang"
export CXX="clang++"
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime
echo "CCACHE_DIR: [$CCACHE_DIR]"


MAKE_ARGS="ARCH=arm64 \
           SUBARCH=arm64 \
           O=out \
           CC=clang \
           HOSTCC=clang \
           CLANG_TRIPLE=aarch64-linux-gnu- \
           CROSS_COMPILE=aarch64-linux-gnu- \
           CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
           CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
           LD=ld.lld \
           AR=llvm-ar \
           NM=llvm-nm \
           OBJCOPY=llvm-objcopy \
           OBJDUMP=llvm-objdump \
           STRIP=llvm-strip"


if [ "$1" == "j1" ]; then
    make $MAKE_ARGS -j1
    exit
fi

if [ "$1" == "continue" ]; then
    make $MAKE_ARGS -j$(nproc)
    exit
fi

DEFCONFIG="vendor/umi_defconfig"

if [ ! -f "arch/arm64/configs/${DEFCONFIG}" ]; then
    echo "No target device [${TARGET_DEVICE}] found."
    echo "Missing: arch/arm64/configs/${DEFCONFIG}"
    echo "Available defconfigs:"
    ls arch/arm64/configs/vendor/*_defconfig
    exit 1
fi

# Check clang is existing.
echo "[clang --version]:"
clang --version

echo ".........TARGET_DEVICE: Xiaomi Mi 10 5g UMI......"

echo "Cleaning..."

rm -rf out/
rm -rf anykernel/

echo "Clone AnyKernel3 for packing kernel (repo: https://github.com/AstideLabs/AnyKernel3)"
git clone https://github.com/AstideLabs/AnyKernel3 -b master --single-branch --depth=1 anykernel

# ------------- Building for MIUI -------------


echo "Building for MIUI....."

dts_source=arch/arm64/boot/dts/vendor/qcom

# Backup dts
cp -a ${dts_source} .dts.bak

echo "Downloading Droidspaces non-GKI kernel patches......."
mkdir -p /tmp/droidspaces-patches
curl -fsSL -o /tmp/droidspaces-patches/01.fix_kernel_panic_in_xt_qtaguid.patch \
    "https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/resources/kernel-patches/non-GKI/01.fix_kernel_panic_in_xt_qtaguid.patch"
curl -fsSL -o "/tmp/droidspaces-patches/02.fix_restore_cgroup_file_prefix_handling.patch" \
    "https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/resources/kernel-patches/non-GKI/02.fix_restore%20cgroup%20file%20prefix%20handling%20.patch"

echo "Applying Droidspaces non-GKI kernel patches......."
for patch_file in /tmp/droidspaces-patches/*.patch; do
    echo "  -> Applying: $(basename "$patch_file")"
    if ! patch -p1 -N --forward < "$patch_file"; then
        echo "     Note: patch may already be applied or failed to apply cleanly - check manually if the build breaks."
    fi
done

echo "Integrating KernelSU (EmanuelCN)..."

git clone --depth=1 \
    https://github.com/EmanuelCN/KernelSU.git \
    KernelSU

echo "..........KernelSu setup done............."

make $MAKE_ARGS ${DEFCONFIG}

echo "..............Applying Droidspaces required kernel configs......."
./scripts/config --file out/.config \
    --enable CONFIG_NAMESPACES \
    --enable CONFIG_PID_NS \
    --enable CONFIG_UTS_NS \
    --enable CONFIG_SYSVIPC \
    --enable CONFIG_IPC_NS \
    --enable CONFIG_DEVTMPFS

echo "......Applying KernelSU configs......."
./scripts/config --file out/.config \
    --enable CONFIG_KSU \
    --enable CONFIG_KPROBES \
    --enable CONFIG_KALLSYMS \
    --enable CONFIG_KALLSYMS_ALL \
    --enable CONFIG_OVERLAY_FS
echo "Resolving config dependencies......."
make $MAKE_ARGS olddefconfig

echo "===== KernelSU config ====="
grep CONFIG_KSU out/.config
echo "==========================="

echo "Compile is beginning at the core......."
make $MAKE_ARGS -j"$(nproc)"

if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "The file [out/arch/arm64/boot/Image] exists. MIUI Build successfully."
else
    echo "The file [out/arch/arm64/boot/Image] does not exist. Seems MIUI build failed."
    exit 1
fi

echo "Generating [out/arch/arm64/boot/dtb]......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb


# Restore modified dts
rm -rf ${dts_source}
mv .dts.bak ${dts_source}

rm -rf anykernel/kernels/
mkdir -p anykernel/kernels/miui/

echo ".............Exporting the required images............."

cp out/arch/arm64/boot/Image anykernel/kernels/miui/
cp out/arch/arm64/boot/dtb anykernel/kernels/miui/
cp out/arch/arm64/boot/dtbo.img anykernel/kernels/miui/

echo "Build for MIUI finished."

# ------------- End of Building for MIUI -------------
#  If you don't need MIUI you can comment out the above block [Building for MIUI]


cd anykernel 

ZIP_FILENAME=Skernelv1.zip

zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip

mv $ZIP_FILENAME ../

cd ..

echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
