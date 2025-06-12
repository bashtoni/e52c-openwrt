#!/bin/bash -e

BUILD_DIR="./build"
BOOT_SIZE_MB=256
ROOT_SIZE_MB=1024
SKIP_MB=16
OPENWRT_RELEASE="24.10.1"
IMAGE_NAME="openwrt-${OPENWRT_RELEASE}-e52c.img"
OPENWRT_ROOTFS="https://downloads.openwrt.org/releases/24.10.1/targets/armsr/armv8/openwrt-${OPENWRT_RELEASE}-armsr-armv8-rootfs.tar.gz"
KERNEL_FS="https://github.com/breakingbadboy/OpenWrt/releases/download/kernel_rk3588/5.10.160-rk3588-flippy-2412a.tar.gz"
TARGET_IMG="build/openwrt-${OPENWRT_RELEASE}-e52c.img"
ROOT_DIR="${BUILD_DIR}/root"
ROOT_IMG="${BUILD_DIR}/root.img"
BOOT_DIR="${BUILD_DIR}/boot"
BOOT_IMG="${BUILD_DIR}/boot.img"
TMP_DIR="${BUILD_DIR}/tmp"


KERNEL_NAME=$(basename $KERNEL_FS .tar.gz)
IMAGE_SIZE=$((SKIP_MB + BOOT_SIZE_MB + ROOT_SIZE_MB + 1))
DTB_TARBALL=${TMP_DIR}/${KERNEL_NAME}/dtb-rockchip-${KERNEL_NAME}.tar.gz
BOOT_TARBALL=${TMP_DIR}/${KERNEL_NAME}/boot-${KERNEL_NAME}.tar.gz
MODULE_TARBALL=${TMP_DIR}/${KERNEL_NAME}/modules-${KERNEL_NAME}.tar.gz

# Calculate sizes in bytes and sectors (512 bytes each)
BOOT_SIZE_BYTES=$((BOOT_SIZE_MB * 1024 * 1024))
ROOT_SIZE_BYTES=$((ROOT_SIZE_MB * 1024 * 1024))
BOOT_SIZE_SECTORS=$((BOOT_SIZE_BYTES / 512))
ROOT_SIZE_SECTORS=$((ROOT_SIZE_BYTES / 512))
# MBR size (1 sector = 512 bytes)
MBR_SIZE=512
# Calculate partition start positions (in sectors)
BOOT_START_SECTOR=$((SKIP_MB * 1024 * 1024 / 512))
ROOT_START_SECTOR=$((BOOT_START_SECTOR + BOOT_SIZE_SECTORS))
BOOT_END_SECTOR=$((ROOT_START_SECTOR - 1))


# Clean up any old files
rm -rf $BUILD_DIR

# Boot directory
mkdir -p $BOOT_DIR
mkdir -p $TMP_DIR
curl -L $KERNEL_FS | tar zx --warning=no-unknown-keyword -C $TMP_DIR
tar zxvf $BOOT_TARBALL -C ${BOOT_DIR}
ln -s uInitrd-${KERNEL_NAME} ${BOOT_DIR}/uInitrd
ln -s vmlinuz-${KERNEL_NAME} ${BOOT_DIR}/Image
mkdir -p ${BOOT_DIR}/dtb/rockchip
tar zxf $DTB_TARBALL -C ${BOOT_DIR}/dtb/rockchip
cp -a boot_files/* ${BOOT_DIR}
sed -i -e 's?^rootdev=.*?rootdev=LABEL=ROOT?' ${BOOT_DIR}/armbianEnv.txt
## Make the filesystem image
echo "Creating boot partition image..."
dd if=/dev/zero of="$BOOT_IMG" bs=1M count="$BOOT_SIZE_MB" status=progress
mkfs.ext4 -L BOOT -d $BOOT_DIR $BOOT_IMG

# Root directory
mkdir -p $ROOT_DIR
curl -L $OPENWRT_ROOTFS | tar zx -C $ROOT_DIR
## Mount filesystems
#echo 'LABEL=ROOT / btrfs defaults,compress=zstd:6,subvol=etc 0 1' >> ${ROOT_DIR}/etc/fstab
echo 'LABEL=ROOT / btrfs defaults,compress=zstd:6 0 1' >> ${ROOT_DIR}/etc/fstab
echo 'LABEL=BOOT /boot ext4 noatime,errors=remount-ro 0 2'
## Update getty for USB debugging
cat > ${ROOT_DIR}/etc/inittab <<EOF
::sysinit:/etc/init.d/rcS S boot
::shutdown:/etc/init.d/rcS K shutdown
tty1::askfirst:/usr/libexec/login.sh
ttyS2::askfirst:/usr/libexec/login.sh
ttyFIQ0::askfirst:/usr/libexec/login.sh
EOF
## Add kernel modules
tar zxf $MODULE_TARBALL -C ${ROOT_DIR}/lib/modules
## Add firmware files
cp -a firmware/* ${ROOT_DIR}/lib/firmware
## Make the filesystem image
echo "Creating root partition image..."
dd if=/dev/zero of="$ROOT_IMG" bs=1M count="$ROOT_SIZE_MB" status=progress
#mkfs.btrfs -r $ROOT_DIR --compress zstd:6 -L "ROOT" --subvol etc $ROOT_IMG
mkfs.btrfs -r $ROOT_DIR --compress zstd:6 -L ROOT $ROOT_IMG



# Create complete image
echo "Creating complete image file"
dd if=/dev/zero of=${TARGET_IMG} bs=1M count=${IMAGE_SIZE}
parted -s "${TARGET_IMG}" -- \
  mklabel gpt \
  mkpart boot ext4 "${BOOT_START_SECTOR}s" "${BOOT_END_SECTOR}s" \
  mkpart root btrfs "${ROOT_START_SECTOR}s" "100%"

# Copy filesystem images into the partitions
echo "Copying boot partition data..."
dd if="$BOOT_IMG" of="$TARGET_IMG" seek="$BOOT_START_SECTOR" bs=512 conv=notrunc status=progress
echo "Copying root partition data..."
dd if="$ROOT_IMG" of="$TARGET_IMG" seek="$ROOT_START_SECTOR" bs=512 conv=notrunc status=progress

# Write the bootloader
echo "Writing bootloader..."
dd if=bootloader/idbloader.img of=${TARGET_IMG} conv=fsync,notrunc bs=512 seek=64
dd if=bootloader/u-boot.itb of=${TARGET_IMG} conv=fsync,notrunc bs=512 seek=16384

echo "Image creation complete: ${TARGET_IMG}"
