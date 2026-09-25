#!/usr/bin/env bash
#
# atlas_registry.sh - Registry-driven EXTRA MNI-space atlas support for the
#                     multi-atlas brainstem labeling path (multi_atlas.sh).
#
# WHY: every additional atlas used to require edits in ~8 places (multi_atlas.sh,
# analysis.sh discovery globs + provenance, reporting, visualization, the
# availability check, docs). This module turns an atlas into a CONFIG ENTRY:
#
#   MULTI_ATLAS_EXTRA="jhu xtract aan lc"      # registry keys (lower-case tags)
#   USE_<KEY>=true|false                        # enable
#   ATLAS_<KEY>_REL=<dir relative to ATLAS_DIR> # where the atlas lives
#   ATLAS_<KEY>_TYPE=dseg|prob4d|probdir|probmap
#   ATLAS_<KEY>_IMAGE=<file or dir, relative to REL>
#   ATLAS_<KEY>_LUT=<FSL .xml or "idx name" .txt, relative to REL or ATLAS_DIR>
#   ATLAS_<KEY>_SPACE=MNI152NLin6Asym (default, == FSL MNI152) | MNI152NLin2009cAsym
#   ATLAS_<KEY>_LUT_OFFSET=auto|0|1             # image value = LUT index + offset
#   ATLAS_<KEY>_PROB_THR=<0..1>                 # threshold for prob* types
#   ATLAS_<KEY>_LABELS="<idx|name ...>"         # optional subset (pons-relevant labels)
#   ATLAS_<KEY>_LABEL_REGEX=<regex>             # optional case-insensitive name selector
#   ATLAS_<KEY>_LUT_FORMAT=auto|xml|freesurfer|txt
#   ATLAS_<KEY>_RESTRICT=brainstem|none         # intersect with the HO brainstem extent
#   ATLAS_<KEY>_SUBDIV="<name_prefix>=<pons|midbrain|medulla> ..." # gross aggregation
#   ATLAS_<KEY>_DILATE=<n>                      # dilate tiny nuclei n voxels (subject space)
#   ATLAS_<KEY>_URL / _CITATION / _LICENSE      # informational (availability report, docs)
#
# Every key's masks land in segmentation/detailed_brainstem as
#   <key>_<name>_label<value>.nii.gz  (+ optional <key>_pons.nii.gz aggregates)
# and are discovered by analysis.sh:find_all_atlas_regions through the shared
# MULTI_ATLAS_SOURCE_TAGS list (config), so provenance/reporting/visualisation
# pick them up with NO further code changes.
#
# SPACE HANDLING (the classic silent bug): atlases distributed on the
# MNI152NLin2009cAsym grid are NOT on FSL's MNI152 (NLin6Asym) grid. Such an
# atlas is first brought into NLin6 space with the TemplateFlow
# tpl-MNI152NLin6Asym_from-MNI152NLin2009cAsym_mode-image_xfm.h5 transform
# (MNI_2009C_TO_NLIN6_XFM / TEMPLATEFLOW_HOME / ${ATLAS_DIR}/templateflow). When
# that transform is absent the atlas is SKIPPED with a WARNING — never warped
# through the wrong template.
#
# IMPORTANT: sourced module — do NOT set `set -e -u -o pipefail` here. Every
# failure path degrades gracefully (WARNING + return 0/1 to the caller).
#

# ── Include guard ────────────────────────────────────────────────────────────
if [ -n "${_ATLAS_REGISTRY_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_ATLAS_REGISTRY_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# Defaults (only when config did not provide them).
: "${ATLAS_DIR:=${FSLDIR:-}/data/atlases}"
: "${MULTI_ATLAS_CACHE_DIR:=${ATLAS_DIR}}"
: "${MULTI_ATLAS_EXTRA:=}"
: "${REG_LABEL_INTERPOLATION:=GenericLabel}"
: "${HO_SUB_MAXPROB_THR:=thr25}"

# ──────────────────────────────────────────────────────────────────────────────
# Registry accessors
# ──────────────────────────────────────────────────────────────────────────────

# _atlas_key_upper <key>  -> upper-case, non-alnum -> _
_atlas_key_upper() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_\n' '_'
}

# _atlas_cfg <key> <FIELD> [default] -> value of ATLAS_<KEY>_<FIELD> (or default)
_atlas_cfg() {
    local key="$1" field="$2" default="${3:-}"
    local var="ATLAS_$(_atlas_key_upper "$key")_${field}"
    printf '%s' "${!var:-$default}"
}

# _atlas_enabled <key> -> 0 when USE_<KEY> == true
_atlas_enabled() {
    local var="USE_$(_atlas_key_upper "$1")"
    [ "${!var:-false}" = "true" ]
}

# atlas_registry_keys -> the configured extra keys (space separated, may be empty)
atlas_registry_keys() {
    printf '%s' "${MULTI_ATLAS_EXTRA:-}"
}

# atlas_registry_source_tags -> every multi-atlas provenance tag, built-ins first.
# Downstream consumers (analysis/reporting/visualisation) iterate over this.
atlas_registry_source_tags() {
    local tags="bianciardi cit168 aal3"
    local k
    for k in $(atlas_registry_keys); do
        case " $tags " in *" $k "*) ;; *) tags="$tags $k" ;; esac
    done
    printf '%s' "$tags"
}

# _atlas_root <key> -> absolute atlas dir (ATLAS_DIR/REL)
_atlas_root() {
    local rel
    rel=$(_atlas_cfg "$1" REL "$1")
    printf '%s/%s' "${ATLAS_DIR}" "$rel"
}

# _atlas_resolve_path <key> <path> -> absolute path: as-is if absolute, else
# relative to the atlas root, else relative to ATLAS_DIR (FSL keeps the *.xml
# LUTs at the atlases root, next to the per-atlas dirs).
_atlas_resolve_path() {
    local key="$1" p="$2"
    [ -n "$p" ] || return 1
    case "$p" in
        /*) printf '%s' "$p"; return 0 ;;
    esac
    local root; root=$(_atlas_root "$key")
    if [ -e "${root}/${p}" ]; then printf '%s/%s' "$root" "$p"; return 0; fi
    if [ -e "${ATLAS_DIR}/${p}" ]; then printf '%s/%s' "$ATLAS_DIR" "$p"; return 0; fi
    # Glob patterns (e.g. "LC*prob*.nii*") resolve to the first match, so a
    # release whose exact file name varies still works without editing config.
    case "$p" in
        *[\*\?\[]*)
            local m
            m=$(compgen -G "${root}/${p}" 2>/dev/null | sort | head -1)
            [ -n "$m" ] || m=$(compgen -G "${ATLAS_DIR}/${p}" 2>/dev/null | sort | head -1)
            if [ -n "$m" ]; then printf '%s' "$m"; return 0; fi ;;
    esac
    printf '%s/%s' "$root" "$p"
    return 0
}

# _atlas_cache_dir <key> -> writable derived/ cache for this atlas. Prefers
# <MULTI_ATLAS_CACHE_DIR>/<REL>/derived (mirrors Bianciardi/AAL3); an FSL system
# install may be read-only, so fall back to a per-run cache under RESULTS_DIR.
_atlas_cache_dir() {
    local key="$1"
    local rel; rel=$(_atlas_cfg "$key" REL "$key")
    local d="${MULTI_ATLAS_CACHE_DIR}/${rel}/derived"
    if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then
        printf '%s' "$d"; return 0
    fi
    d="${RESULTS_DIR:-.}/segmentation/multi_atlas/cache/${key}"
    mkdir -p "$d" 2>/dev/null || true
    printf '%s' "$d"
}

# atlas_registry_present <key> -> 0 when the atlas image/dir is on disk.
atlas_registry_present() {
    local key="$1"
    local image; image=$(_atlas_cfg "$key" IMAGE "")
    [ -n "$image" ] || return 1
    local p; p=$(_atlas_resolve_path "$key" "$image")
    [ -e "$p" ]
}

# _atlas_python -> python launcher with numpy+nibabel (reuses multi_atlas helper)
_atlas_python() {
    if declare -f _multi_atlas_python >/dev/null 2>&1; then
        _multi_atlas_python; return $?
    fi
    if command -v uv >/dev/null 2>&1 && uv run python -c "import numpy, nibabel" >/dev/null 2>&1; then
        echo "uv run python"; return 0
    fi
    if [ -n "${FSLDIR:-}" ] && [ -x "${FSLDIR}/bin/fslpython" ] && \
       "${FSLDIR}/bin/fslpython" -c "import numpy, nibabel" >/dev/null 2>&1; then
        echo "${FSLDIR}/bin/fslpython"; return 0
    fi
    return 1
}

_atlas_mni_ref() {
    printf '%s/data/standard/MNI152_T1_1mm.nii.gz' "${FSLDIR:-}"
}

# ──────────────────────────────────────────────────────────────────────────────
# LUT handling
# ──────────────────────────────────────────────────────────────────────────────

# parse_fsl_xml_lut <atlas.xml> -> "idx<TAB>Name_with_underscores" per label.
# FSL atlas XML: <label index="N" x=.. y=.. z=..>Human Name</label>. Names are
# joined with '_' so the downstream whitespace LUT parser keeps them intact.
parse_fsl_xml_lut() {
    local xml="$1"
    [ -f "$xml" ] || { log_error "parse_fsl_xml_lut: not found: $xml" "${ERR_FILE_NOT_FOUND:-3}"; return 1; }
    sed -n 's/.*<label[^>]*index="\([0-9][0-9]*\)"[^>]*>\([^<]*\)<\/label>.*/\1\t\2/p' "$xml" | \
    awk -F'\t' '{
        name=$2; gsub(/^[ \t]+|[ \t]+$/, "", name); gsub(/[ \t\/]+/, "_", name);
        gsub(/[()]/, "", name); gsub(/[^A-Za-z0-9_.-]/, "", name);
        if (name != "") printf "%d\t%s\n", $1, name }'
}

# _fsl_xml_type <atlas.xml> -> Label | Probabilistic | "" (from <type>)
_fsl_xml_type() {
    sed -n 's/.*<type>\([A-Za-z]*\)<\/type>.*/\1/p' "$1" 2>/dev/null | head -1
}

# _atlas_lut_offset <key> <lut_path> -> 0|1 : image value = LUT index + offset.
#   explicit ATLAS_<KEY>_LUT_OFFSET wins; FSL XML: type Label -> 0 (JHU labels:
#   index == voxel value, index 0 = Unclassified), Probabilistic -> 1 (the
#   maxprob summary image is index+1, like Harvard-Oxford); txt LUTs reuse the
#   multi_atlas.sh heuristic (smallest index 0 -> 1, else 0).
_atlas_lut_offset() {
    local key="$1" lut="$2"
    local explicit; explicit=$(_atlas_cfg "$key" LUT_OFFSET "auto")
    case "$explicit" in 0|1) printf '%s' "$explicit"; return 0 ;; esac
    case "$lut" in
        *.xml|*.XML)
            local t; t=$(_fsl_xml_type "$lut")
            if [ "$t" = "Label" ]; then printf '0'; else printf '1'; fi
            return 0 ;;
    esac
    if declare -f _lut_image_offset >/dev/null 2>&1; then
        _lut_image_offset "$lut"
    else
        local min_idx
        min_idx=$(awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} $1 ~ /^-?[0-9]+$/ {if (m=="" || $1<m) m=$1} END{print m+0}' "$lut")
        if [ "${min_idx:-1}" -le 0 ] 2>/dev/null; then printf '1'; else printf '0'; fi
    fi
}

# parse_freesurfer_lut <FreeSurferColorLUT-style file> -> "idx<TAB>Name_joined"
#   Format: "<idx> <Name possibly with spaces> R G B A". Name words are joined
#   with '_' up to the trailing RGB(A) integer run, so multi-word ROI names
#   (NextBrain: "Left pontine nuclei") survive the whitespace LUT convention.
parse_freesurfer_lut() {
    local lut="$1"
    [ -f "$lut" ] || return 1
    awk '
        { sub(/\r$/, "") }
        /^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next }
        $1 ~ /^[0-9]+$/ && NF >= 2 {
            name = $2
            for (i = 3; i <= NF; i++) {
                if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^[0-9]+$/ && $(i+2) ~ /^[0-9]+$/) break
                name = name "_" $i
            }
            gsub(/[ \/-]+/, "_", name); gsub(/[^A-Za-z0-9_.]/, "", name)
            if (name != "") printf "%d\t%s\n", $1, name
        }' "$lut"
}

# _atlas_lut_is_freesurfer <lut> -> 0 when rows look like "idx Name ... R G B A"
_atlas_lut_is_freesurfer() {
    awk '/^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next}
         NF >= 6 && $1 ~ /^[0-9]+$/ && $(NF) ~ /^[0-9]+$/ && $(NF-1) ~ /^[0-9]+$/ && $(NF-2) ~ /^[0-9]+$/ { found=1; exit }
         END { exit !found }' "$1" 2>/dev/null
}

# _atlas_lut_rows <key> <lut_path> -> normalised "idx<TAB>name" rows
#   XML (FSL), FreeSurfer colour LUT (ATLAS_<KEY>_LUT_FORMAT=freesurfer or
#   auto-detected), or plain "idx name" text.
_atlas_lut_rows() {
    local key="$1" lut="$2"
    local fmt; fmt=$(_atlas_cfg "$key" LUT_FORMAT "auto")
    case "$lut" in *.xml|*.XML) fmt="xml" ;; esac
    if [ "$fmt" = "auto" ] && _atlas_lut_is_freesurfer "$lut"; then fmt="freesurfer"; fi
    case "$fmt" in
        xml)        parse_fsl_xml_lut "$lut" ;;
        freesurfer) parse_freesurfer_lut "$lut" ;;
        *)
            if declare -f parse_atlas_lut >/dev/null 2>&1; then parse_atlas_lut "$lut"
            else
                awk '{ sub(/\r$/, "") } /^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next}
                     $1 ~ /^-?[0-9]+$/ && $2 != "" { printf "%d\t%s\n", $1, $2 }' "$lut"
            fi ;;
    esac
}

# _atlas_label_selected <key> <idx> <name> -> 0 when no subset configured or the
# label (by index or case-insensitive name) is in ATLAS_<KEY>_LABELS.
_atlas_label_selected() {
    local key="$1" idx="$2" name="$3"
    local subset; subset=$(_atlas_cfg "$key" LABELS "")
    local regex; regex=$(_atlas_cfg "$key" LABEL_REGEX "")
    [ -n "$subset" ] || [ -n "$regex" ] || return 0
    local lname; lname=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    # Case-insensitive regex on the name (e.g. brainstem structures of a
    # whole-brain atlas). Matching either selector keeps the label.
    if [ -n "$regex" ] && printf '%s' "$lname" | grep -Eiq -- "$regex"; then return 0; fi
    [ -n "$subset" ] || return 1
    local s ls
    for s in $subset; do
        ls=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
        [ "$s" = "$idx" ] && return 0
        [ "$ls" = "$lname" ] && return 0
    done
    return 1
}

# atlas_lut_to_tsv <key> <lut_path> <out_tsv>
#   Writes "value<TAB>name" rows where value is the IMAGE voxel value (index +
#   offset), filtered to ATLAS_<KEY>_LABELS when set, dropping value 0
#   (background / "Unclassified"). Because values are already image values, the
#   downstream split (_lut_image_offset) sees min>=1 and applies offset 0.
atlas_lut_to_tsv() {
    local key="$1" lut="$2" out="$3"
    [ -f "$lut" ] || { log_formatted "WARNING" "atlas '$key': LUT missing: $lut"; return 1; }
    local offset; offset=$(_atlas_lut_offset "$key" "$lut")
    local idx name val n=0
    {
        printf '# value\tname\t(source LUT: %s, offset=%s)\n' "$(basename "$lut")" "$offset"
        while IFS=$'\t' read -r idx name; do
            [ -n "$idx" ] || continue
            _atlas_label_selected "$key" "$idx" "$name" || continue
            val=$((idx + offset))
            [ "$val" -gt 0 ] 2>/dev/null || continue
            printf '%d\t%s\n' "$val" "$name"
            n=$((n + 1))
        done < <(_atlas_lut_rows "$key" "$lut")
    } > "$out"
    n=$(grep -c -v '^#' "$out" 2>/dev/null || echo 0)
    [ "$n" -gt 0 ] 2>/dev/null || { log_formatted "WARNING" "atlas '$key': no labels selected from $lut"; return 1; }
    log_message "  atlas '$key': $n labels (offset=$offset) -> $out"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Grid / space normalisation
# ──────────────────────────────────────────────────────────────────────────────

# _atlas_same_grid <img> <ref> -> 0 when dims + pixdims match (fslval)
_atlas_same_grid() {
    local a="$1" b="$2" k va vb
    command -v fslval >/dev/null 2>&1 || return 1
    for k in dim1 dim2 dim3 pixdim1 pixdim2 pixdim3; do
        va=$(fslval "$a" "$k" 2>/dev/null | tr -d ' ')
        vb=$(fslval "$b" "$k" 2>/dev/null | tr -d ' ')
        [ -n "$va" ] && [ "$va" = "$vb" ] || return 1
    done
    return 0
}

# _atlas_to_fsl_grid <key> <in> <out> <is_label>
#   Resample an NLin6-space image whose GRID differs from MNI152_T1_1mm (e.g.
#   0.5 mm or 2 mm releases) onto the FSL 1 mm grid via the header transform
#   (flirt -applyxfm -usesqform; NN for labels, trilinear for probabilities).
#   Same-grid inputs are passed through (out == in). Cached: skips when out is
#   newer than in.
_atlas_to_fsl_grid() {
    local key="$1" in="$2" out="$3" is_label="${4:-true}"
    local ref; ref=$(_atlas_mni_ref)
    [ -f "$ref" ] || { log_formatted "WARNING" "atlas '$key': MNI152_T1_1mm reference missing ($ref)"; return 1; }
    if _atlas_same_grid "$in" "$ref"; then
        printf '%s' "$in"; return 0
    fi
    if [ -f "$out" ] && [ "$out" -nt "$in" ]; then
        printf '%s' "$out"; return 0
    fi
    local interp="trilinear"; [ "$is_label" = "true" ] && interp="nearestneighbour"
    log_message "  atlas '$key': resampling onto the FSL MNI152 1mm grid ($interp)"
    if ! flirt -in "$in" -ref "$ref" -applyxfm -usesqform -interp "$interp" -out "$out" >/dev/null 2>&1 || [ ! -f "$out" ]; then
        log_formatted "WARNING" "atlas '$key': grid resample failed"
        return 1
    fi
    printf '%s' "$out"
}

# _atlas_find_2009c_to_nlin6_xfm -> path of the TemplateFlow NLin6<-2009c transform
_atlas_find_2009c_to_nlin6_xfm() {
    local name="tpl-MNI152NLin6Asym_from-MNI152NLin2009cAsym_mode-image_xfm.h5"
    local c
    for c in "${MNI_2009C_TO_NLIN6_XFM:-}" \
             "${TEMPLATEFLOW_HOME:-}/tpl-MNI152NLin6Asym/${name}" \
             "${HOME:-}/.cache/templateflow/tpl-MNI152NLin6Asym/${name}" \
             "${ATLAS_DIR}/templateflow/tpl-MNI152NLin6Asym/${name}" \
             "${ATLAS_DIR}/templateflow/${name}"; do
        [ -n "$c" ] && [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# _atlas_to_nlin6_space <key> <in> <out> <is_label>
#   Bring a MNI152NLin2009cAsym-space image into FSL MNI152 (NLin6Asym) space
#   on the 1 mm grid via the TemplateFlow image transform. Echoes the output
#   path; returns 1 (caller skips the atlas) when no transform is available.
_atlas_to_nlin6_space() {
    local key="$1" in="$2" out="$3" is_label="${4:-true}"
    local ref; ref=$(_atlas_mni_ref)
    [ -f "$ref" ] || { log_formatted "WARNING" "atlas '$key': MNI152_T1_1mm reference missing"; return 1; }
    if [ -f "$out" ] && [ "$out" -nt "$in" ]; then printf '%s' "$out"; return 0; fi
    local xfm
    if ! xfm=$(_atlas_find_2009c_to_nlin6_xfm); then
        log_formatted "WARNING" "atlas '$key' is in MNI152NLin2009cAsym space but the TemplateFlow transform tpl-MNI152NLin6Asym_from-MNI152NLin2009cAsym_mode-image_xfm.h5 was not found (set MNI_2009C_TO_NLIN6_XFM or TEMPLATEFLOW_HOME). SKIPPING '$key' rather than warping through the wrong template."
        return 1
    fi
    local interp="Linear"; [ "$is_label" = "true" ] && interp="${REG_LABEL_INTERPOLATION:-GenericLabel}"
    log_message "  atlas '$key': MNI152NLin2009cAsym -> NLin6Asym via $xfm ($interp)"
    if ! antsApplyTransforms -d 3 -i "$in" -r "$ref" -o "$out" -t "$xfm" -n "$interp" >/dev/null 2>&1 || [ ! -f "$out" ]; then
        log_formatted "WARNING" "atlas '$key': template-space transform failed"
        return 1
    fi
    printf '%s' "$out"
}

# _atlas_apply_explicit_xfm <key> <in> <out> <is_label>
#   ATLAS_<KEY>_XFM="<t1> [<t2> ...]" — an explicit ANTs transform chain (h5 /
#   .mat / warp, applied in the order given, like antsApplyTransforms -t ...)
#   that maps the atlas into FSL MNI152 (NLin6Asym) space. Used for atlases
#   released in spaces TemplateFlow has no transform for (e.g. the linear
#   MNIavg152 grid of the Dahl 2022 LC meta-mask, whose OSF bundle ships its own
#   ANTs transforms). Echoes the output path.
_atlas_apply_explicit_xfm() {
    local key="$1" in="$2" out="$3" is_label="${4:-true}"
    local xfms; xfms=$(_atlas_cfg "$key" XFM "")
    local ref; ref=$(_atlas_mni_ref)
    [ -f "$ref" ] || { log_formatted "WARNING" "atlas '$key': MNI152_T1_1mm reference missing"; return 1; }
    if [ -f "$out" ] && [ "$out" -nt "$in" ]; then printf '%s' "$out"; return 0; fi
    local -a targs=() ; local t
    for t in $xfms; do
        [ -f "$t" ] || { log_formatted "WARNING" "atlas '$key': transform not found: $t — SKIPPING"; return 1; }
        targs+=(-t "$t")
    done
    local interp="Linear"; [ "$is_label" = "true" ] && interp="${REG_LABEL_INTERPOLATION:-GenericLabel}"
    log_message "  atlas '$key': applying explicit transform chain (${#targs[@]} args) -> FSL MNI152 ($interp)"
    if ! antsApplyTransforms -d 3 -i "$in" -r "$ref" -o "$out" "${targs[@]}" -n "$interp" >/dev/null 2>&1 || [ ! -f "$out" ]; then
        log_formatted "WARNING" "atlas '$key': explicit transform failed"
        return 1
    fi
    printf '%s' "$out"
}

# _atlas_normalise_space <key> <in> <cache_dir> <is_label> -> echoes an image on
# the FSL MNI152 1mm grid in NLin6Asym space (or returns 1 => skip atlas).
_atlas_normalise_space() {
    local key="$1" in="$2" cache="$3" is_label="${4:-true}"
    local space; space=$(_atlas_cfg "$key" SPACE "MNI152NLin6Asym")
    local base; base=$(basename "$in"); base="${base%.nii.gz}"; base="${base%.nii}"
    # An explicit transform chain always wins (any source space).
    if [ -n "$(_atlas_cfg "$key" XFM "")" ]; then
        _atlas_apply_explicit_xfm "$key" "$in" "${cache}/${base}_nlin6.nii.gz" "$is_label"
        return $?
    fi
    case "$space" in
        MNI152NLin6Asym|MNI152NLin6|NLin6|NLin6Asym|fsl|FSL|MNI152)
            _atlas_to_fsl_grid "$key" "$in" "${cache}/${base}_fslmni.nii.gz" "$is_label" ;;
        MNI152NLin2009cAsym|MNI152NLin2009cSym|MNI152NLin2009bAsym|MNI152NLin2009bSym|MNI152NLin2009aAsym|2009c|2009b|2009a)
            # 2009a/b/c share one nonlinear average (world space); they differ
            # only in grid/FOV, so the 2009c->NLin6 image transform applies to all.
            _atlas_to_nlin6_space "$key" "$in" "${cache}/${base}_nlin6.nii.gz" "$is_label" ;;
        *)
            log_formatted "WARNING" "atlas '$key': unknown ATLAS_*_SPACE='$space' — SKIPPING (expected MNI152NLin6Asym or MNI152NLin2009[abc]Asym; other spaces need ATLAS_*_XFM)"
            return 1 ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Probabilistic -> dseg builders (numpy/nibabel, streaming)
# ──────────────────────────────────────────────────────────────────────────────

# build_prob4d_dseg <in4d> <lut_tsv(idx name)> <out_dseg> <out_lut> <thr> [subset_idx...]
#   4D probability atlas (one volume per label, XML index == volume index) ->
#   thresholded winner-take-all dseg (value = volume index + 1) + LUT.
build_prob4d_dseg() {
    local in4d="$1" lut_rows="$2" out_dseg="$3" out_lut="$4" thr="${5:-0.25}"
    shift 5 || true
    local subset="$*"
    local py; py=$(_atlas_python) || { log_formatted "WARNING" "No python with numpy+nibabel — cannot build prob4d dseg"; return 1; }
    # shellcheck disable=SC2086
    $py - "$in4d" "$lut_rows" "$out_dseg" "$out_lut" "$thr" "$subset" <<'PYEOF'
import sys
import numpy as np
import nibabel as nib
in4d, lut_rows, out_dseg, out_lut, thr, subset = sys.argv[1:7]
thr = float(thr)
keep = set(int(s) for s in subset.split()) if subset.strip() else None
names = {}
for line in open(lut_rows):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    parts = line.split('\t')
    try:
        names[int(parts[0])] = parts[1]
    except (ValueError, IndexError):
        pass
img = nib.load(in4d)
shape = img.shape
nvol = shape[3] if len(shape) > 3 else 1
best_p = np.zeros(shape[:3], dtype=np.float32)
best_l = np.zeros(shape[:3], dtype=np.int16)
owned = {}
for i in range(nvol):
    if keep is not None and i not in keep:
        continue
    vol = np.asanyarray(img.dataobj[..., i]).astype(np.float32) if nvol > 1 else np.asanyarray(img.dataobj).astype(np.float32)
    if vol.max() > 1.0:          # percent-scaled atlases
        vol = vol / 100.0
    vol[vol < thr] = 0.0
    win = vol > best_p
    best_p[win] = vol[win]
    best_l[win] = i + 1
    del vol, win
u, c = np.unique(best_l, return_counts=True)
for lab, cnt in zip(u.tolist(), c.tolist()):
    if lab > 0:
        owned[lab] = cnt
out = nib.Nifti1Image(best_l, img.affine, img.header)
out.set_data_dtype(np.int16)
nib.save(out, out_dseg)
with open(out_lut, 'w') as fh:
    fh.write('# value\tname\towned_voxels\t(thr=%g)\n' % thr)
    for i in range(nvol):
        if keep is not None and i not in keep:
            continue
        nm = names.get(i, 'vol%d' % i)
        fh.write('%d\t%s\t%d\n' % (i + 1, nm, owned.get(i + 1, 0)))
sys.stderr.write('prob4d dseg: %d volumes considered, %d own >=1 voxel\n' % (nvol if keep is None else len(keep), len(owned)))
PYEOF
    [ -f "$out_dseg" ] && [ -f "$out_lut" ]
}

# build_probdir_dseg <dir> <out_dseg> <out_lut> <thr>
#   Directory of per-structure probability maps (one NIfTI per nucleus; file
#   stem = name) -> thresholded winner-take-all dseg + LUT ("value name owned").
#   Nuclei that lose every voxel to overlap keep an overlay copy in
#   <cache>/overlay/ (same hybrid rule as the Bianciardi build).
build_probdir_dseg() {
    local dir="$1" out_dseg="$2" out_lut="$3" thr="${4:-0.25}"
    local overlay_dir="$(dirname "$out_dseg")/overlay"
    local ref; ref=$(_atlas_mni_ref)
    local py; py=$(_atlas_python) || { log_formatted "WARNING" "No python with numpy+nibabel — cannot build probdir dseg"; return 1; }
    mkdir -p "$overlay_dir"
    # shellcheck disable=SC2086
    $py - "$dir" "$out_dseg" "$out_lut" "$thr" "$overlay_dir" "$ref" <<'PYEOF'
import os, sys, glob, shutil
import numpy as np
import nibabel as nib
d, out_dseg, out_lut, thr, overlay_dir, ref = sys.argv[1:7]
thr = float(thr)
files = sorted(glob.glob(os.path.join(d, '*.nii.gz')) + glob.glob(os.path.join(d, '*.nii')))
files = [f for f in files if not os.path.basename(f).startswith('.')]
if not files:
    sys.stderr.write('ERROR: no probability maps in %s\n' % d)
    sys.exit(2)
first = nib.load(files[0])
shape = first.shape[:3]
affine = first.affine
best_p = np.zeros(shape, dtype=np.float32)
best_l = np.zeros(shape, dtype=np.int16)
names = []
for i, f in enumerate(files, start=1):
    stem = os.path.basename(f)
    for ext in ('.nii.gz', '.nii'):
        if stem.endswith(ext):
            stem = stem[:-len(ext)]
    names.append(stem)
    img = nib.load(f)
    if img.shape[:3] != shape:
        sys.stderr.write('ERROR: %s shape %s != %s\n' % (f, img.shape[:3], shape))
        sys.exit(3)
    data = np.asanyarray(img.dataobj).astype(np.float32)
    if data.ndim > 3:
        data = data[..., 0]
    if data.max() > 1.0:
        data = data / 100.0
    data[data < thr] = 0.0
    win = data > best_p
    best_p[win] = data[win]
    best_l[win] = i
    del data, win
owned = [0] * (len(files) + 1)
u, c = np.unique(best_l, return_counts=True)
for lab, cnt in zip(u.tolist(), c.tolist()):
    if lab > 0:
        owned[lab] = cnt
out = nib.Nifti1Image(best_l, affine, first.header)
out.set_data_dtype(np.int16)
nib.save(out, out_dseg)
with open(out_lut, 'w') as fh:
    fh.write('# value\tname\towned_voxels\t(thr=%g)\n' % thr)
    for i, nm in enumerate(names, start=1):
        fh.write('%d\t%s\t%d\n' % (i, nm, owned[i]))
        if owned[i] == 0:
            try:
                shutil.copyfile(files[i - 1], os.path.join(overlay_dir, nm + '.nii.gz'))
            except Exception as e:
                sys.stderr.write('WARN: overlay copy failed for %s: %s\n' % (nm, e))
sys.stderr.write('probdir dseg: %d maps, %d own >=1 voxel\n' % (len(files), sum(1 for i in range(1, len(files)+1) if owned[i] > 0)))
PYEOF
    [ -f "$out_dseg" ] && [ -f "$out_lut" ]
}

# build_probmap_dseg <probmap> <out_dseg> <out_lut> <thr> <name>
#   Single probability map (e.g. a locus-coeruleus atlas) -> binary label 1.
build_probmap_dseg() {
    local pmap="$1" out_dseg="$2" out_lut="$3" thr="${4:-0.25}" name="${5:-region}"
    # Percent-scaled maps (max > 1) are handled by scaling the threshold.
    local maxv; maxv=$(fslstats "$pmap" -R 2>/dev/null | awk '{print $2+0}')
    local t="$thr"
    if [ -n "$maxv" ] && awk -v m="$maxv" 'BEGIN{exit !(m > 1.0)}'; then
        t=$(awk -v x="$thr" 'BEGIN{print x*100}')
    fi
    if ! safe_fslmaths "probmap->dseg $name" "$pmap" -thr "$t" -bin "$out_dseg" >/dev/null 2>&1 || [ ! -f "$out_dseg" ]; then
        log_formatted "WARNING" "probmap dseg build failed for $pmap"
        return 1
    fi
    printf '# value\tname\t(thr=%s)\n1\t%s\n' "$thr" "$name" > "$out_lut"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Brainstem extent (MNI) for restricting whole-brain tract atlases
# ──────────────────────────────────────────────────────────────────────────────

# _atlas_brainstem_extent_mni -> echoes a cached, 1-voxel-dilated Harvard-Oxford
# Brain-Stem mask (label index 7 -> value 8) on the FSL 1mm grid; returns 1 when
# the HO atlas is unavailable.
_atlas_brainstem_extent_mni() {
    local ho_rel="${ATLAS_HARVARDOXFORD_REL:-HarvardOxford}"
    local ho="${ATLAS_DIR}/${ho_rel}/HarvardOxford-sub-maxprob-${HO_SUB_MAXPROB_THR}-1mm.nii.gz"
    [ -f "$ho" ] || return 1
    # Cache next to the HO atlas (same layout as the other derived/ caches),
    # falling back to a per-run cache when the FSL tree is read-only.
    local cache="${MULTI_ATLAS_CACHE_DIR}/${ho_rel}/derived"
    if ! mkdir -p "$cache" 2>/dev/null || [ ! -w "$cache" ]; then
        cache="${RESULTS_DIR:-.}/segmentation/multi_atlas/cache/harvardoxford"
        mkdir -p "$cache" 2>/dev/null || return 1
    fi
    local out="${cache}/brainstem_extent_${HO_SUB_MAXPROB_THR}_1mm_dil1.nii.gz"
    if [ -f "$out" ] && [ "$out" -nt "$ho" ]; then printf '%s' "$out"; return 0; fi
    local val="${HO_BRAINSTEM_LABEL_VALUE:-8}"
    if ! safe_fslmaths "HO brainstem extent" "$ho" -thr "$val" -uthr "$val" -bin -dilM "$out" >/dev/null 2>&1 || [ ! -f "$out" ]; then
        return 1
    fi
    printf '%s' "$out"
}

# ──────────────────────────────────────────────────────────────────────────────
# Prepare (cache) an MNI dseg + LUT for a registry key
# ──────────────────────────────────────────────────────────────────────────────

# prepare_registry_atlas <key> -> echoes "<mni_dseg><TAB><lut_tsv>" ready to warp.
# Returns 1 (caller skips) on any missing input. Idempotent / cached.
prepare_registry_atlas() {
    local key="$1"
    local type; type=$(_atlas_cfg "$key" TYPE "dseg")
    local image; image=$(_atlas_cfg "$key" IMAGE "")
    local lut; lut=$(_atlas_cfg "$key" LUT "")
    local thr; thr=$(_atlas_cfg "$key" PROB_THR "0.25")
    local restrict; restrict=$(_atlas_cfg "$key" RESTRICT "none")

    if [ -z "$image" ]; then
        log_formatted "WARNING" "atlas '$key': ATLAS_$(_atlas_key_upper "$key")_IMAGE not configured — skipping"
        return 1
    fi
    local src; src=$(_atlas_resolve_path "$key" "$image")
    if [ ! -e "$src" ]; then
        local url; url=$(_atlas_cfg "$key" URL "")
        log_formatted "WARNING" "atlas '$key' not on disk ($src) — skipping${url:+ (download: $url)}"
        return 1
    fi
    local cache; cache=$(_atlas_cache_dir "$key")
    local lut_path=""
    [ -n "$lut" ] && lut_path=$(_atlas_resolve_path "$key" "$lut")

    local mni_dseg="${cache}/${key}_MNI_dseg.nii.gz"
    local lut_tsv="${cache}/${key}_MNI_labels.txt"

    # Cache check: dseg + LUT newer than the source image (and LUT).
    if [ -f "$mni_dseg" ] && [ -f "$lut_tsv" ] && [ "$mni_dseg" -nt "$src" ] && \
       { [ -z "$lut_path" ] || [ ! -f "$lut_path" ] || [ "$lut_tsv" -nt "$lut_path" ]; }; then
        log_message "  atlas '$key': cache up to date ($mni_dseg)"
    else
        log_message "  atlas '$key': building MNI dseg (type=$type, thr=$thr)"
        local built="${cache}/${key}_built_dseg.nii.gz"
        local built_lut="${cache}/${key}_built_labels.txt"
        case "$type" in
            dseg)
                [ -f "$lut_path" ] || { log_formatted "WARNING" "atlas '$key': dseg needs a LUT (ATLAS_*_LUT) — skipping"; return 1; }
                atlas_lut_to_tsv "$key" "$lut_path" "$built_lut" || return 1
                cp -f "$src" "$built" 2>/dev/null || return 1
                ;;
            prob4d)
                [ -f "$lut_path" ] || { log_formatted "WARNING" "atlas '$key': prob4d needs a LUT (ATLAS_*_LUT) — skipping"; return 1; }
                local rows="${cache}/${key}_lut_rows.txt"
                _atlas_lut_rows "$key" "$lut_path" > "$rows"
                # Subset: XML/LUT indices (volume indices) or names -> indices.
                local subset="" idx name
                if [ -n "$(_atlas_cfg "$key" LABELS "")" ]; then
                    while IFS=$'\t' read -r idx name; do
                        [ -n "$idx" ] || continue
                        _atlas_label_selected "$key" "$idx" "$name" && subset="$subset $idx"
                    done < "$rows"
                    [ -n "$subset" ] || { log_formatted "WARNING" "atlas '$key': ATLAS_*_LABELS matched nothing in $lut_path"; return 1; }
                fi
                # shellcheck disable=SC2086
                build_prob4d_dseg "$src" "$rows" "$built" "$built_lut" "$thr" $subset || return 1
                ;;
            probdir)
                [ -d "$src" ] || { log_formatted "WARNING" "atlas '$key': probdir must be a directory: $src"; return 1; }
                build_probdir_dseg "$src" "$built" "$built_lut" "$thr" || return 1
                if [ -n "$(_atlas_cfg "$key" LABELS "")" ]; then
                    # Keep only the selected names (values already image values).
                    local filtered="${cache}/${key}_built_labels_subset.txt"
                    { grep '^#' "$built_lut"; 
                      while IFS=$'\t' read -r idx name _rest; do
                          [ -n "$idx" ] || continue
                          case "$idx" in \#*) continue ;; esac
                          _atlas_label_selected "$key" "$idx" "$name" && printf '%s\t%s\n' "$idx" "$name"
                      done < "$built_lut"; } > "$filtered"
                    mv -f "$filtered" "$built_lut"
                fi
                ;;
            probmap)
                build_probmap_dseg "$src" "$built" "$built_lut" "$thr" "$key" || return 1
                ;;
            *)
                log_formatted "WARNING" "atlas '$key': unknown ATLAS_*_TYPE='$type' — skipping"
                return 1 ;;
        esac

        # Space + grid normalisation onto FSL MNI152 1mm / NLin6Asym.
        local is_label="true"
        local normed
        normed=$(_atlas_normalise_space "$key" "$built" "$cache" "$is_label") || return 1

        # Optional restriction to the (dilated) HO brainstem extent, in MNI space
        # (whole-brain tract atlases would otherwise flood per-region detection
        # with supratentorial voxels).
        if [ "$restrict" = "brainstem" ]; then
            local ext
            if ext=$(_atlas_brainstem_extent_mni); then
                safe_fslmaths "restrict $key to brainstem" "$normed" -mas "$ext" "$mni_dseg" >/dev/null 2>&1 || return 1
                log_message "  atlas '$key': restricted to the Harvard-Oxford brainstem extent (+1 voxel)"
            else
                log_formatted "WARNING" "atlas '$key' requests brainstem restriction but the Harvard-Oxford atlas is absent — SKIPPING (a whole-brain tract atlas must not enter brainstem per-region detection unrestricted)"
                return 1
            fi
        else
            if [ "$normed" != "$mni_dseg" ]; then cp -f "$normed" "$mni_dseg" 2>/dev/null || return 1; fi
        fi
        cp -f "$built_lut" "$lut_tsv" 2>/dev/null || return 1
        touch "$mni_dseg" "$lut_tsv" 2>/dev/null || true
    fi
    printf '%s\t%s' "$mni_dseg" "$lut_tsv"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Subject-space: warp + split + aggregate + view
# ──────────────────────────────────────────────────────────────────────────────

# _atlas_aggregate_subdivisions <key> <subject_dseg> <lut_tsv> <out_dir>
#   ATLAS_<KEY>_SUBDIV="<name_prefix>=<pons|midbrain|medulla|scp> ..." — OR the
#   nucleus masks into <key>_<sub>.nii.gz (+ <key>_left|right_<sub> when the
#   sanitised nucleus name ends in _l/_r or _left/_right).
_atlas_aggregate_subdivisions() {
    local key="$1" dseg="$2" lut="$3" out_dir="$4"
    local map; map=$(_atlas_cfg "$key" SUBDIV "")
    [ -n "$map" ] || return 0
    log_message "  atlas '$key': aggregating nuclei into gross subdivisions ($map)"
    local val name safe pair pref sub lat stem tmp made=0
    while IFS=$'\t' read -r val name _rest; do
        [ -n "$val" ] || continue
        case "$val" in \#*) continue ;; esac
        safe=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr ' /' '__' | tr -cd 'a-z0-9_')
        sub=""; lat=""; stem="$safe"
        case "$safe" in
            *_l|*_left)  lat="left";  stem="${safe%_l}"; stem="${stem%_left}" ;;
            *_r|*_right) lat="right"; stem="${safe%_r}"; stem="${stem%_right}" ;;
            left_*|lh_*)  lat="left";  stem="${safe#left_}"; stem="${stem#lh_}" ;;
            right_*|rh_*) lat="right"; stem="${safe#right_}"; stem="${stem#rh_}" ;;
        esac
        for pair in $map; do
            pref=$(printf '%s' "${pair%%=*}" | tr '[:upper:]' '[:lower:]')
            case "$stem" in "$pref"*) sub="${pair#*=}"; break ;; esac
        done
        [ -n "$sub" ] || continue
        tmp="${out_dir}/.tmp_${key}_${val}.nii.gz"
        safe_fslmaths "tmp $key label $val" "$dseg" -thr "$val" -uthr "$val" -bin "$tmp" >/dev/null 2>&1 || continue
        _atlas_accumulate "${out_dir}/${key}_${sub}.nii.gz" "$tmp"
        [ -n "$lat" ] && _atlas_accumulate "${out_dir}/${key}_${lat}_${sub}.nii.gz" "$tmp"
        rm -f "$tmp"
        made=$((made + 1))
    done < "$lut"
    log_message "  atlas '$key': $made nuclei contributed to subdivision aggregates"
    return 0
}

_atlas_accumulate() {
    local dst="$1" src="$2"
    if [ -f "$dst" ]; then
        safe_fslmaths "accumulate $(basename "$dst")" "$dst" -max "$src" -bin "$dst" >/dev/null 2>&1
    else
        safe_fslmaths "init $(basename "$dst")" "$src" -bin "$dst" >/dev/null 2>&1
    fi
}

# _atlas_dilate_masks <key> <out_dir> <n>  — dilate every <key>_*_label*.nii.gz
# n voxels (tiny nuclei such as the locus coeruleus fall under the analysis
# minimum-voxel guard otherwise). The un-dilated masks are kept as *_core.
_atlas_dilate_masks() {
    local key="$1" out_dir="$2" n="${3:-0}"
    [ "$n" -gt 0 ] 2>/dev/null || return 0
    local f core i
    for f in "$out_dir"/"${key}"_*_label*.nii.gz; do
        [ -f "$f" ] || continue
        case "$f" in *_core.nii.gz) continue ;; esac
        core="${f%.nii.gz}_core.nii.gz"
        cp -f "$f" "$core" 2>/dev/null || continue
        i=0
        while [ "$i" -lt "$n" ]; do
            safe_fslmaths "dilate $(basename "$f")" "$f" -dilM -bin "$f" >/dev/null 2>&1 || break
            i=$((i + 1))
        done
    done
    log_message "  atlas '$key': nucleus masks dilated ${n} voxel(s) (cores kept as *_core.nii.gz)"
    return 0
}

# run_registry_atlas <key> <subject_t1> <reg_prefix> <work_dir> <region_out> <views_dir>
#   Full per-atlas flow. Returns 0 when at least one region mask was produced.
run_registry_atlas() {
    local key="$1" subject_t1="$2" reg_prefix="$3" work_dir="$4" region_out="$5" views_dir="$6"
    local lic; lic=$(_atlas_cfg "$key" LICENSE "")
    log_formatted "INFO" "── extra atlas '$key' ($(_atlas_cfg "$key" TYPE dseg), space=$(_atlas_cfg "$key" SPACE MNI152NLin6Asym))"
    [ -n "$lic" ] && log_message "  license: $lic"

    local prepared
    prepared=$(prepare_registry_atlas "$key") || return 1
    local mni_dseg="${prepared%%	*}" lut_tsv="${prepared#*	}"
    [ -f "$mni_dseg" ] && [ -f "$lut_tsv" ] || return 1

    local subj="${work_dir}/${key}_in_subject.nii.gz"
    if ! warp_atlas_dseg_to_subject "$mni_dseg" "$subj" "$subject_t1" "$reg_prefix" "true"; then
        log_formatted "WARNING" "atlas '$key': warp to subject failed — skipping"
        return 1
    fi
    split_dseg_to_region_masks "$subj" "$lut_tsv" "$region_out" "$key" || return 1
    _atlas_dilate_masks "$key" "$region_out" "$(_atlas_cfg "$key" DILATE 0)"
    _atlas_aggregate_subdivisions "$key" "$subj" "$lut_tsv" "$region_out"
    _emit_atlas_view "$subject_t1" "$subj" "$views_dir" "$key"
    # Provenance sidecar (what was used, from where, which space/threshold).
    {
        printf 'key\t%s\n' "$key"
        printf 'type\t%s\n' "$(_atlas_cfg "$key" TYPE dseg)"
        printf 'space\t%s\n' "$(_atlas_cfg "$key" SPACE MNI152NLin6Asym)"
        printf 'source\t%s\n' "$(_atlas_resolve_path "$key" "$(_atlas_cfg "$key" IMAGE "")")"
        printf 'mni_dseg\t%s\n' "$mni_dseg"
        printf 'lut\t%s\n' "$lut_tsv"
        printf 'prob_thr\t%s\n' "$(_atlas_cfg "$key" PROB_THR 0.25)"
        printf 'restrict\t%s\n' "$(_atlas_cfg "$key" RESTRICT none)"
        printf 'citation\t%s\n' "$(_atlas_cfg "$key" CITATION "")"
        printf 'license\t%s\n' "$lic"
    } > "${work_dir}/${key}_provenance.tsv" 2>/dev/null || true
    return 0
}

# run_registry_atlases <subject_t1> <reg_prefix> <work_dir> <region_out> <views_dir>
#   Iterate the enabled registry keys. Returns 0 when any atlas produced masks.
run_registry_atlases() {
    local subject_t1="$1" reg_prefix="$2" work_dir="$3" region_out="$4" views_dir="$5"
    local any=1 k
    local keys; keys=$(atlas_registry_keys)
    [ -n "$keys" ] || { log_message "No extra registry atlases configured (MULTI_ATLAS_EXTRA empty)"; return 1; }
    for k in $keys; do
        if ! _atlas_enabled "$k"; then
            log_message "  extra atlas '$k' disabled (USE_$(_atlas_key_upper "$k")=false)"
            continue
        fi
        if run_registry_atlas "$k" "$subject_t1" "$reg_prefix" "$work_dir" "$region_out" "$views_dir"; then
            any=0
        fi
    done
    return $any
}

# ── Exports ──────────────────────────────────────────────────────────────────
export -f _atlas_cfg _atlas_enabled atlas_registry_keys atlas_registry_source_tags
export -f atlas_registry_present parse_fsl_xml_lut parse_freesurfer_lut atlas_lut_to_tsv
export -f prepare_registry_atlas run_registry_atlas run_registry_atlases

log_message "Atlas registry module loaded (extra MNI atlases: ${MULTI_ATLAS_EXTRA:-none})"
