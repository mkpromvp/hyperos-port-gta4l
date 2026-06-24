#!/usr/bin/env python3
"""
Create Android super image from partition images.
Fallback when lpmake is not available.
"""
import argparse
import hashlib
import os
import struct
import sys

# Android LP (Logical Partition) metadata structures
LP_MAGIC = b'\x69\x32\x33\x34'  # 0x34333269
LP_METADATA_HEADER_FORMAT = '<4sIIIIIIIII'
LP_METADATA_HEADER_SIZE = struct.calcsize(LP_METADATA_HEADER_FORMAT)
LP_PARTITION_ENTRY_SIZE = 64
LP_EXTENT_ENTRY_SIZE = 32

def align_to(val, align):
    return ((val + align - 1) // align) * align

def create_super_image(partitions, output, block_size=4096, alignment=1048576):
    """
    Create a minimal super image.
    partitions: list of dicts with 'name', 'image_path', 'size'
    """
    print(f"[+] Creating super image: {output}")
    print(f"    Partitions: {len(partitions)}")
    for p in partitions:
        print(f"    - {p['name']}: {p['size']} bytes (from {p['image_path']})")

    total_metadata_size = 4096 * 16  # 64KB for metadata
    header_offset = 0

    with open(output, 'wb') as super_f:
        # Calculate total size needed
        data_start = align_to(total_metadata_size, alignment)
        current_offset = data_start

        # Write metadata header
        super_f.seek(0)
        super_f.write(b'\x00' * (data_start + sum(p['size'] for p in partitions)))

        # Write partition data and build extent table
        extents = []
        partitions_entries = []

        for i, part in enumerate(partitions):
            img_path = part['image_path']
            part_size = part['size']
            part_name = part['name']

            if not os.path.exists(img_path):
                print(f"[-] Image not found: {img_path}")
                continue

            # Read image data
            with open(img_path, 'rb') as img_f:
                data = img_f.read()

            actual_size = len(data)
            aligned_size = align_to(actual_size, block_size)

            # Pad if needed
            if aligned_size > actual_size:
                data += b'\x00' * (aligned_size - actual_size)

            # Write to super image
            super_f.seek(current_offset)
            super_f.write(data)

            # Calculate sector offset (512-byte sectors)
            sector_offset = current_offset // 512
            num_sectors = actual_size // 512
            if actual_size % 512:
                num_sectors += 1

            # Create extent entry
            extent = struct.pack('<II4xQQ',
                1,  # num_sectors (updated below)
                1,  # target_type (linear)
                sector_offset,
                num_sectors
            )
            # Fix num_blocks field (first 4 bytes)
            extent = struct.pack('<I', num_sectors) + extent[4:]
            extents.append(extent)

            # Create partition entry
            name_bytes = part_name.encode('ascii')[:36]
            name_bytes += b'\x00' * (36 - len(name_bytes))
            partition_entry = struct.pack('<36sIIIIII',
                name_bytes,
                1,  # attributes: readonly
                1,  # first_extent_index
                0,  # num_extents (updated below)
                0,  # group_index
                0,  # padding
                i   # partition_index (0-based)
            )
            # Fix attributes
            partition_entry = struct.pack('<36sI', name_bytes, 0) + partition_entry[40:]
            partitions_entries.append(partition_entry)

            print(f"[+] Wrote {part_name}: {actual_size} bytes @ sector {sector_offset}")
            current_offset += aligned_size

        # Update extent count in each partition entry
        extent_start = 0
        for i, p_entry in enumerate(partitions_entries):
            num_extents = 1  # one extent per partition
            # Rebuild with correct extent count
            entry_data = bytearray(p_entry)
            struct.pack_into('<I', entry_data, 44, extent_start)  # first_extent_index
            struct.pack_into('<I', entry_data, 48, num_extents)   # num_extents
            partitions_entries[i] = bytes(entry_data)
            extent_start += num_extents

        # Build metadata
        num_partitions = len(partitions_entries)
        num_extents_total = len(extents)

        # Write metadata at the beginning
        super_f.seek(0)

        # Header
        header = struct.pack(LP_METADATA_HEADER_FORMAT,
            LP_MAGIC,
            10,  # version
            LP_METADATA_HEADER_SIZE,  # header_size
            LP_METADATA_HEADER_SIZE,  # header_size (same)
            num_partitions,  # num_partitions
            36,  # max_volume_name_length
            num_extents_total,  # num_extents
            num_extents_total,  # num_extents (same)
            0,  # first_logical_sector (will fill in)
            0,  # last_logical_sector
            alignment,  # alignment
            0,  # alignment_offset
            block_size,  # block_size
            current_offset  # super partition size
        )

        super_f.write(header)

        # Write partition entries
        for p_entry in partitions_entries:
            super_f.write(p_entry)

        # Write extent entries
        for ext in extents:
            super_f.write(ext)

        # Calculate first and last sectors
        first_sector = data_start // 512
        last_sector = current_offset // 512

        # Update header with correct sector values
        super_f.seek(LP_METADATA_HEADER_SIZE - 8 - 8 - 4 - 4)
        super_f.write(struct.pack('<QQ', first_sector, last_sector))

    actual_output_size = os.path.getsize(output)
    print(f"[+] Super image created: {actual_output_size} bytes")
    print(f"    Partitions: {num_partitions}, Extents: {num_extents_total}")
    return actual_output_size

def main():
    parser = argparse.ArgumentParser(description='Create Android super image')
    parser.add_argument('--system', help='System image path', required=True)
    parser.add_argument('--vendor', help='Vendor image path')
    parser.add_argument('--product', help='Product image path')
    parser.add_argument('--odm', help='ODM image path')
    parser.add_argument('--output', help='Output super image path', required=True)
    parser.add_argument('--block-size', help='Block size', type=int, default=4096)
    parser.add_argument('--alignment', help='Alignment in bytes', type=int, default=1048576)

    args = parser.parse_args()

    partitions = []

    for name, path in [('system', args.system), ('vendor', args.vendor),
                       ('product', args.product), ('odm', args.odm)]:
        if path and os.path.exists(path):
            size = os.path.getsize(path)
            aligned = align_to(size, args.block_size)
            partitions.append({
                'name': name,
                'image_path': path,
                'size': aligned
            })

    if not partitions:
        print("[-] No valid partition images provided")
        sys.exit(1)

    create_super_image(partitions, args.output, args.block_size, args.alignment)

if __name__ == '__main__':
    main()
