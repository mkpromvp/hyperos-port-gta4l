#!/usr/bin/env python3
"""Extract partitions from super.img - handles LP_MAGIC and raw ext4 images."""
import struct, os, sys

def log(msg):
    print(msg, flush=True)

def extract_lp(data, out_dir):
    """Extract using LP metadata header."""
    magic, version, lp_hdr_sz, hdr_sz_bt, partitions, max_vol_name, extent_entries, total_extents, first_lun, last_lun, alignment, alignment_offset, block_size, super_sz = struct.unpack_from('<4sIIIIIIIIIIIIIII', data, 0)
    log(f"[+] LP super: {super_sz} bytes, {partitions} partitions, block_size={block_size}")

    offset = lp_hdr_sz
    for i in range(partitions):
        part_entry = data[offset:offset+64]
        part_name = part_entry[0:36].split(b'\x00')[0].decode('ascii', errors='replace')
        num_extents = struct.unpack('<I', part_entry[52:56])[0]
        offset += 64

        for e in range(num_extents):
            extent_entry = data[offset:offset+32]
            num_blocks, start_sector = struct.unpack_from('<I12xQ16x', extent_entry)
            offset += 32
            part_offset = start_sector * 512
            part_size = num_blocks * block_size
            log(f"[+] Extracting: {part_name} ({part_size} bytes at {part_offset})")
            out_file = os.path.join(out_dir, f"{part_name}.img")
            with open(out_file, 'wb') as f:
                pos = part_offset
                remaining = part_size
                while remaining > 0 and pos < len(data):
                    chunk = min(remaining, 64*1024*1024)
                    f.write(data[pos:pos+chunk])
                    pos += chunk
                    remaining -= chunk
            log(f"    -> {os.path.getsize(out_file)} bytes")
    return True

def extract_ext4_scan(data, out_dir):
    """Scan for ext4 superblocks and extract partitions."""
    BLOCK_SIZE = 4096
    EXT4_MAGIC = b'\x53\xEF'
    partitions = []

    log("[!] LP_MAGIC not found, scanning for ext4 partitions...")
    offset = 0
    last_part_end = 0

    while offset < len(data):
        if offset + 0x3a > len(data):
            break
        if data[offset+0x38:offset+0x3a] == EXT4_MAGIC and offset >= last_part_end:
            blocks_count_lo = struct.unpack('<I', data[offset+4:offset+8])[0]
            block_size_field = 1024 << struct.unpack('<H', data[offset+0x5a:offset+0x5c])[0]
            if block_size_field == 0:
                block_size_field = BLOCK_SIZE
            est_size = blocks_count_lo * block_size_field
            volume_name = data[offset+0x70:offset+0x86].split(b'\x00')[0].decode('ascii', errors='replace').strip()
            part_name = volume_name if volume_name else f"part_{offset//1024//1024}MB"
            log(f"[+] Ext4: {part_name} at {offset}, size ~{est_size}")
            partitions.append((offset, min(est_size, len(data) - offset), part_name))
            last_part_end = offset + est_size
            offset += BLOCK_SIZE
        else:
            offset += BLOCK_SIZE

    if not partitions:
        log("[-] No partitions found in super image")
        return False

    log(f"\n[+] Found {len(partitions)} partitions, extracting...")
    for i, (part_offset, part_size, part_name) in enumerate(partitions):
        if part_size <= 0:
            continue
        name = part_name.lower().replace(' ', '_')
        out_file = os.path.join(out_dir, f"{name}.img")
        log(f"[+] Extracting {i}: {name} ({part_size} bytes at {part_offset})")
        with open(out_file, 'wb') as f:
            pos = part_offset
            remaining = part_size
            while remaining > 0 and pos < len(data):
                chunk = min(remaining, 64*1024*1024)
                f.write(data[pos:pos+chunk])
                pos += chunk
                remaining -= chunk
        log(f"    -> {os.path.getsize(out_file)} bytes")
    return True

def main():
    if len(sys.argv) < 3:
        log(f"Usage: {sys.argv[0]} <super.img> <output_dir>")
        sys.exit(1)

    super_img = sys.argv[1]
    out_dir = sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    size = os.path.getsize(super_img)
    log(f"[+] Super image: {super_img} ({size/1024/1024/1024:.2f} GB)")

    with open(super_img, 'rb') as f:
        data = f.read()

    # Try LP_MAGIC first
    if len(data) >= 4 and data[:4] == b'\x69\x32\x33\x34':
        log("[+] LP_MAGIC found")
        if extract_lp(data, out_dir):
            return

    # Fallback: scan for ext4
    if extract_ext4_scan(data, out_dir):
        return

    log("[-] All extraction methods failed")
    sys.exit(1)

if __name__ == '__main__':
    main()
