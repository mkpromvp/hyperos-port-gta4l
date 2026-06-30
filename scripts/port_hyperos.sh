#!/bin/bash
set -e

# ============================================================
# HyperOS Port for Samsung Galaxy Tab A7 (gta4l)
# Ports HyperOS from Redmi Pad SE to SM-T505N
# ============================================================

print_step() { echo -e "\n\033[1;34m[*] $1\033[0m"; }
print_ok()  { echo -e "\033[1;32m[+] $1\033[0m"; }
print_warn() { echo -e "\033[1;33m[!] $1\033[0m"; }
print_err() { echo -e "\033[1;31m[-] $1\033[0m"; }
print_debug() { echo -e "\033[1;30m[D] $1\033[0m"; }

# Enable debug mode with DEBUG=1 environment variable
if [ -n "$DEBUG" ]; then
    set -x
    print_ok "Debug mode enabled"
fi

# Config
DEVICE="gta4l"
MODEL="SM-T505N"
ANDROID_VER="14"

SAMSUNG_FW="${1:?Error: Provide Samsung firmware path}"
HYPEROS_FW="${2:?Error: Provide HyperOS firmware path}"
OUTPUT_DIR="${3:-./output}"

WORK_DIR="$(pwd)/build"
TOOLS_DIR="$(pwd)/tools"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR" "$TOOLS_DIR"

# ============================================================
# Step 0: Setup tools
# ============================================================
setup_tools() {
    print_step "Setting up tools"

    sudo apt update
    sudo apt install -y lz4 wget unzip tar python3 python3-pip \
        android-sdk-libsparse-utils e2fsprogs

    pip3 install --quiet protobuf lz4 unsuper numpy 2>/dev/null || true

    # Check lpunpack/lpmake are available
    if ! command -v lpunpack &>/dev/null || ! command -v lpmake &>/dev/null; then
        print_warn "lpunpack/lpmake not in PATH, checking tools dir"
        if [ -f "$TOOLS_DIR/lpunpack" ] && [ -f "$TOOLS_DIR/lpmake" ]; then
            export PATH="$TOOLS_DIR:$PATH"
            print_ok "Found tools in $TOOLS_DIR"
        else
            print_err "lpunpack/lpmake not found. Install them first!"
            exit 1
        fi
    fi

    print_ok "Tools ready"
}

# ============================================================
# Step 1: Extract Samsung firmware
# ============================================================
extract_samsung() {
    print_step "Extracting Samsung firmware"

    local SAMSUNG_OUT="$WORK_DIR/samsung"
    mkdir -p "$SAMSUNG_OUT"

    local AP_FILE
    if [ -f "$SAMSUNG_FW/AP*.tar.md5" ]; then
        AP_FILE=$(ls "$SAMSUNG_FW/AP"*.tar.md5 2>/dev/null | head -1)
    elif [ -f "$SAMSUNG_FW" ]; then
        AP_FILE="$SAMSUNG_FW"
    fi

    if [ -z "$AP_FILE" ] && [ -d "$SAMSUNG_FW" ]; then
        print_step "Samsung firmware is a directory, looking for image files"
        if [ -f "$SAMSUNG_FW/super.img.lz4" ]; then
            print_ok "Found super.img.lz4"
            cp "$SAMSUNG_FW/super.img.lz4" "$SAMSUNG_OUT/"
            cp "$SAMSUNG_FW/boot.img"* "$SAMSUNG_OUT/" 2>/dev/null || true
            cp "$SAMSUNG_FW/recovery.img"* "$SAMSUNG_OUT/" 2>/dev/null || true
            cp "$SAMSUNG_FW/vbmeta.img"* "$SAMSUNG_OUT/" 2>/dev/null || true
            cp "$SAMSUNG_FW/dtbo.img"* "$SAMSUNG_OUT/" 2>/dev/null || true
        elif [ -f "$SAMSUNG_FW/super.img" ]; then
            cp "$SAMSUNG_FW/super.img" "$SAMSUNG_OUT/"
        else
            print_err "No super.img found in Samsung firmware directory"
            ls -la "$SAMSUNG_FW/"
            exit 1
        fi
    elif [ -n "$AP_FILE" ]; then
        print_step "Extracting AP tar.md5"
        print_debug "AP_FILE=$AP_FILE ($(stat -c '%s' "$AP_FILE" 2>/dev/null || echo '?') bytes)"
        print_debug "AP_FILE type: $(file -b "$AP_FILE" 2>/dev/null)"
        tar -xf "$AP_FILE" -C "$SAMSUNG_OUT/"
        print_debug "Tar contents: $(ls -la "$SAMSUNG_OUT/" | wc -l) files"
        ls -la "$SAMSUNG_OUT/"
    else
        print_err "Cannot find Samsung firmware at: $SAMSUNG_FW"
        exit 1
    fi

    # Decompress lz4 files
    pushd "$SAMSUNG_OUT" > /dev/null
    LZ4_COUNT=0
    for f in *.lz4; do
        if [ -f "$f" ]; then
            print_debug "Found lz4: $f ($(stat -c '%s' "$f") bytes)"
            print_step "Decompressing: $f"
            lz4 -d "$f" "${f%.lz4}" 2>/dev/null || true
            LZ4_COUNT=$((LZ4_COUNT+1))
        fi
    done
    print_debug "Decompressed $LZ4_COUNT lz4 files"
    print_debug "After decompression: $(ls *.img 2>/dev/null | tr '\n' ' ')"

    # Convert sparse images to raw (Samsung often uses sparse format)
    if command -v simg2img &>/dev/null; then
        SPARSE_COUNT=0
        for img in super.img vendor.img system.img product.img odm.img; do
            if [ -f "$img" ]; then
                local IMG_TYPE
                IMG_TYPE=$(file -b "$img" | head -1)
                print_debug "Image type for $img: $IMG_TYPE"
                if echo "$IMG_TYPE" | grep -qi "sparse"; then
                    print_step "Converting sparse image: $img"
                    mv "$img" "${img}.sparse"
                    simg2img "${img}.sparse" "$img"
                    print_ok "Converted $img from sparse to raw"
                    print_debug "Raw size: $(stat -c '%s' "$img" 2>/dev/null) bytes"
                    SPARSE_COUNT=$((SPARSE_COUNT+1))
                fi
            fi
        done
        print_debug "Converted $SPARSE_COUNT sparse images"
    else
        print_warn "simg2img not found, sparse images may not be converted"
    fi
    popd > /dev/null

    # Extract super.img using lpunpack
    if [ -f "$SAMSUNG_OUT/super.img" ]; then
        print_step "Extracting super.img with lpunpack"
        print_debug "super.img: $(stat -c '%s' "$SAMSUNG_OUT/super.img") bytes, type: $(file -b "$SAMSUNG_OUT/super.img" | head -1)"
        mkdir -p "$SAMSUNG_OUT/super_out"
        lpunpack "$SAMSUNG_OUT/super.img" "$SAMSUNG_OUT/super_out/" 2>&1 || {
            print_warn "lpunpack failed, trying Python fallback"
            extract_super_img "$SAMSUNG_OUT/super.img" "$SAMSUNG_OUT/super_out"
        }
        print_debug "super_out contents:"
        ls -la "$SAMSUNG_OUT/super_out/"
    else
        print_err "super.img not found after extraction"
        exit 1
    fi

    # Clean up to save space
    print_step "Cleaning up Samsung intermediates"
    rm -f "$SAMSUNG_OUT/super.img.lz4" 2>/dev/null || true
    rm -f "$SAMSUNG_OUT/super.img.sparse" 2>/dev/null || true
    for f in "$SAMSUNG_OUT"/*.lz4; do [ -f "$f" ] && rm -f "$f"; done 2>/dev/null || true
    # Delete AP tar now that it's extracted
    if [ -f "$SAMSUNG_FW" ] && [[ "$SAMSUNG_FW" == *.tar.md5 ]]; then
        rm -f "$SAMSUNG_FW" 2>/dev/null || true
        print_ok "Deleted AP tar to free space"
    fi
    df -h
    print_ok "Samsung firmware extracted"
}

# Extract super.img using multiple tools (unsuper, lpunpack, dd+skip)
extract_super_img() {
    local SUPER_IMG="$1"
    local OUT_DIR="$2"
    mkdir -p "$OUT_DIR"

    # Method 1: unsuper (best Python tool)
    if python3 -c "import unsuper" 2>/dev/null; then
        print_debug "Using unsuper for extraction..."
        python3 -m unsuper "$SUPER_IMG" "$OUT_DIR" --jobs 4 2>&1 || true
        if [ -f "$OUT_DIR/system.img" ] || [ -f "$OUT_DIR/system_a.img" ]; then
            print_ok "unsuper extracted successfully"
            return 0
        fi
    fi

    # Method 2: lpunpack
    if command -v lpunpack &>/dev/null; then
        print_debug "Using lpunpack..."
        lpunpack "$SUPER_IMG" "$OUT_DIR/" 2>&1 || true
        if ls "$OUT_DIR/system"*.img 2>/dev/null | head -1; then
            print_ok "lpunpack extracted successfully"
            return 0
        fi
    fi

    # Method 3: Skip first 4096 bytes and retry (for greeshan format)
    print_debug "Trying with 4096-byte offset (greeshan format)..."
    local TRIMMED="${SUPER_IMG}.trimmed"
    dd if="$SUPER_IMG" of="$TRIMMED" bs=4096 skip=1 2>/dev/null
    if python3 -c "import unsuper" 2>/dev/null; then
        python3 -m unsuper "$TRIMMED" "$OUT_DIR" --jobs 4 2>&1 || true
        if [ -f "$OUT_DIR/system.img" ] || [ -f "$OUT_DIR/system_a.img" ]; then
            print_ok "unsuper with offset extracted successfully"
            rm -f "$TRIMMED"
            return 0
        fi
    fi
    lpunpack "$TRIMMED" "$OUT_DIR/" 2>&1 || true
    if ls "$OUT_DIR/system"*.img 2>/dev/null | head -1; then
        print_ok "lpunpack with offset extracted successfully"
        rm -f "$TRIMMED"
        return 0
    fi
    rm -f "$TRIMMED"

    # Method 4: Mount with offset
    print_debug "Trying mount with offset 4096..."
    local MNT="/tmp/super_mnt_$$"
    mkdir -p "$MNT"
    if sudo mount -o loop,ro,offset=4096 "$SUPER_IMG" "$MNT" 2>/dev/null; then
        print_ok "Mounted with offset 4096"
        ls -la "$MNT/"
        for d in system system_a vendor vendor_a product product_a odm odm_a; do
            if [ -d "$MNT/$d" ]; then
                print_ok "Found $d in mount, creating empty marker"
                touch "$OUT_DIR/${d}.img"
            fi
        done
        sudo umount "$MNT" 2>/dev/null || true
        # If we found partitions, the tool needs to handle directory-based extraction
        if ls "$OUT_DIR/system"*.img 2>/dev/null | head -1; then
            return 0
        fi
    fi

    # Method 5: Try fsck.ext4 to identify the image
    print_debug "Trying fsck.ext4..."
    sudo fsck.ext4 -n "$SUPER_IMG" 2>&1 | head -5 || true

    print_warn "All extraction methods failed for $SUPER_IMG"
    return 1
}

# ============================================================
# Step 2: Extract HyperOS firmware (original recovery ROM)
# ============================================================
extract_hyperos() {
    print_step "Extracting HyperOS firmware (original recovery ROM)"

    local HYPEROS_OUT="$WORK_DIR/hyperos"
    mkdir -p "$HYPEROS_OUT"

    local HYPEROS_FILE
    if [ -d "$HYPEROS_FW" ]; then
        HYPEROS_FILE=$(ls "$HYPEROS_FW"/*.tgz "$HYPEROS_FW"/*.zip "$HYPEROS_FW"/*.tar.gz 2>/dev/null | head -1)
    else
        HYPEROS_FILE="$HYPEROS_FW"
    fi

    if [ ! -f "$HYPEROS_FILE" ]; then
        print_err "HyperOS firmware file not found: $HYPEROS_FW"
        exit 1
    fi

    print_step "Extracting: $(basename $HYPEROS_FILE)"
    print_debug "HYPEROS_FILE=$HYPEROS_FILE ($(stat -c '%s' "$HYPEROS_FILE" 2>/dev/null || echo '?') bytes)"
    print_debug "HYPEROS_FILE type: $(file -b "$HYPEROS_FILE" 2>/dev/null)"

    # Unzip the recovery ROM
    unzip -o "$HYPEROS_FILE" -d "$HYPEROS_OUT/"
    print_ok "Recovery ROM extracted"
    print_debug "Contents:"
    find "$HYPEROS_OUT" -maxdepth 2 -type f | head -30

    # Find payload.bin
    local PAYLOAD_BIN=""
    if [ -f "$HYPEROS_OUT/payload.bin" ]; then
        PAYLOAD_BIN="$HYPEROS_OUT/payload.bin"
    elif [ -f "$HYPEROS_OUT/images/payload.bin" ]; then
        PAYLOAD_BIN="$HYPEROS_OUT/images/payload.bin"
    fi

    if [ -z "$PAYLOAD_BIN" ]; then
        print_err "payload.bin not found in recovery ROM"
        find "$HYPEROS_OUT" -name "payload*" -type f 2>/dev/null
        exit 1
    fi

    # Use payload-dumper from HyperOS-Port-Python tool
    print_step "Extracting partitions from payload.bin using payload-dumper"
    PAYLOAD_DUMPER=$(command -v payload-dumper || echo "$TOOLS_DIR/../hyperos_tool/bin/linux/x86_64/payload-dumper")
    if [ ! -f "$PAYLOAD_DUMPER" ]; then
        print_err "payload-dumper not found"
        exit 1
    fi
    print_debug "Using payload-dumper: $PAYLOAD_DUMPER"

    local HYPEROS_IMG_DIR="$HYPEROS_OUT/images"
    mkdir -p "$HYPEROS_IMG_DIR"

    "$PAYLOAD_DUMPER" --out "$HYPEROS_IMG_DIR" "$PAYLOAD_BIN" 2>&1
    print_ok "payload-dumper completed"

    # Convert sparse images to raw
    print_step "Converting sparse images to raw"
    if command -v simg2img &>/dev/null; then
        for img in "$HYPEROS_IMG_DIR"/*.img; do
            local IMG_TYPE
            IMG_TYPE=$(file -b "$img" | head -1)
            if echo "$IMG_TYPE" | grep -qi "sparse"; then
                print_step "Converting sparse: $(basename $img)"
                mv "$img" "${img}.sparse"
                simg2img "${img}.sparse" "$img"
            fi
        done
    fi

    print_ok "HyperOS partitions extracted:"
    ls -la "$HYPEROS_IMG_DIR/"*.img 2>/dev/null | awk '{print $5, $9}'

    # Clean up to save space
    print_step "Cleaning up HyperOS intermediates"
    rm -f "$PAYLOAD_BIN" 2>/dev/null || true
    if [ -f "$HYPEROS_FW" ] && [[ "$HYPEROS_FW" == *.zip ]]; then
        rm -f "$HYPEROS_FW" 2>/dev/null || true
        print_ok "Deleted HyperOS zip to free space"
    fi
    df -h
    print_ok "HyperOS firmware extracted"
}

# ============================================================
# Step 3: Port - Replace system + patch
# ============================================================
do_port() {
    print_step "Starting porting process"

    local SAMSUNG_OUT="$WORK_DIR/samsung/super_out"
    local HYPEROS_OUT
    if [ -d "$WORK_DIR/hyperos/images" ]; then
        HYPEROS_OUT="$WORK_DIR/hyperos/images"
    elif [ -d "$WORK_DIR/hyperos/super_out" ]; then
        HYPEROS_OUT="$WORK_DIR/hyperos/super_out"
    elif [ -d "$WORK_DIR/hyperos/images/super_out" ]; then
        HYPEROS_OUT="$WORK_DIR/hyperos/images/super_out"
    else
        HYPEROS_OUT="$WORK_DIR/hyperos/images"
        mkdir -p "$HYPEROS_OUT"
    fi
    mkdir -p "$PORT_OUT"

    # Handle A/B naming: create symlinks for _a partitions
    if [ -f "$HYPEROS_OUT/system_a.img" ] && [ ! -f "$HYPEROS_OUT/system.img" ]; then
        print_ok "Creating symlinks for A/B slot images"
        for part in system product vendor odm system_ext mi_ext vendor_dlkm system_dlkm; do
            if [ -f "$HYPEROS_OUT/${part}_a.img" ]; then
                ln -sf "${part}_a.img" "$HYPEROS_OUT/$part.img"
            fi
        done
    fi

    # Copy Samsung base partitions
    print_step "Copying Samsung base partitions"
    for part in system vendor product odm; do
        if [ -f "$SAMSUNG_OUT/${part}.img" ]; then
            cp "$SAMSUNG_OUT/${part}.img" "$PORT_OUT/${part}_samsung.img"
            print_ok "Copied ${part}_samsung.img"
        fi
    done

    # Copy HyperOS system
    print_step "Copying HyperOS system"
    if [ -f "$HYPEROS_OUT/system.img" ]; then
        cp "$HYPEROS_OUT/system.img" "$PORT_OUT/system.img"
        print_ok "Copied HyperOS system.img"
    elif [ -f "$WORK_DIR/hyperos/images/system.img" ]; then
        cp "$WORK_DIR/hyperos/images/system.img" "$PORT_OUT/system.img"
        print_ok "Copied HyperOS system.img (flat)"
    else
        print_err "HyperOS system.img not found"
        ls -la "$HYPEROS_OUT/" 2>/dev/null || ls -la "$WORK_DIR/hyperos/" 2>/dev/null || true
        exit 1
    fi

    # Copy HyperOS product (for Xiaomi apps/features)
    if [ -f "$HYPEROS_OUT/product.img" ]; then
        cp "$HYPEROS_OUT/product.img" "$PORT_OUT/product.img"
        print_ok "Copied HyperOS product.img"
    fi

    # Mount and patch system build.prop
    print_step "Patching system build.prop"
    mkdir -p "$WORK_DIR/mount_system"
    sudo mount -o loop "$PORT_OUT/system.img" "$WORK_DIR/mount_system" 2>/dev/null || {
        print_warn "Cannot mount system.img (may need fsck), trying fallback"
        sudo fsck.ext4 -y "$PORT_OUT/system.img" 2>/dev/null || true
        sudo mount -o loop,ro "$PORT_OUT/system.img" "$WORK_DIR/mount_system" 2>/dev/null || {
            # Try using debugfs instead
            print_warn "Using debugfs to extract build.prop"
            mkdir -p "$WORK_DIR/system_extract"
            cd "$WORK_DIR/system_extract"
            python3 -c "
import os, subprocess, sys
img = '$PORT_OUT/system.img'
out = '$WORK_DIR/system_extract'
# Use debugfs to pull files
subprocess.run(['sudo', 'debugfs', '-R', 'ls -l /', img], capture_output=True)
print('Cannot fully extract without mount, continuing with patches')
" 2>/dev/null || true
        }
    }

    # Patch build.prop
    local BUILD_PROP="$WORK_DIR/mount_system/build.prop"
    if [ -f "$BUILD_PROP" ]; then
        print_step "Patching build.prop with Samsung device properties"

        sudo sed -i 's|^ro.product.board=.*|ro.product.board=gta4l|' "$BUILD_PROP" 2>/dev/null || true
        sudo sed -i 's|^ro.product.device=.*|ro.product.device=gta4l|' "$BUILD_PROP" 2>/dev/null || true
        sudo sed -i 's|^ro.product.model=.*|ro.product.model=SM-T505N|' "$BUILD_PROP" 2>/dev/null || true
        sudo sed -i 's|^ro.product.name=.*|ro.product.name=gta4l_egy|' "$BUILD_PROP" 2>/dev/null || true
        sudo sed -i 's|^ro.product.manufacturer=.*|ro.product.manufacturer=Samsung|' "$BUILD_PROP" 2>/dev/null || true
        sudo sed -i 's|^ro.build.fingerprint=.*|ro.build.fingerprint=samsung/gta4l_egy/gta4l:12/T505NDXS7CXG1/T505NDXS7CXG1:user/release-keys|' "$BUILD_PROP" 2>/dev/null || true

        # Add Samsung-specific properties
        echo "# Samsung device properties" | sudo tee -a "$BUILD_PROP"
        echo "ro.product.vendor.device=gta4l" | sudo tee -a "$BUILD_PROP"
        echo "ro.product.vendor.model=SM-T505N" | sudo tee -a "$BUILD_PROP"
        echo "ro.product.vendor.manufacturer=Samsung" | sudo tee -a "$BUILD_PROP"
        echo "ro.vendor.build.fingerprint=samsung/gta4l_egy/gta4l:12/T505NDXS7CXG1/T505NDXS7CXG1:user/release-keys" | sudo tee -a "$BUILD_PROP"
        echo "ro.samsung.mdl=true" | sudo tee -a "$BUILD_PROP"

        print_ok "build.prop patched"
        grep "^ro.product." "$BUILD_PROP" | head -20
    else
        print_warn "build.prop not found at mount point"
    fi

    # Unmount system
    sudo umount "$WORK_DIR/mount_system" 2>/dev/null || true

    # Copy Samsung's boot.img, recovery.img, vbmeta.img, dtbo.img
    print_step "Copying Samsung boot images"
    for img in boot recovery vbmeta dtbo; do
        for ext in "" ".img" ".img.lz4"; do
            local F="$WORK_DIR/samsung/${img}${ext}"
            if [ -f "$F" ]; then
                cp "$F" "$PORT_OUT/${img}${ext}" 2>/dev/null || true
                print_ok "Copied: $(basename $F)"
            fi
        done
    done

    # Clean up large images no longer needed
    print_step "Cleaning up after porting"
    rm -f "$WORK_DIR/samsung/super.img" 2>/dev/null || true
    rm -rf "$WORK_DIR/samsung/super_out" 2>/dev/null || true
    rm -rf "$WORK_DIR/hyperos/images/super_out" 2>/dev/null || true
    df -h
    print_ok "Porting complete"
}

# ============================================================
# Step 4: Repack super.img
# ============================================================
repack_super() {
    print_step "Repacking super image"

    local PORT_OUT="$WORK_DIR/port"

    # Get partition sizes from Samsung
    local SUPER_SIZE
    if [ -f "$WORK_DIR/samsung/super.img" ]; then
        SUPER_SIZE=$(stat -f --format="%z" "$WORK_DIR/samsung/super.img" 2>/dev/null || stat -c "%s" "$WORK_DIR/samsung/super.img" 2>/dev/null || wc -c < "$WORK_DIR/samsung/super.img")
        print_ok "Original super.img size: $SUPER_SIZE bytes"
    else
        SUPER_SIZE=$((6*1024*1024*1024))  # 6GB max for gta4l
        print_warn "Using default super size: $SUPER_SIZE"
    fi

    # Get system partition size
    local SYSTEM_SIZE
    if [ -f "$PORT_OUT/system.img" ]; then
        SYSTEM_SIZE=$(stat -c "%s" "$PORT_OUT/system.img" 2>/dev/null)
    else
        SYSTEM_SIZE=$((4*1024*1024*1024))  # 4GB default
    fi

    # Get vendor size from Samsung
    local VENDOR_SIZE
    if [ -f "$PORT_OUT/vendor_samsung.img" ]; then
        VENDOR_SIZE=$(stat -c "%s" "$PORT_OUT/vendor_samsung.img" 2>/dev/null)
    else
        VENDOR_SIZE=$((1024*1024*1024))  # 1GB default
    fi

    # Get product size
    local PRODUCT_SIZE=0
    if [ -f "$PORT_OUT/product.img" ]; then
        PRODUCT_SIZE=$(stat -c "%s" "$PORT_OUT/product.img" 2>/dev/null)
    elif [ -f "$PORT_OUT/product_samsung.img" ]; then
        PRODUCT_SIZE=$(stat -c "%s" "$PORT_OUT/product_samsung.img" 2>/dev/null)
    fi

    # Align sizes to block size (4096)
    align() { local s=$1; local a=4096; echo $(( (s + a - 1) / a * a )); }

    SYSTEM_SIZE=$(align $SYSTEM_SIZE)
    VENDOR_SIZE=$(align $VENDOR_SIZE)
    PRODUCT_SIZE=$(align $PRODUCT_SIZE)
    SUPER_SIZE=$(align $SUPER_SIZE)

    # Convert to raw ext4 if needed
    if command -v simg2img &>/dev/null; then
        for img in system vendor product; do
            local SRC="$PORT_OUT/${img}.img"
            local SRCSAMS="$PORT_OUT/${img}_samsung.img"
            if [ -f "$SRC" ]; then
                local TYPE
                TYPE=$(file -b "$SRC" | head -1)
                if echo "$TYPE" | grep -qi "sparse"; then
                    print_step "Converting $(basename $SRC) from sparse to raw"
                    mv "$SRC" "${SRC}.sparse"
                    simg2img "${SRC}.sparse" "$SRC"
                fi
            fi
        done
    fi

    # Create super.img using lpmake
    print_step "Creating super.img with lpmake"

    local LPMAKE_CMD="lpmake --metadata-size 65536 --super-name super --block-size 4096"
    LPMAKE_CMD+=" --device super:$SUPER_SIZE"

    # Add system partition
    if [ -f "$PORT_OUT/system.img" ]; then
        LPMAKE_CMD+=" --partition system:readonly:$SYSTEM_SIZE:system_image"
        LPMAKE_CMD+=" --image system=$(readlink -f $PORT_OUT/system.img)"
    fi

    # Add vendor partition (from Samsung)
    if [ -f "$PORT_OUT/vendor_samsung.img" ]; then
        local VENDOR_FILE="$PORT_OUT/vendor_samsung.img"
        LPMAKE_CMD+=" --partition vendor:readonly:$VENDOR_SIZE:vendor_image"
        LPMAKE_CMD+=" --image vendor=$(readlink -f $VENDOR_FILE)"
    fi

    # Add product partition (from HyperOS)
    if [ -f "$PORT_OUT/product.img" ] && [ "$PRODUCT_SIZE" -gt 1048576 ]; then
        LPMAKE_CMD+=" --partition product:readonly:$PRODUCT_SIZE:product_image"
        LPMAKE_CMD+=" --image product=$(readlink -f $PORT_OUT/product.img)"
    elif [ -f "$PORT_OUT/product_samsung.img" ] && [ "$PRODUCT_SIZE" -gt 1048576 ]; then
        LPMAKE_CMD+=" --partition product:readonly:$PRODUCT_SIZE:product_image"
        LPMAKE_CMD+=" --image product=$(readlink -f $PORT_OUT/product_samsung.img)"
    fi

    LPMAKE_CMD+=" --sparse --output $PORT_OUT/super.img"

    print_step "Running lpmake..."
    echo "$LPMAKE_CMD"
    eval "$LPMAKE_CMD" 2>&1 || {
        print_warn "lpmake failed, trying without sparse"
        LPMAKE_CMD="${LPMAKE_CMD/--sparse /}"
        eval "$LPMAKE_CMD" 2>&1 || {
            print_err "lpmake failed again"
            false
        }
    }

    if [ -f "$PORT_OUT/super.img" ]; then
        print_ok "super.img created: $(stat -c "%s" "$PORT_OUT/super.img") bytes"
    else
        # Manual creating via Python
        print_warn "lpmake failed, creating minimal super.img via Python"
        python3 "$(dirname $0)/create_super.py" \
            --system "$PORT_OUT/system.img" \
            --vendor "$PORT_OUT/vendor_samsung.img" \
            --product "$PORT_OUT/product.img" \
            --output "$PORT_OUT/super.img" \
            --block-size 4096
    fi
}

# ============================================================
# Step 5: Create Odin flashable tar
# ============================================================
create_odin_tar() {
    print_step "Creating Odin flashable tar"

    local PORT_OUT="$WORK_DIR/port"
    local TAR_NAME="HYPEROS_PORT_${MODEL}_${DEVICE}"
    local TAR_FILE="${TAR_NAME}.tar.md5"

    cd "$PORT_OUT"

    local HAS_BOOT=false
    local HAS_SUPER=false

    # Collect files for the tar
    local TAR_FILES=""

    # boot.img - use Samsung's
    if [ -f "boot.img" ]; then
        TAR_FILES+=" boot.img"
        HAS_BOOT=true
    fi

    # recovery.img - use Samsung's
    if [ -f "recovery.img" ]; then
        TAR_FILES+=" recovery.img"
    fi

    # super.img - our ported one
    if [ -f "super.img" ]; then
        TAR_FILES+=" super.img"
        HAS_SUPER=true
    fi

    # vbmeta.img - Samsung's (disabled verification)
    if [ -f "vbmeta.img" ]; then
        TAR_FILES+=" vbmeta.img"
    fi

    # dtbo.img - Samsung's
    if [ -f "dtbo.img" ]; then
        TAR_FILES+=" dtbo.img"
    fi

    if [ "$HAS_BOOT" = false ] || [ "$HAS_SUPER" = false ]; then
        print_err "Missing required images for Odin tar"
        echo "  boot.img: $HAS_BOOT"
        echo "  super.img: $HAS_SUPER"
        exit 1
    fi

    print_step "Creating tar: $TAR_FILE"
    tar -cvf "$OUTPUT_DIR/$TAR_FILE" $TAR_FILES

    # Generate md5 for Odin
    cd "$OUTPUT_DIR"
    md5sum -t "$TAR_FILE" >> "$TAR_FILE"
    print_ok "Odin flashable tar created: $OUTPUT_DIR/$TAR_FILE"
    ls -la "$OUTPUT_DIR/$TAR_FILE"
}

# ============================================================
# Main
# ============================================================
main() {
    print_step "=== HyperOS Port for Samsung Galaxy Tab A7 (gta4l) ==="
    echo "  Samsung FW: $SAMSUNG_FW"
    echo "  HyperOS FW: $HYPEROS_FW"
    echo "  Output:     $OUTPUT_DIR"
    echo "  Work dir:   $WORK_DIR"
    echo "  Tools dir:  $TOOLS_DIR"
    echo "  Device:     $MODEL ($DEVICE)"
    print_debug "Arguments: '$1' '$2' '$3'"
    print_debug "SAMSUNG_FW exists? $(test -e "$SAMSUNG_FW" && echo YES || echo NO)"
    print_debug "SAMSUNG_FW type: $(file -b "$SAMSUNG_FW" 2>/dev/null || echo 'N/A')"
    print_debug "HYPEROS_FW exists? $(test -e "$HYPEROS_FW" && echo YES || echo NO)"
    print_debug "HYPEROS_FW type: $(file -b "$HYPEROS_FW" 2>/dev/null || echo 'N/A')"
    df -h

    setup_tools
    extract_samsung
    extract_hyperos
    do_port
    repack_super
    create_odin_tar

    print_step "=== Porting complete! ==="
    echo ""
    echo "Output file: $OUTPUT_DIR/HYPEROS_PORT_${MODEL}_${DEVICE}.tar.md5"
    echo ""
    echo "Flash using Odin:"
    echo "  1. Boot device into Download Mode"
    echo "  2. Open Odin"
    echo "  3. Load tar.md5 in AP slot"
    echo "  4. Click Start"
    echo ""
    echo "WARNING: First boot may take 5-10 minutes"
    echo "If it bootloops, try wiping data in recovery"
}

main "$@"
