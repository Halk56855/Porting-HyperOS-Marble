#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  scripts/port.sh - Port ROM builder disesuaikan untuk Samsung Galaxy A04 (SM-A045F)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET_DEVICE=${TARGET_DEVICE:-SM-A045F}
PORT_VERSION=${PORT_VERSION:-HyperOS_Port_A045F}
ROM_AUTHOR=${ROM_AUTHOR:-}
ANTI_VER=${ANTI_VER:-}
FLASH_RECOVERY=${FLASH_RECOVERY:-false}

BASE_ROM=${BASE_ROM:-}
PORT_ROM=${PORT_ROM:-}
SUPER_SIZE=${SUPER_SIZE:-auto}
SUPER_FORMAT=${SUPER_FORMAT:-raw}   # raw | zst
OUT_DIR=${OUT_DIR:-"$REPO_ROOT/out"}
WORK=${WORK:-"$REPO_ROOT/work"}
TOOLS_DIR=${TOOLS_DIR:-"$REPO_ROOT/tools"}
BIN=${BIN:-"$TOOLS_DIR/bin"}

# إعدادات التوافق مع SM-A045F (تعطيل افتراضي لخصائص marble وxiaomi.eu)
MILLET_FIX=${MILLET_FIX:-false}
AOD_FIX=${AOD_FIX:-false}
ALLOW_XIAOMI_EU_EXTRAS=${ALLOW_XIAOMI_EU_EXTRAS:-false}
BRANDING_BUILD_HOST=${BRANDING_BUILD_HOST:-false}
ARCH64_FIX=${ARCH64_FIX:-false}
ARCH64_COPY_LIB=${ARCH64_COPY_LIB:-false}
APPS_FROM_URL=${APPS_FROM_URL:-false}
GMS_FROM_BASE=${GMS_FROM_BASE:-auto}
BROWSER_FALLBACK=${BROWSER_FALLBACK:-auto}

AB_IMAGES=${AB_IMAGES:-""}
NONAB_IMAGES=${NONAB_IMAGES:-"boot dtbo vbmeta vbmeta_system vbmeta_vendor recovery"}

B_WORK="$WORK/base"
P_WORK="$WORK/port"
B_IMG="$B_WORK/imgs"
P_IMG="$P_WORK/imgs"
B_FS="$B_WORK/fs"
P_FS="$P_WORK/fs"
STAGE_DIR="$WORK/zip_stage"

# ------------------------------------------------------------------ Helpers
log()  { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERR ] %s\n' "$*" >&2; exit 1; }

is_true() {
    case "${1:-}" in
        true|TRUE|True|1|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

get_prop() {
    local file=$1 key=$2
    [[ -f $file ]] || { echo ""; return 0; }
    sed -n "s/^${key//./\\.}=//p" "$file" | head -n1 || true
}

set_prop() {
    local file=$1 key=$2 val=$3 esc_key esc_val
    mkdir -p "$(dirname "$file")"
    touch "$file"
    esc_key=${key//./\\.}
    esc_val=${val//&/\\&}
    if grep -qE "^${esc_key}=" "$file"; then
        sed -i "s|^${esc_key}=.*|${key}=${esc_val}|" "$file"
    else
        printf '%s=%s\n' "$key" "$val" >> "$file"
    fi
}

donor_is_eu() {
    local prop_val
    prop_val=$(cat "$P_FS/system/system/build.prop" "$P_FS/product/etc/build.prop" "$P_FS/mi_ext/etc/build.prop" 2>/dev/null || true)
    grep -qiE 'xiaomi\.eu|eu\.miui' <<< "$prop_val"
}

base_privapp_perms() {
    local rel_dir=$1 src_etc dst_etc
    src_etc="$B_FS/product/etc/permissions"
    dst_etc="$P_FS/product/etc/permissions"
    [[ -d $src_etc ]] || return 0
    mkdir -p "$dst_etc"
    cp -rn "$src_etc"/. "$dst_etc/" 2>/dev/null || true
    log "Privapp perms disalin dari base untuk $rel_dir"
}

check_url() {
    local name=$1 url=$2
    if [[ $url =~ ^https?:// ]]; then
        command -v curl >/dev/null || die "$name: curl tidak tersedia untuk memeriksa $url"
        curl -fsI "$url" >/dev/null || die "$name: URL tidak dapat diakses ($url)"
    elif [[ ! -f $url ]]; then
        die "$name: file lokal tidak ditemukan ($url)"
    fi
}

fetch() {
    local src=$1 dst_dir=$2 prefix=$3 out
    mkdir -p "$dst_dir"
    if [[ $src =~ ^https?:// ]]; then
        out="$dst_dir/${prefix}_download"
        curl -fsSL "$src" -o "$out" || die "Gagal mengunduh $src"
        echo "$out"
    else
        [[ -f $src ]] || die "File tidak ditemukan: $src"
        echo "$src"
    fi
}

find_tool() {
    local name=$1
    if [[ -x "$BIN/$name" ]]; then echo "$BIN/$name"; return 0; fi
    if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
    return 1
}

# ------------------------------------------------------------------ استخراج الصور والملفات
decompress_lz4_tree() {
    local dir=$1 f
    command -v lz4 >/dev/null 2>&1 || return 0
    while IFS= read -r -d '' f; do
        lz4 -df --rm "$f" "${f%.lz4}" >/dev/null 2>&1 || true
    done < <(find "$dir" -type f -name '*.lz4' -print0 2>/dev/null || true)
}

unpack_source_to_imgs() {
    local src=$1 out_imgs=$2 tmp="$WORK/unpack_$$"
    [[ -n $src ]] || die "Path ROM kosong"
    rm -rf "$out_imgs" "$tmp"
    mkdir -p "$out_imgs" "$tmp"

    if [[ -d $src ]]; then
        log "Menyalin gambar/paket dari direktori: $src"
        cp -a "$src"/. "$tmp/"
    elif [[ -f $src ]]; then
        log "Mengekstrak arsip: $src"
        case "$src" in
            *.zip) unzip -q "$src" -d "$tmp" ;;
            *.tar.md5|*.tar) tar -xf "$src" -C "$tmp" ;;
            *.img) cp -f "$src" "$tmp/" ;;
            *) die "Format sumber tidak didukung: $src" ;;
        esac
    else
        die "Sumber ROM tidak ditemukan: $src"
    fi

    # Ekstrak file AP_*.tar.md5 / *.tar di dalamnya bila ada
    local t
    while IFS= read -r -d '' t; do
        tar -xf "$t" -C "$tmp" 2>/dev/null || true
    done < <(find "$tmp" -maxdepth 2 -type f \( -name 'AP*.tar*' -o -name '*.tar' -o -name '*.tar.md5' \) -print0 2>/dev/null || true)

    decompress_lz4_tree "$tmp"

    # Salin semua file .img ke direktori gambar
    find "$tmp" -type f -name '*.img' -exec cp -f {} "$out_imgs/" \;

    # Jika ada super.img, ekstrak partisi logisnya jika lpunpack tersedia
    if [[ -f "$out_imgs/super.img" ]]; then
        local lpunpack_bin
        if lpunpack_bin=$(find_tool lpunpack 2>/dev/null); then
            log "Mengekstrak partisi dari super.img menggunakan $lpunpack_bin"
            "$lpunpack_bin" "$out_imgs/super.img" "$out_imgs/" >/dev/null 2>&1 || true
        fi
    fi

    rm -rf "$tmp"
    [[ -n "$(find "$out_imgs" -maxdepth 1 -name '*.img' -print -quit)" ]] || die "Tidak ada file .img yang berhasil disiapkan dari $src"
}

extract_img() {
    local img=$1 dest=$2
    [[ -f $img ]] || die "File image tidak ada: $img"
    mkdir -p "$dest" "$dest/config"
    if [[ -x "$SCRIPT_DIR/img_extract.py" ]]; then
        python3 "$SCRIPT_DIR/img_extract.py" "$img" "$dest"
        return 0
    fi
    if command -v debugfs >/dev/null 2>&1; then
        local magic
        magic=$(od -An -tx1 -j 1080 -N 2 "$img" 2>/dev/null | tr -d ' \n' || true)
        if [[ $magic == "53ef" ]]; then
            rdump_ext4 "$img" "$dest"
            return 0
        fi
    fi
    local erofs_bin
    if erofs_bin=$(find_tool extract.erofs 2>/dev/null); then
        "$erofs_bin" -i "$img" -o "$dest" >/dev/null 2>&1 && return 0
    fi
    die "Tidak ada alat yang mendukung ekstraksi $img"
}

rdump_ext4() {
    local img=$1 dest=$2
    python3 - "$img" "$dest" <<'PY'
import os, subprocess, sys

img, dest = sys.argv[1], sys.argv[2]
os.makedirs(dest, exist_ok=True)
out = subprocess.check_output(["debugfs", "-R", "ls -p /", img], text=True, stderr=subprocess.DEVNULL)
for line in out.splitlines():
    parts = line.split("/")
    if len(parts) >= 6:
        name = parts[5]
        ftype = parts[3] if len(parts) > 3 else ""
        if name in ("", ".", ".."):
            continue
        if ftype.startswith("4"):
            subprocess.run(["debugfs", "-R", f"rdump /{name} {os.path.join(dest, name)}", img],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.run(["debugfs", "-R", f"dump /{name} {os.path.join(dest, name)}", img],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
}

# ------------------------------------------------------------------ تحميل السكربتات المساعدة
for extra in port_extras.sh port_arch64.sh port_gms.sh port_chrome.sh port_apps.sh; do
    if [[ -f "$SCRIPT_DIR/$extra" ]]; then
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/$extra"
    fi
done

# ------------------------------------------------------------------ خطوات البناء الرئيسية
detect_super_bytes() {
    if [[ -n $SUPER_SIZE && $SUPER_SIZE != "auto" ]]; then
        echo "$SUPER_SIZE"
        return 0
    fi
    if [[ -f "$B_IMG/super.img" ]]; then
        stat -c '%s' "$B_IMG/super.img"
        return 0
    fi
    # قيمة احتياطية آمنة (8 GiB) إذا لم يتوفر super.img خام
    echo "8589934592"
}

build_super_img() {
    local super_bytes=$1 out_super="$STAGE_DIR/images/super.img"
    local lpmake_bin
    mkdir -p "$STAGE_DIR/images"

    if [[ -f "$B_IMG/super.img" && ! -f "$P_IMG/system.img" ]]; then
        cp -f "$B_IMG/super.img" "$out_super"
        ok "Menyalin super.img dasar ke paket keluaran"
        return 0
    fi

    if lpmake_bin=$(find_tool lpmake 2>/dev/null); then
        local -a args=(
            --metadata-size 65536
            --super-name super
            --metadata-slots 2
            --device "super:${super_bytes}"
            --group "main:${super_bytes}"
            --output "$out_super"
        )
        local part img_path sz
        for part in system system_ext product vendor odm mi_ext vendor_dlkm system_dlkm odm_dlkm; do
            img_path=""
            if [[ -f "$P_IMG/${part}.img" ]]; then
                img_path="$P_IMG/${part}.img"
            elif [[ -f "$B_IMG/${part}.img" ]]; then
                img_path="$B_IMG/${part}.img"
            fi
            if [[ -n $img_path ]]; then
                sz=$(stat -c '%s' "$img_path")
                args+=(--partition "${part}:readonly:${sz}:main" --image "${part}=${img_path}")
            fi
        done
        "$lpmake_bin" "${args[@]}"
        ok "super.img berhasil dibuat dengan lpmake ($out_super)"
    elif [[ -f "$B_IMG/super.img" ]]; then
        cp -f "$B_IMG/super.img" "$out_super"
        warn "lpmake tidak ditemukan; menyalin super.img dari base"
    else
        die "Gagal membuat super.img: lpmake tidak tersedia dan base/super.img tidak ada"
    fi
}

generate_update_binary() {
    local super_bytes=$1
    local meta_dir="$STAGE_DIR/META-INF/com/google/android"
    local tpl="$SCRIPT_DIR/update-binary"
    [[ -f $tpl ]] || tpl="$REPO_ROOT/update-binary"
    [[ -f $tpl ]] || die "Template update-binary tidak ditemukan"

    mkdir -p "$meta_dir"
    sed \
        -e "s|@TARGET_DEVICE@|${TARGET_DEVICE}|g" \
        -e "s|@PORT_VERSION@|${PORT_VERSION}|g" \
        -e "s|@ANTI_VER@|${ANTI_VER}|g" \
        -e "s|@SUPER_FORMAT@|${SUPER_FORMAT}|g" \
        -e "s|@SUPER_BYTES@|${super_bytes}|g" \
        -e "s|@FLASH_RECOVERY@|${FLASH_RECOVERY}|g" \
        -e "s|@AB_IMAGES@|${AB_IMAGES}|g" \
        -e "s|@NONAB_IMAGES@|${NONAB_IMAGES}|g" \
        -e "s|@ROM_AUTHOR@|${ROM_AUTHOR}|g" \
        "$tpl" > "$meta_dir/update-binary"
    chmod 0755 "$meta_dir/update-binary"
    ok "update-binary dihasilkan untuk $TARGET_DEVICE"
}

package_zip() {
    local zip_name="${TARGET_DEVICE}_${PORT_VERSION}.zip"
    local zip_path="$OUT_DIR/$zip_name"
    mkdir -p "$OUT_DIR"
    rm -f "$zip_path"
    (
        cd "$STAGE_DIR"
        zip -rq "$zip_path" .
    )
    ok "Paket flashable selesai: $zip_path"
}

main() {
    log "Memulai proses port untuk perangkat: $TARGET_DEVICE"

    if declare -F apps_check_urls >/dev/null; then
        apps_check_urls
    fi

    [[ -n $BASE_ROM ]] || die "Variabel BASE_ROM belum diisi"
    [[ -n $PORT_ROM ]] || die "Variabel PORT_ROM belum diisi"

    unpack_source_to_imgs "$BASE_ROM" "$B_IMG"
    unpack_source_to_imgs "$PORT_ROM" "$P_IMG"

    rm -rf "$B_FS" "$P_FS" "$STAGE_DIR"
    mkdir -p "$B_FS" "$P_FS" "$STAGE_DIR/images" "$WORK"

    for p in system system_ext product vendor odm mi_ext; do
        if [[ -f "$B_IMG/${p}.img" ]]; then
            extract_img "$B_IMG/${p}.img" "$B_FS/$p"
        fi
        if [[ -f "$P_IMG/${p}.img" ]]; then
            extract_img "$P_IMG/${p}.img" "$P_FS/$p"
        fi
    done

    # Terapkan penyesuaian tambahan
    declare -F files_from_base >/dev/null && files_from_base
    declare -F fix_aod_overlay >/dev/null && fix_aod_overlay
    declare -F millet_fix >/dev/null && millet_fix
    declare -F unlock_device_features >/dev/null && unlock_device_features
    declare -F arch64_fix >/dev/null && arch64_fix
    declare -F gms_from_base >/dev/null && gms_from_base
    declare -F browser_fallback >/dev/null && browser_fallback
    declare -F apps_from_url >/dev/null && apps_from_url
    declare -F rom_branding >/dev/null && rom_branding

    # Salin gambar non-super (boot, dtbo, vbmeta, dll.) dari base bila ada
    local img_name
    for img_name in $NONAB_IMAGES $AB_IMAGES; do
        [[ -n $img_name ]] || continue
        if [[ -f "$B_IMG/${img_name}.img" ]]; then
            cp -f "$B_IMG/${img_name}.img" "$STAGE_DIR/images/${img_name}.img"
        fi
    done

    local super_bytes
    super_bytes=$(detect_super_bytes)
    build_super_img "$super_bytes"
    generate_update_binary "$super_bytes"
    package_zip

    ok "Selesai seluruhnya!"
}

main "$@"
