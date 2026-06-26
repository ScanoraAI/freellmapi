#!/bin/bash
BINARY=/home/zfr6rwssd45a/nodevenv/freellm-backend/24/lib/node_modules/better-sqlite3/build/Release/better_sqlite3.node

if [ ! -f "$BINARY" ]; then
  echo "[patch-sqlite] Binary not found, skipping."
  exit 0
fi

echo "[patch-sqlite] Applying patchelf..."
~/patchelf --clear-symbol-version log $BINARY
~/patchelf --clear-symbol-version pow $BINARY
~/patchelf --clear-symbol-version log2 $BINARY
~/patchelf --clear-symbol-version exp $BINARY

echo "[patch-sqlite] Applying verneed patch..."
python3 << 'PYEOF'
import struct, sys
path = '/home/zfr6rwssd45a/nodevenv/freellm-backend/24/lib/node_modules/better-sqlite3/build/Release/better_sqlite3.node'
with open(path, 'rb') as f:
    data = bytearray(f.read())
e_shoff = struct.unpack_from('<Q', data, 40)[0]
e_shentsize = struct.unpack_from('<H', data, 58)[0]
e_shnum = struct.unpack_from('<H', data, 60)[0]
verneed_offset = verneed_size = dynstr_offset = None
for i in range(e_shnum):
    sh = e_shoff + i * e_shentsize
    sh_type = struct.unpack_from('<I', data, sh + 4)[0]
    sh_flags = struct.unpack_from('<Q', data, sh + 8)[0]
    sh_offset = struct.unpack_from('<Q', data, sh + 24)[0]
    sh_size = struct.unpack_from('<Q', data, sh + 32)[0]
    if sh_type == 0x6ffffffe:
        verneed_offset, verneed_size = sh_offset, sh_size
    if sh_type == 3 and sh_flags == 2:
        dynstr_offset = sh_offset
if verneed_offset is None:
    print('[patch-sqlite] No verneed section, skipping.')
    sys.exit(0)
pos = verneed_offset
while pos < verneed_offset + verneed_size:
    vn_cnt = struct.unpack_from('<H', data, pos + 2)[0]
    vn_file = struct.unpack_from('<I', data, pos + 4)[0]
    vn_aux = struct.unpack_from('<I', data, pos + 8)[0]
    vn_next = struct.unpack_from('<I', data, pos + 12)[0]
    file_name = bytes(data[dynstr_offset + vn_file:dynstr_offset + vn_file + 20]).split(b'\x00')[0]
    aux_pos = pos + vn_aux
    prev_aux_pos = None
    for j in range(vn_cnt):
        vna_name = struct.unpack_from('<I', data, aux_pos + 8)[0]
        vna_next = struct.unpack_from('<I', data, aux_pos + 12)[0]
        name = bytes(data[dynstr_offset + vna_name:dynstr_offset + vna_name + 20]).split(b'\x00')[0]
        if file_name == b'libm.so.6' and name == b'GLIBC_2.29':
            print(f'[patch-sqlite] Removing {name.decode()} from {file_name.decode()}')
            if prev_aux_pos is not None:
                struct.pack_into('<I', data, prev_aux_pos + 12, vna_next if vna_next else 0)
            else:
                if vna_next:
                    struct.pack_into('<I', data, pos + 8, vn_aux + vna_next)
            struct.pack_into('<H', data, pos + 2, vn_cnt - 1)
        prev_aux_pos = aux_pos
        if vna_next == 0:
            break
        aux_pos += vna_next
    if vn_next == 0:
        break
    pos += vn_next
with open(path, 'wb') as f:
    f.write(data)
print('[patch-sqlite] Done.')
PYEOF

echo "[patch-sqlite] Complete."
