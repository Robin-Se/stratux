#!/bin/bash

# To run this, make sure that this is installed:
# sudo apt install --yes qemu-user-static qemu-system-arm
# Run this script as root.
# Run with argument "dev" to not clone the stratux repository from remote, but instead copy this current local checkout onto the image
set -x
BASE_IMAGE_URL="http://downloads.raspberrypi.org/raspios_lite_armhf/images/raspios_lite_armhf-2020-05-28/2020-05-27-raspios-buster-lite-armhf.zip"
ZIPNAME="2020-05-27-raspios-buster-lite-armhf.zip"
IMGNAME="${ZIPNAME%.*}.img"
TMPDIR="$HOME/stratux-tmp"

die() {
    echo $1
    exit 1
}

if [ "$#" -ne 2 ]; then
    die "Usage: " $0 " dev|prod branch"
fi

# cd to script directory
cd "$(dirname "$0")"
SRCDIR="$(realpath $(pwd)/..)"
mkdir -p $TMPDIR
cd $TMPDIR

# Download/extract image
wget -c $BASE_IMAGE_URL || die "Download failed"
unzip $ZIPNAME || die "Extracting image failed"

# Check where in the image the root partition begins:
sector=$(fdisk -l $IMGNAME | grep Linux | awk -F ' ' '{print $2}')
partoffset=$(( 512*sector ))
bootoffset=$(fdisk -l $IMGNAME | grep W95 | awk -F ' ' '{print $2}')
bootoffset=$(( 512*bootoffset ))
sizelimit=$(fdisk -l $IMGNAME | grep W95 | awk -F ' ' '{print $4}')
sizelimit=$(( 512*sizelimit ))

# Original image partition is too small to hold our stuff.. resize it to 2.5gb
# Append one GB and truncate to size
#truncate -s 2600M $IMGNAME
qemu-img resize $IMGNAME 2500M || die "Image resize failed"
lo=$(losetup -f)
losetup $lo $IMGNAME
partprobe $lo
e2fsck -f ${lo}p2
fdisk $lo <<EOF
p
d
2
n
p
2
$sector

p
w
EOF
partprobe $lo || die "Partprobe failed failed"
resize2fs -p ${lo}p2 || die "FS resize failed"
losetup -d $lo || die "Loop device setup failed"




# Mount image locally, clone our repo, install packages..
mkdir -p mnt
mount -t ext4 -o offset=$partoffset $IMGNAME mnt/ || die "root-mount failed"
mount -t vfat -o offset=$bootoffset,sizelimit=$sizelimit $IMGNAME mnt/boot || die "boot-mount failed"
cp $(which qemu-arm-static) mnt/usr/bin || die "Failed to copy qemu-arm-static into image"

# Download and extract go in the chroot
cd mnt/root
wget https://dl.google.com/go/go1.12.4.linux-armv6l.tar.gz || die "Go download failed"
tar xzf go1.12.4.linux-armv6l.tar.gz
rm go1.12.4.linux-armv6l.tar.gz

if [ "$1" == "dev" ]; then
    rsync -av --progress --exclude=ogn/esp-idf $SRCDIR ./
    cd stratux && git checkout $2 && cd ..
else
    git clone --recursive -b $2 https://github.com/b3nn0/stratux.git
fi
cd ../..

# Now download a specific kernel to run raspbian images in qemu and boot it..
chroot mnt qemu-arm-static /bin/bash -c /root/stratux/image/mk_europe_edition_device_setup.sh
mkdir out


# Copy the selfupdate file out of there..
cp mnt/root/stratux/work/*.sh out
rm -r mnt/root/stratux/work

umount mnt/boot
umount mnt

mv $IMGNAME out/

cd $SRCDIR
outname="stratux-$(git describe --tags --abbrev=0)-$(git log -n 1 --pretty=%H | cut -c 1-8).img"
cd $TMPDIR/out
mv $IMGNAME $outname
zip $outname.zip $outname


echo "Final image has been placed into $TMPDIR/out. Please install and test the image."
