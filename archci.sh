#!/bin/bash
set -e

PATH="/usr/lib/archci/node_modules/.bin:$PATH"
SRCDIR=$(realpath "$1")
TRGDIR=$(realpath "$2")
NAME=$(basename "$1")

AURDIR=$(mktemp -d)
BUILDDIR=$(mktemp -d)

AUR="$SRCDIR/aur.deps"
ARCH="$SRCDIR/arch.deps"
AURBUILD="$SRCDIR/aur.build.deps"
ARCHBUILD="$SRCDIR/arch.build.deps"

ROOTFS="$SRCDIR/rootfs"
SCRIPT="$SRCDIR/build"
MANIFEST="$SRCDIR/manifest"

# Validate manifest
echo "### Validating Package $NAME"
if [ ! -f "$MANIFEST" ]; then
	echo "No Manifest found!"
	exit 1
fi

actool validate "$MANIFEST"

# Extract labels from manifest
MOS=$(sx -jxi $MANIFEST x.labels | sx -jxlf "x.name==='os'" | sx -jx x.value)
MARCH=$(sx -jxi $MANIFEST x.labels | sx -jxlf "x.name==='arch'" | sx -jx x.value)
MNAME=$(sx -jxi $MANIFEST 'x.name.split("/")[1]')
MVERSION=$(sx -jxi $MANIFEST x.labels | sx -jxlf "x.name==='version'" | sx -jx x.value)

# If we have no version in the manifest and no installed packages, abort
if [ -z $MVERSION ]; then
	if [ ! -f $ARCH ] && [ ! -f $AUR ]; then
		echo "No version in manifest and no aur/arch packages!"
		exit 1
	fi
fi

# Start building
echo "### Building Package $NAME"
mkdir -pm 755 "$BUILDDIR/rootfs"
sudo pacstrap -cdGM "$BUILDDIR/rootfs" filesystem

# Install Arch build dependencies
if [ -f "$ARCHBUILD" ]; then
	sudo pacman --asdeps --noconfirm -r "$BUILDDIR/rootfs" -S $(cat "$ARCHBUILD")
fi

# Install Aur build dependencies
if [ -f "$AURBUILD" ]; then
	PKGDEST="$AURDIR" pacaur --noconfirm --noedit -m $(cat "$AURBUILD")
	sudo pacman -r "$BUILDDIR/rootfs" --asdeps --noconfirm -U $AURDIR/*
	rm -rf "$AURDIR"
fi

# Install Repo Dependencies
if [ -f "$ARCH" ]; then
	sudo pacman --noconfirm -r "$BUILDDIR/rootfs" -S $(cat "$ARCH")
fi

# Install Aur dependencies
if [ -f "$AUR" ]; then
	PKGDEST="$AURDIR" pacaur --noconfirm --noedit -m $(cat "$AUR")
	sudo pacman -r "$BUILDDIR/rootfs" --noconfirm -U $AURDIR/*
	rm -rf "$AURDIR"
fi

# Copy any files from the rootfs over
if [ -d "$ROOTFS" ]; then
	sudo cp -rpf "$ROOTFS" "$BUILDDIR"
fi

# Run the install script
if [ -f "$SCRIPT" ]; then
	cp "$SCRIPT" "$BUILDDIR/rootfs"
	sudo arch-chroot "$BUILDDIR/rootfs" /build
	rm "$BUILDDIR/rootfs/build"
fi

# Remove build dependencies
if [ -f "$ARCHBUILD" ] || [ -f "$AURBUILD" ]; then
	sudo pacman --noconfirm -r "$BUILDDIR/rootfs" -Rns $(pacman -Qtdqr "$BUILDDIR/rootfs")
fi

# If we have no version, load it from the first installed package
if [ -z $MVERSION ]; then
	if [ -f $ARCH ] ; then
		MVERSION=$(sudo pacman -r "$BUILDDIR/rootfs" -Q $(head -1 "$ARCH") | sed 's/[^ ]* //')
	else
		MVERSION=$(sudo pacman -r "$BUILDDIR/rootfs" -Q $(head -1 "$AUR") | sed 's/[^ ]* //')
	fi
fi

# Copy and patch the manifest with the version
if [ -z $MVERSION ]; then
	sx -jxpi "$MANIFEST" "x.labels.push({'name':'version', 'value':'$MVERSION'}); x" > "$BUILDDIR/manifest"
else
	cp "$MANIFEST" "$BUILDDIR/manifest"
fi

# Combine infos into ACI name
ACI="$TRGDIR/images/$MOS/$MARCH/$MNAME-$MVERSION.aci"
mkdir -p $(dirname "$ACI")

# Build the aci and clean up
sudo actool build "$BUILDDIR" "$ACI"
sudo rm -rf "$BUILDDIR"
sudo rm -rf "$AURDIR"

# Generate Signature
gpg --armor --output "$ACI.asc" --detach-sig "$ACI"
