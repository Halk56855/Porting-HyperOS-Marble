#!/usr/bin/env bash
# =============================================================================
#  port_extras.sh - tambahan untuk scripts/port.sh (disesuaikan untuk Galaxy A04)
#
#  Memakai helper dan variabel dari port.sh:
#    log ok warn die is_true get_prop set_prop
#    P_FS B_FS TOOLS_DIR WORK SCRIPT_DIR TARGET_DEVICE
#
#  Catatan:
#    - Fitur khusus marble & xiaomi.eu dinonaktifkan secara default untuk A04.
#    - Fungsi tetap dipertahankan agar kompatibel dengan pemanggilan dari port.sh.
# =============================================================================

AOD_FIX=${AOD_FIX:-false}          # false = nonaktif (khusus overlay doze marble/MIUI)
MILLET_FIX=${MILLET_FIX:-false}    # false = nonaktif (netlink millet khusus kernel Xiaomi)
ALLOW_XIAOMI_EU_EXTRAS=${ALLOW_XIAOMI_EU_EXTRAS:-false}

# ------------------------------------------------------------------ helper APK
apk_tool() {
    local mode=$1 in=$2 out=$3 at="$TOOLS_DIR/bin/apktool"
    if [[ -f $at/apktool ]]; then
        chmod +x "$at/apktool" 2>/dev/null || true
        "$at/apktool" "$mode" "$in" -o "$out" -f > "$WORK/apktool.log" 2>&1
    elif command -v apktool >/dev/null; then
        apktool "$mode" "$in" -o "$out" -f > "$WORK/apktool.log" 2>&1
    elif [[ -f $at/APKEditor.jar ]]; then
        java -jar "$at/APKEditor.jar" "$mode" -i "$in" -o "$out" -f > "$WORK/apktool.log" 2>&1
    else
        echo "apktool/APKEditor tidak ditemukan di $at maupun PATH" > "$WORK/apktool.log"
        return 127
    fi
}

apk_sign() {
    local apk=$1 ks="$WORK/port_test.jks"
    if ! command -v apksigner >/dev/null; then
        warn "sign: apksigner tidak ada, $(basename "$apk") tidak ditandatangani"
        return 0
    fi
    if command -v zipalign >/dev/null; then
        zipalign -f -p 4 "$apk" "$apk.al" && mv -f "$apk.al" "$apk" || true
    fi
    if [[ ! -f $ks ]]; then
        keytool -genkeypair -keystore "$ks" -storepass android -keypass android -alias port \
            -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=port" >/dev/null 2>&1 \
            || { warn "sign: keytool gagal membuat kunci uji"; return 0; }
    fi
    if apksigner sign --ks "$ks" --ks-pass pass:android --key-pass pass:android "$apk" >/dev/null 2>&1; then
        ok "sign: $(basename "$apk") ditandatangani"
    else
        warn "sign: apksigner gagal untuk $(basename "$apk")"
    fi
}

# ------------------------------------------------------------------ AOD (nonaktif untuk A04)
fix_aod_overlay() {
    if ! is_true "$AOD_FIX"; then
        log "AOD: dinonaktifkan untuk ${TARGET_DEVICE:-a04} (AOD_FIX=$AOD_FIX)"
        return 0
    fi
    log "AOD: diaktifkan secara manual (AOD_FIX=true)"
}

# ------------------------------------------------------------------ Millet (nonaktif untuk A04)
millet_fix() {
    if ! is_true "$MILLET_FIX"; then
        log "Millet: dinonaktifkan untuk ${TARGET_DEVICE:-a04} (MILLET_FIX=$MILLET_FIX)"
        return 0
    fi
    log "Millet: diaktifkan secara manual (MILLET_FIX=true)"
}

# ------------------------------------------------------------------ device_features
unlock_device_features() {
    local d="$P_FS/product/etc/device_features" out
    local feats=${UNLOCK_FEATURES:-none}
    case ${feats,,} in
        ""|none|off|false)
            log "device_features: dilewati (UNLOCK_FEATURES=${feats:-none})"
            return 0
            ;;
    esac
    if [[ ! -d $d ]]; then
        log "device_features: folder $d tidak ada pada ${TARGET_DEVICE:-a04}, dilewati"
        return 0
    fi
    # shellcheck disable=SC2086
    if ! out=$(python3 "$SCRIPT_DIR/device_features_unlock.py" "$d" $feats 2>&1); then
        warn "device_features: unlock gagal, file dibiarkan seperti semula"
        return 0
    fi
    while IFS= read -r f; do printf '    %s\n' "$f"; done <<< "$out"
    ok "device_features: selesai"
}

# ------------------------------------------------------------------ file dasar dari base
files_from_base() {
    local b p
    b="$B_FS/product/media/bootanimation.zip"
    p="$P_FS/product/media/bootanimation.zip"
    if [[ -f $b && -d $P_FS/product ]]; then
        mkdir -p "$(dirname "$p")"
        cp -f "$b" "$p"
        ok "bootanimation.zip disalin dari base"
    else
        log "bootanimation.zip: tidak disalin (tidak ada di base atau target bukan MIUI/HyperOS)"
    fi
}

# ------------------------------------------------------------------ Branding (xiaomi.eu dinonaktifkan)
ROM_AUTHOR=${ROM_AUTHOR:-}
BRANDING_BUILD_HOST=${BRANDING_BUILD_HOST:-false}

branding_build_host() {
    if ! is_true "$BRANDING_BUILD_HOST"; then
        log "Branding: ro.build.host tidak diubah (BRANDING_BUILD_HOST=false)"
        return 1
    fi
    if declare -F donor_is_eu >/dev/null && donor_is_eu && ! is_true "$ALLOW_XIAOMI_EU_EXTRAS"; then
        log "Branding: penyesuaian khusus xiaomi.eu dilewati"
        return 1
    fi
    return 1
}

rom_branding() {
    if ! is_true "$ALLOW_XIAOMI_EU_EXTRAS"; then
        log "Branding: fitur branding khusus xiaomi.eu/marble dinonaktifkan untuk ${TARGET_DEVICE:-a04}"
        return 0
    fi
    if [[ -z $ROM_AUTHOR ]]; then
        log "Branding: ROM_AUTHOR kosong, dilewati"
        return 0
    fi
    log "Branding: dijalankan dengan ALLOW_XIAOMI_EU_EXTRAS=true"
}
