#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error.
# The return value of a pipeline is the status of the last command to exit with a non-zero status.
set -euo pipefail

# --- Configuration ---
# Allow overriding from command line, e.g., ./build.sh 6.1.0 23.05.0
readonly KERNEL_NAME="${1:-6.16.0-rc1}"
readonly OPENWRT_RELEASE="${2:-24.10.1}"

# Static Configuration
readonly BUILD_DIR="${PWD}/build"
readonly BOOT_SIZE_MB=256
readonly ROOT_SIZE_MB=4096
readonly SKIP_MB=16 # Space reserved for bootloader

readonly IMAGE_NAME="openwrt-${OPENWRT_RELEASE}-${KERNEL_NAME}-e52c.img"
readonly OPENWRT_ROOTFS="https://downloads.openwrt.org/releases/${OPENWRT_RELEASE}/targets/armsr/armv8/openwrt-${OPENWRT_RELEASE}-armsr-armv8-rootfs.tar.gz"
readonly TARGET_IMG="${BUILD_DIR}/${IMAGE_NAME}"

readonly ROOT_DIR="${BUILD_DIR}/root"
readonly ROOT_IMG="${BUILD_DIR}/root.img"
readonly BOOT_DIR="${BUILD_DIR}/boot"
readonly BOOT_IMG="${BUILD_DIR}/boot.img"

readonly KERNEL_BUILD_DIR="${BUILD_DIR}/linux-build"
readonly FIRMWARE_DIR="${BUILD_DIR}/linux-firmware"
# This logic converts versions like '6.16.0-rc1' to '6.16-rc1' for the download URL.
readonly KERNEL_TARBALL_VERSION=$(echo "$KERNEL_NAME" | sed 's/\.0-rc/-rc/')
readonly KERNEL_URL="https://git.kernel.org/torvalds/t/linux-${KERNEL_TARBALL_VERSION}.tar.gz"
readonly FIRMWARE_GIT_URL="git://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git"


# Bootloader offsets in 512-byte sectors
readonly IDBLOADER_OFFSET=64
readonly UBOOT_OFFSET=16384

# --- Cross-compilation setup ---
MAKE_ARGS=""
if [ "$(uname -m)" != "aarch64" ]; then
    echo "--- Host is not aarch64, enabling cross-compilation for arm64 ---"
    MAKE_ARGS="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"
fi

# --- Functions ---

die() {
    echo "ERROR: $1" >&2
    exit 1
}

check_dependencies() {
    local missing=0
    local deps="curl tar dd parted mkfs.ext4 mkfs.btrfs depmod truncate sed git make gcc bison flex mkimage"
    
    if [[ -n "$MAKE_ARGS" ]]; then
        deps="$deps aarch64-linux-gnu-gcc"
    fi

    for cmd in $deps; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Error: Required command '$cmd' is not installed." >&2
            missing=1
        fi
    done

    if [ "$missing" -ne 0 ]; then
        die "Please install missing dependencies."
    fi
}

prepare_workspace() {
    echo "--- Preparing workspace ---"
    # Keep firmware clone to avoid re-downloading
    rm -rf "$KERNEL_BUILD_DIR" "$ROOT_DIR" "$BOOT_DIR" "$ROOT_IMG" "$BOOT_IMG" "$TARGET_IMG"
    mkdir -p "$BOOT_DIR" "$ROOT_DIR"
}

build_kernel() {
    echo "--- Building kernel ---"
    if [ ! -d "$KERNEL_BUILD_DIR" ]; then
        mkdir -p "$KERNEL_BUILD_DIR"
        echo "Downloading and extracting kernel source..."
        curl -L "$KERNEL_URL" | tar zx --strip-components=1 -C "$KERNEL_BUILD_DIR"
    fi

    echo "Configuring kernel..."
    cp "kernel/config" "${KERNEL_BUILD_DIR}/.config"
    make -C "$KERNEL_BUILD_DIR" $MAKE_ARGS olddefconfig

    echo "Building kernel (this may take a while)..."
    make -C "$KERNEL_BUILD_DIR" -j"$(nproc)" $MAKE_ARGS all
}

download_firmware() {
    echo "--- Downloading firmware ---"
    if [ ! -d "$FIRMWARE_DIR" ]; then
        git clone --depth 1 "$FIRMWARE_GIT_URL" "$FIRMWARE_DIR"
    else
        echo "Firmware directory already exists, skipping download."
    fi
}

build_boot_partition() {
    echo "--- Building boot partition ---"
    cp "${KERNEL_BUILD_DIR}/arch/arm64/boot/Image" "${BOOT_DIR}/vmlinuz"

    if [ ! -d "initrd" ]; then
        die "'initrd/' directory not found. Please create it to build the initrd."
    fi

    echo "Creating initrd from 'initrd/' directory..."
    local temp_initrd_gz="${BUILD_DIR}/initrd.img.gz"
    (cd initrd && find . | cpio -o -H newc | gzip -9 > "$temp_initrd_gz")

    echo "Creating uInitrd from custom initrd..."
    mkimage -A arm64 -O linux -T ramdisk -C gzip -n "Initial Ramdisk" \
        -d "$temp_initrd_gz" "${BOOT_DIR}/uInitrd"

    echo "Copying device tree..."
    mkdir -p "${BOOT_DIR}/rockchip"
    cp -a "${KERNEL_BUILD_DIR}/arch/arm64/boot/dts/rockchip/"*.dtb "${BOOT_DIR}/rockchip/"

    cp -a boot_files/* "${BOOT_DIR}"

    sed -i \
        -e 's?^rootdev=.*?rootdev=LABEL=ROOTFS?' \
        -e 's?^fdtfile=.*?fdtfile=rockchip/rk3582-radxa-e52c.dtb?' \
        "${BOOT_DIR}/armbianEnv.txt"

    echo "Creating boot partition image..."
    truncate -s "${BOOT_SIZE_MB}M" "$BOOT_IMG"
    mkfs.ext4 -L BOOTFS -d "$BOOT_DIR" "$BOOT_IMG"
}

build_root_partition() {
    echo "--- Building root partition ---"
    echo "Downloading and extracting OpenWrt rootfs..."
    curl -L "$OPENWRT_ROOTFS" | tar zx -C "$ROOT_DIR"

    echo "LABEL=ROOTFS / btrfs defaults,compress=zstd:6 0 1" >> "${ROOT_DIR}/etc/fstab"
    echo "LABEL=BOOTFS /boot ext4 noatime,errors=remount-ro 0 2" >> "${ROOT_DIR}/etc/fstab"

    cat > "${ROOT_DIR}/etc/inittab" <<EOF
::sysinit:/etc/init.d/rcS S boot
::shutdown:/etc/init.d/rcS K shutdown
tty1::askfirst:/usr/libexec/login.sh
ttyS2::askfirst:/usr/libexec/login.sh
EOF

    cat > "${ROOT_DIR}/etc/config/network" <<EOF
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'
config interface 'lan'
	option device 'eth1'
	option proto 'static'
	option ipaddr '192.168.1.1'
	option netmask '255.255.255.0'
config interface 'wan'
	option device 'eth0'
	option proto 'dhcp'
EOF

    echo "Installing kernel modules..."
    make -C "$KERNEL_BUILD_DIR" $MAKE_ARGS modules_install INSTALL_MOD_PATH="$ROOT_DIR"

    echo "Installing firmware..."
    mkdir -p "${ROOT_DIR}/lib/firmware"
    git -C "$FIRMWARE_DIR" archive HEAD | tar -x -C "${ROOT_DIR}/lib/firmware/"

    depmod -ae -F "${KERNEL_BUILD_DIR}/System.map" -b "$ROOT_DIR" "$KERNEL_NAME"
    # Remove symlinks to the build host's kernel source directory
    rm -f "${ROOT_DIR}/lib/modules/${KERNEL_NAME}"/build
    rm -f "${ROOT_DIR}/lib/modules/${KERNEL_NAME}"/source

    echo "Creating root partition image..."
    truncate -s "${ROOT_SIZE_MB}M" "$ROOT_IMG"
    mkfs.btrfs -r "$ROOT_DIR" --compress zstd:6 -L ROOTFS "$ROOT_IMG"
}

assemble_image() {
    echo "--- Assembling final image ---"
    local image_size_mb=$((SKIP_MB + BOOT_SIZE_MB + ROOT_SIZE_MB + 1))
    local boot_start_sector=$((SKIP_MB * 1024 * 1024 / 512))
    local boot_size_sectors=$((BOOT_SIZE_MB * 1024 * 1024 / 512))
    local root_start_sector=$((boot_start_sector + boot_size_sectors))
    local boot_end_sector=$((root_start_sector - 1))

    echo "Creating complete image file..."
    truncate -s "${image_size_mb}M" "$TARGET_IMG"

    parted -s "$TARGET_IMG" -- \
        mklabel gpt \
        mkpart boot ext4 "${boot_start_sector}s" "${boot_end_sector}s" \
        mkpart root btrfs "${root_start_sector}s" "100%"

    echo "Copying boot partition data..."
    dd if="$BOOT_IMG" of="$TARGET_IMG" seek="$boot_start_sector" bs=512 conv=notrunc status=progress
    echo "Copying root partition data..."
    dd if="$ROOT_IMG" of="$TARGET_IMG" seek="$root_start_sector" bs=512 conv=notrunc status=progress

    echo "Writing bootloader..."
    dd if="bootloader/idbloader.img" of="$TARGET_IMG" conv=fsync,notrunc bs=512 seek="${IDBLOADER_OFFSET}"
    dd if="bootloader/u-boot.itb" of="$TARGET_IMG" conv=fsync,notrunc bs=512 seek="${UBOOT_OFFSET}"
}

# --- Main Logic ---
main() {
    check_dependencies
    prepare_workspace
    build_kernel
    download_firmware
    build_boot_partition
    build_root_partition
    assemble_image
    echo "Image creation complete: ${TARGET_IMG}"
}

main "$@"
