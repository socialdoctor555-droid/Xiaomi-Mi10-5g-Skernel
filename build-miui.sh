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


# Rekernel integration selector.
# NOTE: the actual Rekernel patch download/apply now happens in the GitHub
# Actions workflow (see the "Download :: Rekernel Patches" step). This script
# only needs to know whether it was selected, to enable the matching config.
export REKERNEL_SELECTOR="${REKERNEL_SELECTOR:-none}"

# Baseband Guard integration selector.
# NOTE: the Baseband Guard setup.sh download/run now happens in the GitHub
# Actions workflow (see the "Download :: Baseband Guard Setup" step). This
# script only needs to know whether it was selected, to finish the LSM wiring.
export BBG_SELECTOR="${BBG_SELECTOR:-none}"


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

MAIN_DEFCONFIG="arch/arm64/configs/${DEFCONFIG}"

# Check clang is existing.
echo "[clang --version]:"
clang --version

echo ".........TARGET_DEVICE: Xiaomi Mi 10 5g UMI......"

echo "Cleaning..."

rm -rf out/

# NOTE: AnyKernel3 is cloned by the "Download :: AnyKernel3" workflow step
# before this script runs, so it's not re-fetched here.
if [ ! -d anykernel ]; then
    echo "-- Fatal: anykernel/ directory not found. It should have been cloned by the workflow's AnyKernel3 download step."
    exit 1
fi

# ------------- Building for MIUI -------------


echo "Building for MIUI....."

dts_source=arch/arm64/boot/dts/vendor/qcom

# Backup dts
cp -a ${dts_source} .dts.bak

# NOTE: patches are fetched by the "Download :: Droidspaces Non-GKI Patches"
# workflow step; this script only applies what's already on disk.
DROIDSPACES_PATCH_DIR="${DROIDSPACES_PATCH_DIR:-/tmp/droidspaces-patches}"

echo "Applying Droidspaces non-GKI kernel patches......."
for patch_file in "$DROIDSPACES_PATCH_DIR"/*.patch; do
    echo "  -> Applying: $(basename "$patch_file")"
    if ! patch -p1 -N --forward < "$patch_file"; then
        echo "     Note: patch may already be applied or failed to apply cleanly - check manually if the build breaks."
    fi
done

echo "========== Integrating ReSukiSU =========="

# NOTE: ReSukiSU is fetched and set up by the "Download :: ReSukiSU (KernelSU)
# Setup" workflow step, which runs against this same checked-out source tree
# before this script executes. From here we just finish the integration.

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

# NOTE: susfs4ksu is cloned by the "Download :: SUSFS4KSU Source" workflow
# step. This script only copies files from that clone and applies the patch.
SUSFS_DIR="${SUSFS_DIR:-/tmp/susfs4ksu}"

if [ ! -d "$SUSFS_DIR" ]; then
    echo "-- Fatal: $SUSFS_DIR not found. It should have been cloned by the workflow's SUSFS4KSU download step."
    exit 1
fi

echo "-- Copying susfs core files into kernel tree..."
cp "$SUSFS_DIR/kernel_patches/fs/susfs.c" fs/
mkdir -p include/linux
cp "$SUSFS_DIR/kernel_patches/include/linux/susfs.h" include/linux/
cp "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" include/linux/ 2>/dev/null || true

echo "-- Applying kernel-side susfs patch (conflicts against our manual hooks are possible)..."
cp "$SUSFS_DIR/kernel_patches/50_add_susfs_in_kernel-4.19.patch" ./susfs_kernel.patch
patch_status=0
patch -p1 -N --forward < susfs_kernel.patch || patch_status=$?

rej_files=$(find . -name "*.rej")
if [ -n "$rej_files" ] || [ "$patch_status" -ne 0 ]; then
    echo "-- Fatal: the susfs kernel patch did not apply cleanly."
    echo "   This usually happens because ReSukiSU's manual-hook setup already"
    echo "   hand-modified files (commonly fs/stat.c, fs/exec.c, fs/open.c,"
    echo "   include/linux/fs.h) that the patch also expects to touch, so the"
    echo "   hunks touching those files get rejected while unrelated hunks"
    echo "   (e.g. fs/proc/task_mmu.c) still apply -- leaving code that"
    echo "   *references* susfs macros/flags without their *definitions*,"
    echo "   which only surfaces as a compile error much later."
    echo ""
    echo "   Rejected hunks (*.rej):"
    for f in $rej_files; do
        echo "   ---------------------------------------------------------------"
        echo "   $f"
        echo "   ---------------------------------------------------------------"
        cat "$f"
    done
    echo ""
    echo "   Manually resolve these hunks against the ReSukiSU-modified files"
    echo "   above (the source is at $SUSFS_DIR/kernel_patches) and re-run."
    exit 1
fi

echo "-- Verifying susfs macros used in the tree are actually defined..."
missing_macro=0
for macro in $(grep -rhoE 'INODE_STATE_[A-Z_]+' --include=*.c --include=*.h . | sort -u); do
    if ! grep -rq "define[[:space:]]\+$macro" --include=*.h .; then
        echo "-- Fatal: '$macro' is referenced in the tree but never #define'd."
        missing_macro=1
    fi
done
if [ "$missing_macro" -ne 0 ]; then
    echo "   One or more susfs inode-state flags are used without a definition"
    echo "   (see fatal lines above). This is the same partial-patch-application"
    echo "   issue described earlier -- check include/linux/susfs_def.h and"
    echo "   include/linux/fs.h against $SUSFS_DIR/kernel_patches for the"
    echo "   missing #define hunk."
    exit 1
fi

echo "========== SUSFS integration completed =========="

case "$REKERNEL_SELECTOR" in
    rekernel)
        # NOTE: the Rekernel patches themselves are downloaded and applied by
        # the "Download :: Rekernel Patches" workflow step (conditional on the
        # same selector). Here we just enable the matching kernel config.
        echo "-- Rekernel selected, enabling CONFIG_REKERNEL..."
        echo "CONFIG_REKERNEL=y" >> $MAIN_DEFCONFIG
        ;;
    none|"")
        echo "-- Rekernel is not selected."
        ;;
    *)
        echo "- Invalid REKERNEL_SELECTOR: $REKERNEL_SELECTOR. Valid options: rekernel, none."
        exit 1
        ;;
esac

echo "========== Rekernel integration completed =========="

case "$BBG_SELECTOR" in
    bbg)
        # NOTE: Baseband Guard's setup.sh is downloaded and run by the
        # "Download :: Baseband Guard Setup" workflow step (conditional on the
        # same selector). Here we just finish the config/LSM/objsec wiring.
        echo "-- Baseband Guard selected, enabling CONFIG_BBG..."
        echo "CONFIG_BBG=y" >> "$MAIN_DEFCONFIG"

        # Check and configure LSM Hooks
        if grep -q "#define DEFINE_LSM(lsm)" "include/linux/lsm_hooks.h" 2>/dev/null; then
            if grep -q "^CONFIG_LSM=" "$MAIN_DEFCONFIG"; then
                sed -i 's/^\(CONFIG_LSM=".*\)"/\1,baseband_guard"/' "$MAIN_DEFCONFIG"
                echo "-- Appended baseband_guard to existing CONFIG_LSM."
            else
                echo 'CONFIG_LSM="lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf,baseband_guard"' >> "$MAIN_DEFCONFIG"
                echo "-- Added default CONFIG_LSM with baseband_guard."
            fi
        fi

        # Check and remove duplicate task_security_struct
        if grep -q "struct[[:space:]]\+task_security_struct[[:space:]]\+\*selinux_cred" "security/selinux/include/objsec.h" 2>/dev/null; then
            echo "-- Removing duplicate task_security_struct definition..."
            sed -i '/static inline struct task_security_struct \*selinux_cred/,/[[:space:]]*}/d' security/baseband-guard/tracing/tracing.c
        fi
        ;;
    none|"")
        echo "-- Baseband Guard is not selected."
        ;;
    *)
        echo "- Invalid BBG_SELECTOR: $BBG_SELECTOR. Valid options: bbg, none."
        exit 1
        ;;
esac

echo "========== Baseband Guard integration completed =========="

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
    --enable CONFIG_KSU_SUSFS \
    --enable CONFIG_KSU_SUSFS_SUS_PATH \
    --enable CONFIG_KSU_SUSFS_SUS_MOUNT \
    --enable CONFIG_KSU_SUSFS_SUS_KSTAT \
    --enable CONFIG_KSU_SUSFS_SPOOF_UNAME \
    --enable CONFIG_KSU_SUSFS_ENABLE_LOG \
    --enable CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    --enable CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    --enable CONFIG_KSU_SUSFS_OPEN_REDIRECT \
    --enable CONFIG_KSU_SUSFS_SUS_MAP \
    --enable CONFIG_KSU_SUSFS_TRY_UMOUNT

echo "Resolving config dependencies......."
make $MAKE_ARGS olddefconfig

echo "-- Verifying CONFIG_KSU_SUSFS survived olddefconfig..."
if ! grep -q "^CONFIG_KSU_SUSFS=y$" out/.config; then
    echo "-- Fatal: CONFIG_KSU_SUSFS was NOT enabled after olddefconfig."
    echo "   This means SuSFS_SUS_* sub-options were silently dropped due to an"
    echo "   unmet Kconfig dependency (missing 'depends on' target, or the SUSFS"
    echo "   patch didn't apply the Kconfig hunk that defines KSU_SUSFS at all)."
    echo "   Check: grep -n 'KSU_SUSFS' security/selinux -r drivers/ 2>/dev/null | head -30"
    exit 1
fi
echo "-- OK: CONFIG_KSU_SUSFS=y confirmed in out/.config"

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
