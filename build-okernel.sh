#!/bin/bash
# Standalone MIUI kernel build script.
# Only needs: TARGET_DEVICE / DEFCONFIG overridable via env; everything else
# is self-contained so it no longer depends on state from earlier CI steps.

set -euo pipefail

echo "Compile is beginning..."

# ---------------- Toolchain & env setup ----------------
TOOLCHAIN_PATH="${TOOLCHAIN_PATH:-$HOME/neutron-clang/bin}"
export PATH="$TOOLCHAIN_PATH:/usr/lib/ccache:$PATH"

export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache_mikernel}"
export CC="clang"
export CXX="clang++"
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime

DEFCONFIG="${DEFCONFIG:-vendor/umi_defconfig}"
dts_source="${dts_source:-arch/arm64/boot/dts/vendor/qcom}"

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

echo "TOOLCHAIN_PATH: [$TOOLCHAIN_PATH]"
echo "CCACHE_DIR: [$CCACHE_DIR]"
echo "DEFCONFIG: [$DEFCONFIG]"

# ---------------- Sanity check: toolchain resolvable ----------------
if ! command -v clang >/dev/null 2>&1; then
  echo "ERROR: clang not found on PATH. Check TOOLCHAIN_PATH." >&2
  exit 1
fi
if ! command -v ld.lld >/dev/null 2>&1; then
  echo "ERROR: ld.lld not found on PATH. Check TOOLCHAIN_PATH." >&2
  exit 1
fi

# ---------------- Config generation ----------------
if [ ! -f "out/.config" ]; then
  echo "Generating defconfig [$DEFCONFIG]......."
  make $MAKE_ARGS "$DEFCONFIG"
else
  echo "Existing out/.config found, skipping defconfig generation."
fi

# ---------------- Build ----------------
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
if [ -d ".dts.bak" ]; then
  rm -rf "${dts_source}"
  mv .dts.bak "${dts_source}"
else
  echo "WARNING: .dts.bak not found, skipping dts restore."
fi

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
ZIP_FILENAME=OKernel_v1_HOS_Mi10.zip
zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore 'out/*' './*.zip'
mv "$ZIP_FILENAME" ../
cd ..
echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
