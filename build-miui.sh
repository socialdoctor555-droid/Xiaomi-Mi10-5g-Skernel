#!/bin/bash

# Ensure the script exits on error
set -e

TOOLCHAIN_PATH=$HOME/neutron-clang/bin
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
git clone https://github.com/socialdoctor555-droid/AnyKernel3 -b Skernel --single-branch --depth=1 anykernel

# ------------- Building for MIUI -------------


echo "Building for MIUI....."

dts_source=arch/arm64/boot/dts/vendor/qcom

# Backup dts
cp -a ${dts_source} .dts.bak

echo "Downloading Droidspaces non-GKI kernel patches......."
mkdir -p /tmp/droidspaces-patches
curl -fsSL -o /tmp/droidspaces-patches/02.fix_restore_cgroup_file_prefix_handling.patch \
    "https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/resources/kernel-patches/non-GKI/02.fix_restore%20cgroup%20file%20prefix%20handling%20.patch"

echo "Applying Droidspaces non-GKI kernel patches......."
for patch_file in /tmp/droidspaces-patches/*.patch; do
    echo "  -> Applying: $(basename "$patch_file")"
    if ! patch -p1 -N --forward < "$patch_file"; then
        echo "     Note: patch may already be applied or failed to apply cleanly - check manually if the build breaks."
    fi
done

echo "========== Integrating ReSukiSU =========="

KSU_SETUP_URI="https://github.com/ReSukiSU/ReSukiSU/raw/refs/heads/main/kernel/setup.sh"
KSU_SETUP_BRANCH="main"

echo "-- Running ReSukiSU setup..."
curl -LSs --fail --retry 3 "$KSU_SETUP_URI" | bash -s "$KSU_SETUP_BRANCH" || {
    echo "ReSukiSU setup failed!"
    exit 1
}

echo "-- DEBUG: locating init_rc_hook symbol --"
grep -rln "ksu_is_init_rc_hook_enabled\|ksu_init_rc_hook" . --include=*.h --include=*.c || echo "not found anywhere"

echo "-- Exporting required SELinux symbols..."

unstatic() {
    local file="$1"
    local regex="$2"

    if [ -f "$file" ] && grep -q "static $regex" "$file" 2>/dev/null; then
        sed -i "s/static $regex/$regex/" "$file"
        echo "  -> Exported: $regex"
    fi
}

unstatic "security/selinux/selinuxfs.c" "const struct file_operations sel_handle_status_ops"
unstatic "security/selinux/selinuxfs.c" "DEFINE_MUTEX(sel_mutex);"
unstatic "security/selinux/ss/services.c" "struct page \*selinux_status_page;"
unstatic "security/selinux/ss/services.c" "DEFINE_MUTEX(selinux_status_lock);"
unstatic "security/selinux/ss/services.c" "DEFINE_RWLOCK(policy_rwlock);"
unstatic "security/selinux/hooks.c" "struct security_operations selinux_ops"

echo "========== ReSukiSU integration completed =========="

echo "========== Integrating SUSFS =========="

SUSFS_BRANCH="kernel-4.19"
SUSFS_DIR="/tmp/susfs4ksu"

echo "-- Cloning susfs4ksu ($SUSFS_BRANCH)..."
rm -rf "$SUSFS_DIR"
git clone -b "$SUSFS_BRANCH" --single-branch --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git "$SUSFS_DIR"

echo "-- Copying susfs core files into kernel tree..."
cp "$SUSFS_DIR/kernel_patches/fs/susfs.c" fs/
mkdir -p include/linux
cp "$SUSFS_DIR/kernel_patches/include/linux/susfs.h" include/linux/
cp "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" include/linux/ 2>/dev/null || true

echo "-- Applying kernel-side susfs patch (conflicts against our manual hooks are possible)..."
cp "$SUSFS_DIR/kernel_patches/50_add_susfs_in_kernel-4.19.patch" ./susfs_kernel.patch
patch -p1 -N --forward < susfs_kernel.patch || {
    echo "Note: some hunks may have failed against fs/stat.c, fs/exec.c, fs/open.c"
    echo "      (they were already hand-modified for ReSukiSU manual hooks)."
    echo "      Check for *.rej files below:"
    find . -name "*.rej"
}

echo "========== SUSFS integration completed =========="

make $MAKE_ARGS ${DEFCONFIG}

echo "..............Applying Droidspaces required kernel configs......."
./scripts/config --file out/.config \
    --enable CONFIG_NAMESPACES \
    --enable CONFIG_PID_NS \
    --enable CONFIG_UTS_NS \
    --enable CONFIG_SYSVIPC \
    --enable CONFIG_IPC_NS \
    --enable CONFIG_DEVTMPFS

echo "........Resukisu Integration..........."
./scripts/config --file out/.config \
    --enable CONFIG_KSU \
    --enable CONFIG_KSU_MULTI_MANAGER_SUPPORT \
    --enable CONFIG_KPM \
    --enable CONFIG_KSU_MANUAL_HOOK \
    --enable CONFIG_HAVE_SYSCALL_TRACEPOINTS \
    --enable CONFIG_THREAD_INFO_IN_TASK

echo "============= .....Applying Susfs Integration.... =============="
./scripts/config --file out/.config \
    --enable CONFIG_KSU_SUSFS_SUS_PATH \
    --enable CONFIG_KSU_SUSFS_SUS_MOUNT \
    --enable CONFIG_KSU_SUSFS_SUS_KSTAT \
    --enable CONFIG_KSU_SUSFS_SPOOF_UNAME \
    --enable CONFIG_KSU_SUSFS_ENABLE_LOG \
    --enable CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    --enable CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    --enable CONFIG_KSU_SUSFS_OPEN_REDIRECT \
    --enable CONFIG_KSU_SUSFS_SUS_MAP \
    --enable CONFIG_KSU_SUSFS_TRY_UMOUNT \

echo "Resolving config dependencies......."
make $MAKE_ARGS olddefconfig

echo "Compile is beginning..."
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
