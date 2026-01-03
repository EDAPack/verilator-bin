#!/bin/bash
set -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <version> <platform>"
    exit 1
fi

VERSION=$1
PLATFORM=$2
ROOT=$(pwd)

echo "Creating pacman package for Verilator ${VERSION} on ${PLATFORM}"

# Create package directory structure
PKG_DIR="${ROOT}/release/pacman-pkg"
mkdir -p "${PKG_DIR}"

# Copy verilator installation
cp -r "${ROOT}/release/verilator" "${PKG_DIR}/verilator-${VERSION}"

# Create PKGBUILD
cat > "${PKG_DIR}/PKGBUILD" <<EOF
# Maintainer: Verilator Binary Project
pkgname=mingw-w64-x86_64-verilator-bin
pkgver=${VERSION}
pkgrel=1
pkgdesc="Verilator - the fastest Verilog/SystemVerilog simulator (binary distribution with Bitwuzla)"
arch=('any')
url="https://github.com/edapack/verilator-bin"
license=('LGPL3' 'Artistic2.0')
depends=(
    'mingw-w64-x86_64-gcc-libs'
    'mingw-w64-x86_64-gmp'
    'mingw-w64-x86_64-mpfr'
)
provides=('mingw-w64-x86_64-verilator')
conflicts=('mingw-w64-x86_64-verilator')
source=()
md5sums=()

package() {
    cd "\${srcdir}/../verilator-${VERSION}"
    
    # Install binaries
    mkdir -p "\${pkgdir}/mingw64/bin"
    cp -r bin/* "\${pkgdir}/mingw64/bin/"
    
    # Install shared files
    mkdir -p "\${pkgdir}/mingw64/share"
    cp -r share/* "\${pkgdir}/mingw64/share/"
    
    # Set execute permissions
    chmod +x "\${pkgdir}/mingw64/bin/"*
}
EOF

# Create .PKGINFO
cat > "${PKG_DIR}/.PKGINFO" <<EOF
pkgname = mingw-w64-x86_64-verilator-bin
pkgver = ${VERSION}-1
pkgdesc = Verilator - the fastest Verilog/SystemVerilog simulator (binary distribution with Bitwuzla)
url = https://github.com/edapack/verilator-bin
builddate = $(date +%s)
packager = Verilator Binary Build System
size = $(du -sb "${PKG_DIR}/verilator-${VERSION}" | cut -f1)
arch = any
license = LGPL3
license = Artistic2.0
depend = mingw-w64-x86_64-gcc-libs
depend = mingw-w64-x86_64-gmp
depend = mingw-w64-x86_64-mpfr
provides = mingw-w64-x86_64-verilator
conflicts = mingw-w64-x86_64-verilator
EOF

# Create package structure for pacman
cd "${PKG_DIR}"
mkdir -p mingw64/{bin,share}
cp -r "verilator-${VERSION}/bin/"* mingw64/bin/
cp -r "verilator-${VERSION}/share/"* mingw64/share/

# Create the package archive
PKGFILE="${ROOT}/release/mingw-w64-x86_64-verilator-bin-${VERSION}-1-any.pkg.tar.zst"
echo "Creating package: ${PKGFILE}"

# Use tar with zstd compression to create the package
tar --zstd -cf "${PKGFILE}" -C "${PKG_DIR}" .PKGINFO mingw64

if [ $? -eq 0 ]; then
    echo "Successfully created pacman package: ${PKGFILE}"
    ls -lh "${PKGFILE}"
else
    echo "Failed to create pacman package"
    exit 1
fi

# Cleanup
rm -rf "${PKG_DIR}"

echo "Pacman package creation complete"
