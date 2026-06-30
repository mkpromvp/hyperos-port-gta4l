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

    pip3 install --quiet protobuf lz4 2>/dev/null || true

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
        tar -xf "$AP_FILE" -C "$SAMSUNG_OUT/"
    else
        print_err "Cannot find Samsung firmware at: $SAMSUNG_FW"
        exit 1
    fi

    # Decompress lz4 files
    pushd "$SAMSUNG_OUT" > /dev/null
    for f in *.lz4; do
        if [ -f "$f" ]; then
            print_step "Decompressing: $f"
            lz4 -d "$f" "${f%.lz4}" 2>/dev/null || true
        fi
    done

    # Convert sparse images to raw (Samsung often uses sparse format)
    if command -v simg2img &>/dev/null; then
        for img in super.img vendor.img system.img product.img odm.img; do
            if [ -f "$img" ]; then
                local IMG_TYPE
                IMG_TYPE=$(file -b "$img" | head -1)
                if echo "$IMG_TYPE" | grep -qi "sparse"; then
                    print_step "Converting sparse image: $img"
                    mv "$img" "${img}.sparse"
                    simg2img "${img}.sparse" "$img"
                    print_ok "Converted $img from sparse to raw"
                fi
            fi
        done
    fi
    popd > /dev/null

    # Extract super.img using lpunpack
    if [ -f "$SAMSUNG_OUT/super.img" ]; then
        print_step "Extracting super.img with lpunpack"
        mkdir -p "$SAMSUNG_OUT/super_out"
        lpunpack "$SAMSUNG_OUT/super.img" "$SAMSUNG_OUT/super_out/" 2>&1 || {
            print_warn "lpunpack failed, trying Python fallback"
            extract_super_python "$SAMSUNG_OUT/super.img" "$SAMSUNG_OUT/super_out"
        }
        ls -la "$SAMSUNG_OUT/super_out/"
    else
        print_err "super.img not found after extraction"
        exit 1
    fi

    print_ok "Samsung firmware extracted"
}

# Python fallback for super.img extraction
extract_super_python() {
    local SUPER_IMG="$1"
    local OUT_DIR="$2"
    mkdir -p "$OUT_DIR"

    python3 <<EOF
import struct, os, sys

super_img = open("$SUPER_IMG", "rb")
out_dir = "$OUT_DIR"

# Read magic
magic = super_img.read(4)
if magic != b'\x69\x32\x33\x34':  # LP_MAGIC
    print("[-] Not a valid super image (LP_MAGIC not found)")
    print(f"    Magic: {magic.hex()}")
    super_img.close()
    sys.exit(1)

# Read header (simple parsing)
super_img.seek(0)
header_fmt = '<4sIIIIIIIIIIIIIII'
header_size = struct.calcsize(header_fmt)
header_data = super_img.read(header_size)
magic, version, lp_hdr_sz, hdr_sz_bt, partitions, max_vol_name, extent_entries, total_extents, first_lun, last_lun, alignment, alignment_offset, block_size, super_sz = struct.unpack_from(header_fmt, header_data)

print(f"[+] Super image: {super_sz} bytes, {partitions} partitions, block_size={block_size}")

# Read partition table
super_img.seek(lp_hdr_sz)
for i in range(partitions):
    part_entry = super_img.read(64)  # sizeof(LpMetadataPartition)
    part_name = part_entry[0:36].split(b'\x00')[0].decode('ascii', errors='replace')
    part_attr, part_extents = struct.unpack_from('<II', part_entry, 36)
    part_gi, part_idx = struct.unpack_from('<II', part_entry, 44)
    
    # Seek to extent table
    super_img.seek(lp_hdr_sz + header_size + i * 64 + 52)
    num_extents = struct.unpack('<I', super_img.read(4))[0]
    
    # Read extents
    for e in range(num_extents):
        extent_entry = super_img.read(32)  # sizeof(LpMetadataExtent)
        num_blocks, ext_flags, start_sector = struct.unpack_from('<I12xQ16x', extent_entry)
        
        offset = start_sector * 512
        size = num_blocks * block_size
        
        print(f"[+] Extracting: {part_name} ({size} bytes at {offset})")
        
        out_file = os.path.join(out_dir, f"{part_name}.img")
        with open(out_file, 'wb') as f:
            super_img.seek(offset)
            remaining = size
            while remaining > 0:
                chunk_size = min(remaining, 1024*1024*64)  # 64MB chunks
                data = super_img.read(chunk_size)
                if not data:
                    break
                f.write(data)
                remaining -= len(data)
        print(f"    -> {out_file} ({os.path.getsize(out_file)} bytes)")

super_img.close()
print(f"[+] Done extracting super.img to {out_dir}")
EOF
}

# ============================================================
# Step 2: Extract HyperOS firmware
# ============================================================
extract_hyperos() {
    print_step "Extracting HyperOS firmware"

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

    case "$HYPEROS_FILE" in
        *.tgz|*.tar.gz)
            tar -xzf "$HYPEROS_FILE" -C "$HYPEROS_OUT/"
            ;;
        *.zip)
            unzip -o "$HYPEROS_FILE" -d "$HYPEROS_OUT/"
            ;;
        *)
            print_err "Unknown HyperOS firmware format"
            exit 1
            ;;
    esac

    # Show extracted structure
    print_ok "Extracted HyperOS zip to: $(ls -d $HYPEROS_OUT/*/ 2>/dev/null | tr '\n' ' ')"

    # Find image files
    if [ -d "$HYPEROS_OUT/images" ]; then
        HYPEROS_IMG_DIR="$HYPEROS_OUT/images"
    else
        HYPEROS_IMG_DIR="$HYPEROS_OUT"
    fi
    print_ok "Image directory: $HYPEROS_IMG_DIR"

    # Handle repack format: firmware-update/greeshan.img → super.img
    if [ -f "$HYPEROS_OUT/firmware-update/greeshan.img" ]; then
        print_step "Found greeshan.img (repack format), copying to super.img"
        cp "$HYPEROS_OUT/firmware-update/greeshan.img" "$HYPEROS_IMG_DIR/super.img"
        print_ok "Copied greeshan.img → super.img ($(stat -c '%s' "$HYPEROS_IMG_DIR/super.img") bytes)"
    fi

    # If it's a recovery ROM with payload.bin
    if [ -f "$HYPEROS_OUT/payload.bin" ]; then
        print_step "Extracting payload.bin"
        python3 <<EOF
import os, sys, struct

payload_file = "$HYPEROS_OUT/payload.bin"
out_dir = "$HYPEROS_OUT/images"
os.makedirs(out_dir, exist_ok=True)

with open(payload_file, "rb") as f:
    magic = f.read(4)
    if magic != b'CRXU':
        print(f"[-] Not a valid payload.bin (magic: {magic.hex()})")
        sys.exit(1)
    
    # Simple extraction - look for img files
    f.seek(0)
    data = f.read()
    
    # Find partitions by looking for EXT4 magic
    img_ext = data.find(b'\xe2\x2a\x07\x22')  # spoof_ext4
    if img_ext < 0:
        img_ext = data.find(b'\x53\xEF')  # ext4 magic
    
    print(f"[+] payload.bin size: {len(data)} bytes")
    print("[!] Full payload.bin extraction requires update_engine, using raw copy")
    
    # For now, copy the payload.bin for later processing
    import shutil
    shutil.copy(payload_file, os.path.join(out_dir, "payload.bin"))
    print(f"[+] Copied payload.bin to {out_dir}/")
EOF
    fi

    # Convert sparse images to raw
    if command -v simg2img &>/dev/null; then
        for img in "$HYPEROS_IMG_DIR"/*.img; do
            local IMG_TYPE
            IMG_TYPE=$(file -b "$img" | head -1)
            if echo "$IMG_TYPE" | grep -qi "sparse"; then
                print_step "Converting sparse image: $(basename $img)"
                mv "$img" "${img}.sparse"
                simg2img "${img}.sparse" "$img"
            fi
        done
    fi

    # Extract super.img if present
    if [ -f "$HYPEROS_IMG_DIR/super.img" ]; then
        print_step "Extracting HyperOS super.img"
        mkdir -p "$HYPEROS_IMG_DIR/super_out"
        local IMG_TYPE
        IMG_TYPE=$(file -b "$HYPEROS_IMG_DIR/super.img" | head -1)
        print_ok "Super image type: $IMG_TYPE"
        if command -v lpunpack &>/dev/null; then
            lpunpack "$HYPEROS_IMG_DIR/super.img" "$HYPEROS_IMG_DIR/super_out/" 2>&1 || true
        fi
        if [ ! -f "$HYPEROS_IMG_DIR/super_out/system.img" ]; then
            extract_super_python "$HYPEROS_IMG_DIR/super.img" "$HYPEROS_IMG_DIR/super_out" || true
        fi
        if [ ! -f "$HYPEROS_IMG_DIR/super_out/system.img" ]; then
            print_warn "lpunpack failed, trying raw mount"
            local SUPER_MNT="$HYPEROS_IMG_DIR/super_mount"
            mkdir -p "$SUPER_MNT"
            if sudo mount -o loop,ro "$HYPEROS_IMG_DIR/super.img" "$SUPER_MNT" 2>/dev/null; then
                print_ok "Mounted super.img - looking for partitions"
                ls -la "$SUPER_MNT/"
                for subdir in system system_a system_ext system_ext_a; do
                    if [ -d "$SUPER_MNT/$subdir" ]; then
                        print_ok "Found $subdir in mounted super"
                    fi
                done
                sudo umount "$SUPER_MNT" 2>/dev/null || true
            else
                print_warn "Cannot mount super.img (may need LP header restoration)"
                print_warn "Super image first 64 bytes:"
                hexdump -C "$HYPEROS_IMG_DIR/super.img" 2>/dev/null | head -4 || od -A x -t x1z -N 64 "$HYPEROS_IMG_DIR/super.img" 2>/dev/null | head -4
            fi
        fi
        ls -la "$HYPEROS_IMG_DIR/super_out/"
    fi

    print_ok "HyperOS firmware extracted"
}

# ============================================================
# Step 3: Port - Replace system + patch
# ============================================================
do_port() {
    print_step "Starting porting process"

    local SAMSUNG_OUT="$WORK_DIR/samsung/super_out"
    local HYPEROS_OUT
    if [ -d "$WORK_DIR/hyperos/super_out" ]; then
        HYPEROS_OUT="$WORK_DIR/hyperos/super_out"
    elif [ -d "$WORK_DIR/hyperos/images/super_out" ]; then
        HYPEROS_OUT="$WORK_DIR/hyperos/images/super_out"
    else
        HYPEROS_OUT="$WORK_DIR/hyperos/super_out"
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
        SUPER_SIZE=$((8*1024*1024*1024))  # 8GB default for gta4l
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
    echo "  Device:     $MODEL ($DEVICE)"

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
