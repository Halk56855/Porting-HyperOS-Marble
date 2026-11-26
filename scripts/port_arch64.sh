#!/usr/bin/env bash
# =============================================================================
#  port_arch64.sh - penyesuaian arsitektur untuk Samsung Galaxy A04
#  (di-source oleh port.sh; dinonaktifkan secara default agar tidak memaksakan
#   aturan 64-bit-only / QCOM milik marble ke perangkat Galaxy A04)
# =============================================================================

ARCH64_FIX=${ARCH64_FIX:-false}
ARCH64_COPY_LIB=${ARCH64_COPY_LIB:-false}

a64_donor_is_64only() {
    local sys="$P_FS/system/system" list no_lib=0 no_abi=0
    list=$(get_prop "$sys/build.prop" ro.system.product.cpu.abilist)
    if [[ -z $(find "$sys/lib" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true) ]]; then no_lib=1; fi
    if [[ -n $list && $list != *armeabi-v7a* ]]; then no_abi=1; fi
    log "arch64: donor abilist='${list:-?}' | system/lib $([[ $no_lib == 1 ]] && echo kosong/tidak ada || echo ada)"
    [[ $no_lib == 1 || $no_abi == 1 ]]
}

a64_take() {
    local rel=$1 s="$A64_BASE_SYS/$1" d="$P_FS/system/system/$1"
    if [[ ! -e $s && ! -L $s ]]; then warn "arch64: $rel tidak ada di base, dilewati"; return 1; fi
    rm -rf "$d"
    mkdir -p "$(dirname "$d")"
    cp -a "$s" "$d"
    printf 'system/system/%s\n' "$1" >> "$A64_LIST_SYS"
    if [[ -L $s ]]; then ok "arch64: system/$rel <- base (symlink -> $(readlink "$s"))"
    else ok "arch64: system/$rel <- base"; fi
}

a64_prop() {
    local f=$1 kv k v g; shift
    [[ -f $f ]] || { warn "arch64: ${f#"$B_FS"/} tidak ada, props dilewati"; return 0; }
    for kv in "$@"; do
        k=${kv%%=*}; v=${kv#*=}
        set_prop "$f" "$k" "$v"
        for g in "$(dirname "$f")"/*build.prop; do
            [[ -f $g && $g != "$f" ]] || continue
            if grep -qE "^${k//./\\.}=" "$g"; then set_prop "$g" "$k" "$v"; fi
        done
    done
    ok "arch64: props ${f#"$B_FS"/} -> $*"
}

a64_record_new() {
    local src=$1 dst=$2 pre=$3 list=$4 m=$5 rel
    while IFS= read -r -d '' rel; do
        if [[ $m == true || ( ! -e $dst/$rel && ! -L $dst/$rel ) ]]; then printf '%s\n' "$pre/$rel" >> "$list"; fi
    done < <(find "$src" -mindepth 1 -printf '%P\0')
}

a64_sync_cfg() {
    local part=$1 bcfg=$2 list=$3 out kind hit miss
    [[ -s $list ]] || return 0
    out=$(python3 - "$bcfg" "$P_FS/config" "$part" "$list" <<'PY'
import os, re, sys
bdir, pdir, part, listf = sys.argv[1:5]
paths = [l.rstrip("\n") for l in open(listf, encoding="utf-8") if l.strip()]
esc = lambda k: re.sub(r"([^-_/a-zA-Z0-9])", r"\\\1", k)
def load(fn, unesc):
    d = {}
    if os.path.isfile(fn):
        for line in open(fn, encoding="utf-8", errors="replace"):
            line = line.rstrip("\n")
            if line.strip():
                k, _, rest = line.partition(" ")
                d[k.replace("\\", "") if unesc else k] = rest
    return d
for kind, prefix in (("fs_config", ""), ("file_contexts", "/")):
    bfn = os.path.join(bdir, "%s_%s" % (part, kind))
    pfn = os.path.join(pdir, "%s_%s" % (part, kind))
    base = load(bfn, kind == "file_contexts")
    port = load(pfn, kind == "file_contexts")
    hit = miss = 0
    for p in paths:
        k = prefix + p
        if k in base:
            port[k] = base[k]
            hit += 1
        else:
            miss += 1
    if hit:
        with open(pfn, "w", encoding="utf-8", newline="\n") as f:
            for k in sorted(port):
                f.write("%s %s\n" % (esc(k) if kind == "file_contexts" else k, port[k]))
    print("%s %d %d" % (kind, hit, miss))
PY
) || { warn "arch64: sinkron config $part gagal"; return 0; }
    while read -r kind hit miss; do
        if [[ ${miss:-0} -gt 0 ]]; then
            warn "arch64: $part $kind: $miss path tidak ada di config base, $hit disalin dari base"
        else
            ok "arch64: $part $kind: $hit entri disalin dari config base"
        fi
    done <<< "$out"
}

a64_strip_omx_hal() {
    local f n
    for f in "$@"; do
        [[ -f $f ]] || continue
        n=$(python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="replace").read()
removed = 0
def drop(m):
    global removed
    if re.search(r"<name>\s*android\.hardware\.media\.omx\s*</name>", m.group(0)):
        removed += 1
        return ""
    return m.group(0)
t = re.sub(r"<hal\b.*?</hal>", drop, s, flags=re.S)
if removed:
    open(p, "w", encoding="utf-8").write(t)
print(removed)
PY
)
        if [[ ${n:-0} -gt 0 ]]; then ok "arch64: HAL media.omx dihapus dari ${f#"$B_FS"/} ($n blok)"; fi
    done
}

arch64_fix() {
    local mode=${ARCH64_FIX,,} root sysdir f n rc
    case $mode in
        false|off|no|0)
            log "arch64: dinonaktifkan untuk ${TARGET_DEVICE:-a04} (ARCH64_FIX=$ARCH64_FIX)"
            return 0
            ;;
        auto)
            log "arch64: mode auto tidak dijalankan otomatis pada ${TARGET_DEVICE:-a04}; set ARCH64_FIX=true jika memang diperlukan"
            return 0
            ;;
        true|on|yes|1)
            ;;
        *)
            warn "arch64: nilai ARCH64_FIX='$ARCH64_FIX' tidak dikenal (false|true), dilewati"
            return 0
            ;;
    esac

    log "arch64: dijalankan secara manual untuk ${TARGET_DEVICE:-a04}"
    root="$WORK/base_arch"; rm -rf "$root"; mkdir -p "$root"
    A64_LIST_SYS="$WORK/arch64_paths_system.txt"; A64_LIST_EXT="$WORK/arch64_paths_system_ext.txt"
    : > "$A64_LIST_SYS"; : > "$A64_LIST_EXT"

    if [[ -n ${A64_BASE_SYS_OVERRIDE:-} ]]; then
        A64_BASE_SYS=$A64_BASE_SYS_OVERRIDE
        A64_BASE_CFG=${A64_BASE_CFG_OVERRIDE:-$root/config}
    else
        [[ -f $B_IMG/system.img ]] || { warn "arch64: $B_IMG/system.img tidak ada"; return 0; }
        extract_img "$B_IMG/system.img" "$root"
        A64_BASE_SYS="$root/system/system"
        [[ -d $A64_BASE_SYS/bin ]] || A64_BASE_SYS="$root/system"
        A64_BASE_CFG="$root/config"
    fi
    sysdir="$P_FS/system/system"

    for f in bin/linker bin/linker_asan bin/bootstrap/linker bin/bootstrap/linker_asan; do a64_take "$f" || true; done
    for f in bin/vold bin/vold_prepare_subdirs; do
        if a64_take "$f"; then chmod 0755 "$sysdir/$f" 2>/dev/null || true; fi
    done

    local cp_mode=${ARCH64_COPY_LIB,,} cpo=(-a)
    case $cp_mode in
        auto) cpo=(-a --update=none) ;;
        true|on|yes|1) cpo=(-a) ;;
        false|off|no|0) cp_mode=false ;;
        *) cp_mode=false ;;
    esac

    if [[ $cp_mode != false && -d $A64_BASE_SYS/lib ]]; then
        a64_record_new "$A64_BASE_SYS/lib" "$sysdir/lib" system/system/lib "$A64_LIST_SYS" "$cp_mode"
        mkdir -p "$sysdir/lib"; cp "${cpo[@]}" "$A64_BASE_SYS/lib/." "$sysdir/lib/"
        ok "arch64: system/lib disalin dari base (mode $cp_mode)"
    fi

    a64_sync_cfg system "$A64_BASE_CFG" "$A64_LIST_SYS"

    if is_true "${ARCH64_SET_PROPS:-false}"; then
        a64_prop "$B_FS/odm/etc/build.prop" \
            ro.odm.product.cpu.abilist=arm64-v8a ro.odm.product.cpu.abilist32= ro.odm.product.cpu.abilist64=arm64-v8a \
            ro.zygote=zygote64 dalvik.vm.dex2oat64.enabled=true
        a64_prop "$B_FS/vendor/build.prop" \
            ro.vendor.product.cpu.abilist=arm64-v8a ro.vendor.product.cpu.abilist32= ro.vendor.product.cpu.abilist64=arm64-v8a \
            ro.zygote=zygote64 dalvik.vm.dex2oat64.enabled=true
    fi

    if is_true "${ARCH64_STRIP_OMX:-false}"; then
        n=0
        while IFS= read -r -d '' rc; do
            rm -f "$rc"; n=$((n + 1)); ok "arch64: vendor/etc/init/$(basename "$rc") dihapus"
        done < <(find "$B_FS/vendor/etc/init" -maxdepth 1 -type f -iname '*omx*' -print0 2>/dev/null || true)
        a64_strip_omx_hal "$B_FS"/vendor/etc/vintf/manifest*.xml "$B_FS"/vendor/etc/vintf/manifest/*.xml \
                          "$B_FS"/odm/etc/vintf/manifest*.xml "$B_FS"/odm/etc/vintf/manifest/*.xml
    fi

    rm -rf "$root"
}
