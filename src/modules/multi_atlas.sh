#!/usr/bin/env bash
#
# multi_atlas.sh - Multi-atlas brainstem labeling (Bianciardi + CIT168 + AAL3)
#
# Consumes pre-downloaded atlases under $FSLDIR/data/atlases and produces
# subject-space per-region masks for the per-region GMM detection in analysis.sh
# (find_all_atlas_regions discovers them under segmentation/detailed_brainstem).
#
# Atlases handled:
#   - Bianciardi BrainstemNavigator v1.0 (MNI) — 86 thresholded-probabilistic
#     nuclei (brainstem 2a + diencephalic 2b). Built into a hybrid winner-take-all
#     dseg PLUS an overlay set for nuclei that lose all voxels to argmax overlap.
#   - CIT168 (MNI152NLin6Asym) — single 16-label subcortical dseg; sform identical
#     to FSL MNI152 (no resample needed).
#   - AAL3 (1mm) — 170-label whole-brain dseg stored on the SPM/neurological grid;
#     reoriented + resampled onto the FSL MNI152 grid before warping.
#
# IMPORTANT: This is a sourced module — do NOT set `set -e -u -o pipefail` here
# (it would leak into the pipeline shell). Match the idiom of segmentation.sh.
# External-tool / atlas-missing paths degrade gracefully (WARNING + non-fatal
# return), never hard-crash.
#

# ── Include guard ────────────────────────────────────────────────────────────
if [ -n "${_MULTI_ATLAS_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_MULTI_ATLAS_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# ──────────────────────────────────────────────────────────────────────────────
# Configuration defaults (only set if not already provided by default_config.sh)
# ──────────────────────────────────────────────────────────────────────────────
: "${ATLAS_DIR:=${FSLDIR:-}/data/atlases}"
: "${BIANCIARDI_PROB_THRESHOLD:=0.35}"
: "${USE_BIANCIARDI:=true}"
: "${USE_CIT168:=true}"
: "${USE_AAL3:=false}"
: "${REG_LABEL_INTERPOLATION:=GenericLabel}"

# ──────────────────────────────────────────────────────────────────────────────
# _multi_atlas_python
#   Echo a python launcher with numpy + nibabel (prefer uv, fall back to
#   fslpython). Returns non-zero if neither is usable.
# ──────────────────────────────────────────────────────────────────────────────
_multi_atlas_python() {
    if command -v uv >/dev/null 2>&1 && \
       uv run python -c "import numpy, nibabel" >/dev/null 2>&1; then
        echo "uv run python"
        return 0
    fi
    if [ -n "${FSLDIR:-}" ] && [ -x "${FSLDIR}/bin/fslpython" ] && \
       "${FSLDIR}/bin/fslpython" -c "import numpy, nibabel" >/dev/null 2>&1; then
        echo "${FSLDIR}/bin/fslpython"
        return 0
    fi
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# parse_atlas_lut <lut_file>
#   Shared index->name parser tolerant of all three LUT formats:
#     - AAL3   AAL3v1.nii.txt   : "idx name color..."
#     - CIT168 CIT168_labels.txt: "idx name"
#     - Bianciardi (generated)  : "idx name owned_voxels"
#   Skips '#' and blank lines, splits on whitespace/tab, idx=field0 (int),
#   name=field1, ignores trailing fields. Emits normalized "idx<TAB>name".
# ──────────────────────────────────────────────────────────────────────────────
parse_atlas_lut() {
    local lut_file="$1"

    if [ -z "$lut_file" ] || [ ! -f "$lut_file" ]; then
        log_error "parse_atlas_lut: LUT file not found: ${lut_file:-<empty>}" "${ERR_FILE_NOT_FOUND:-3}"
        return 1
    fi

    awk '
        { sub(/\r$/, "") }                  # tolerate CRLF
        /^[[:space:]]*#/ { next }           # comment lines
        /^[[:space:]]*$/ { next }           # blank lines
        {
            idx = $1
            name = $2
            if (idx ~ /^-?[0-9]+$/ && name != "") {
                printf "%d\t%s\n", idx, name
            }
        }
    ' "$lut_file"
}

# ──────────────────────────────────────────────────────────────────────────────
# build_bianciardi_dseg
#   Cached hybrid winner-take-all build over the 86 MNI thresholded-prob maps.
#   Outputs (under <ATLAS_DIR>/Bianciardi/derived/):
#     Bianciardi_MNI_brainstem-dien_dseg.nii.gz  int16 dseg on the 182^3 FSL grid
#     Bianciardi_MNI_labels.txt                  "idx name owned_voxels"  (LUT)
#     Bianciardi_MNI_overlay_nuclei.txt          sidecar list of overlay nuclei
#     overlay/<nucleus>.nii.gz                   copies of overlay prob maps
#
#   CRITICAL: Bianciardi is an OVERLAPPING probabilistic atlas; a single-label
#   dseg cannot hold overlaps. Naive argmax fully overwrites the 12 overlapping
#   reticular-formation nuclei (they end with 0 owned voxels). The hybrid keeps
#   the dseg for nuclei that own >=1 voxel, AND emits the zero-owned nuclei as a
#   per-nucleus overlay set so they are warped/analyzed individually.
#
#   Idempotent: skips the build when the cache is present and newer than inputs.
# ──────────────────────────────────────────────────────────────────────────────
build_bianciardi_dseg() {
    log_message "build_bianciardi_dseg: ensuring Bianciardi winner-take-all dseg"

    local bianc_root="${ATLAS_DIR}/Bianciardi/BrainstemNavigatorv1.0/1.0"
    local thr_tag="${BIANCIARDI_PROB_THRESHOLD}"
    local sub_2a="${bianc_root}/2a.BrainstemNucleiAtlas_MNI/labels_thresholded_probabilistic_${thr_tag}"
    local sub_2b="${bianc_root}/2b.DiencephalicNucleiAtlas_MNI/labels_thresholded_probabilistic_${thr_tag}"

    local derived_dir="${ATLAS_DIR}/Bianciardi/derived"
    local out_dseg="${derived_dir}/Bianciardi_MNI_brainstem-dien_dseg.nii.gz"
    local out_lut="${derived_dir}/Bianciardi_MNI_labels.txt"
    local out_overlay_list="${derived_dir}/Bianciardi_MNI_overlay_nuclei.txt"
    local overlay_dir="${derived_dir}/overlay"

    if [ ! -d "$sub_2a" ] || [ ! -d "$sub_2b" ]; then
        log_formatted "WARNING" "Bianciardi MNI subdirs missing (looked for $sub_2a / $sub_2b) — skipping Bianciardi build"
        return 0
    fi

    mkdir -p "$derived_dir" "$overlay_dir"

    # Cache check: dseg + LUT + sidecar present and no input newer than the dseg.
    if [ -f "$out_dseg" ] && [ -f "$out_lut" ] && [ -f "$out_overlay_list" ]; then
        local newest_input
        newest_input=$(find "$sub_2a" "$sub_2b" -name '*.nii.gz' -newer "$out_dseg" -print -quit 2>/dev/null)
        if [ -z "$newest_input" ]; then
            log_message "  Bianciardi dseg cache is up to date: $out_dseg"
            return 0
        fi
        log_message "  Bianciardi inputs newer than cache — rebuilding"
    fi

    local py
    py=$(_multi_atlas_python) || {
        log_formatted "WARNING" "No python with numpy+nibabel (uv/fslpython) — skipping Bianciardi build"
        return 0
    }

    local mni_ref="${FSLDIR}/data/standard/MNI152_T1_1mm.nii.gz"
    if [ ! -f "$mni_ref" ]; then
        log_formatted "WARNING" "MNI152_T1_1mm reference missing ($mni_ref) — skipping Bianciardi build"
        return 0
    fi

    log_message "  Streaming winner-take-all argmax over Bianciardi nuclei (one volume at a time)"
    # shellcheck disable=SC2086
    $py - "$sub_2a" "$sub_2b" "$mni_ref" "$out_dseg" "$out_lut" "$out_overlay_list" "$overlay_dir" <<'PYEOF'
import os, sys, glob, shutil
import numpy as np
import nibabel as nib

sub_2a, sub_2b, mni_ref, out_dseg, out_lut, out_overlay_list, overlay_dir = sys.argv[1:8]

ref = nib.load(mni_ref)
shape = ref.shape[:3]
affine = ref.affine

files = sorted(glob.glob(os.path.join(sub_2a, "*.nii.gz"))) + \
        sorted(glob.glob(os.path.join(sub_2b, "*.nii.gz")))
if not files:
    sys.stderr.write("ERROR: no Bianciardi nucleus maps found\n")
    sys.exit(2)

# Label index = 1-based position in sorted file order. Stem = filename w/o ext.
names = []
for f in files:
    stem = os.path.basename(f)
    for ext in (".nii.gz", ".nii"):
        if stem.endswith(ext):
            stem = stem[: -len(ext)]
            break
    names.append(stem)

# Streaming argmax: best probability and owning label per voxel.
best_prob = np.zeros(shape, dtype=np.float32)
best_label = np.zeros(shape, dtype=np.int16)

for i, f in enumerate(files, start=1):
    img = nib.load(f)
    if img.shape[:3] != shape:
        sys.stderr.write("ERROR: %s shape %s != ref %s\n" % (f, img.shape[:3], shape))
        sys.exit(3)
    data = np.asanyarray(img.dataobj).astype(np.float32)
    if data.ndim > 3:
        data = data[..., 0]
    win = data > best_prob          # strictly greater => stable first-writer-wins on ties
    best_prob[win] = data[win]
    best_label[win] = i
    del data, win

owned = [0] * (len(files) + 1)
uniq, counts = np.unique(best_label, return_counts=True)
for lab, c in zip(uniq.tolist(), counts.tolist()):
    if lab > 0:
        owned[lab] = c

out = nib.Nifti1Image(best_label, affine, ref.header)
out.set_data_dtype(np.int16)
nib.save(out, out_dseg)

overlay = []
with open(out_lut, "w") as fh:
    fh.write("# index\tname\towned_voxels\n")
    for i, nm in enumerate(names, start=1):
        fh.write("%d\t%s\t%d\n" % (i, nm, owned[i]))
        if owned[i] == 0:
            overlay.append((i, nm, files[i - 1]))

os.makedirs(overlay_dir, exist_ok=True)
with open(out_overlay_list, "w") as fh:
    fh.write("# nucleus\tsource_prob_map\n")
    for _, nm, src in overlay:
        dst = os.path.join(overlay_dir, nm + ".nii.gz")
        try:
            shutil.copyfile(src, dst)
        except Exception as e:
            sys.stderr.write("WARN: could not copy overlay %s: %s\n" % (src, e))
        fh.write("%s\t%s\n" % (nm, dst))

n_labels = sum(1 for i in range(1, len(names) + 1) if owned[i] > 0)
sys.stderr.write("Bianciardi dseg: %d total nuclei, %d own >=1 voxel, %d overlay\n"
                 % (len(names), n_labels, len(overlay)))
PYEOF
    local rc=$?
    if [ "$rc" -ne 0 ] || [ ! -f "$out_dseg" ]; then
        log_formatted "WARNING" "Bianciardi dseg build failed (rc=$rc) — skipping Bianciardi"
        return 0
    fi

    log_formatted "SUCCESS" "Bianciardi dseg built: $out_dseg"
    log_message "  LUT: $out_lut"
    log_message "  Overlay nuclei: $out_overlay_list"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# normalize_aal3_to_fsl_mni
#   Cached: reorient AAL3 (SPM/neurological grid: sform +x, origin -90) to std,
#   then resample onto the FSL MNI152_T1_1mm grid (sform -x, origin +90) with
#   nearest-neighbour (label-preserving). Sanity-checks a known-lateralized label
#   is not L-R flipped. Echoes the cached output path on success.
#   Cache under <ATLAS_DIR>/AAL3/derived/.
# ──────────────────────────────────────────────────────────────────────────────
normalize_aal3_to_fsl_mni() {
    log_message "normalize_aal3_to_fsl_mni: ensuring AAL3 on the FSL MNI152 grid"

    local aal_src="${ATLAS_DIR}/AAL3/AAL3/AAL3v1_1mm.nii.gz"
    local aal_lut="${ATLAS_DIR}/AAL3/AAL3/AAL3v1.nii.txt"
    local derived_dir="${ATLAS_DIR}/AAL3/derived"
    local out_dseg="${derived_dir}/AAL3v1_1mm_fslmni.nii.gz"
    local mni_ref="${FSLDIR}/data/standard/MNI152_T1_1mm.nii.gz"

    if [ ! -f "$aal_src" ]; then
        log_formatted "WARNING" "AAL3 source missing ($aal_src) — skipping AAL3 normalize"
        return 0
    fi
    if [ ! -f "$mni_ref" ]; then
        log_formatted "WARNING" "MNI152_T1_1mm reference missing ($mni_ref) — skipping AAL3 normalize"
        return 0
    fi

    mkdir -p "$derived_dir"

    # Cache is valid only if newer than BOTH the source and the MNI152 grid it
    # was resampled onto (an FSL upgrade could replace the reference).
    if [ -f "$out_dseg" ] && [ "$out_dseg" -nt "$aal_src" ] && [ "$out_dseg" -nt "$mni_ref" ]; then
        log_message "  AAL3 normalized cache up to date: $out_dseg"
        echo "$out_dseg"
        return 0
    fi

    # FSL refuses ambiguous basenames; the atlas dir ships BOTH AAL3v1_1mm.nii
    # and AAL3v1_1mm.nii.gz, so fslreorient2std/flirt error with "No image files
    # match". Copy the compressed source to an unambiguous name first.
    local src_copy="${derived_dir}/AAL3v1_1mm_src.nii.gz"
    cp -f "$aal_src" "$src_copy" 2>/dev/null || {
        log_formatted "WARNING" "Could not stage AAL3 source copy — skipping"
        return 0
    }

    local tmp_reorient="${derived_dir}/AAL3v1_1mm_std.nii.gz"
    log_message "  fslreorient2std + resample onto FSL MNI152 grid (nearest-neighbour)"
    if ! fslreorient2std "$src_copy" "$tmp_reorient" >/dev/null 2>&1; then
        log_formatted "WARNING" "fslreorient2std failed for AAL3 — skipping"
        return 0
    fi

    # Resample onto the FSL MNI152 grid via sqform alignment + NN interpolation.
    if ! flirt -in "$tmp_reorient" -ref "$mni_ref" -applyxfm -usesqform \
               -interp nearestneighbour -out "$out_dseg" >/dev/null 2>&1; then
        log_formatted "WARNING" "flirt resample of AAL3 onto MNI152 grid failed — skipping"
        return 0
    fi

    if [ ! -f "$out_dseg" ]; then
        log_formatted "WARNING" "AAL3 normalized output not produced — skipping"
        return 0
    fi

    # --- L-R flip sanity check on a known-lateralized label ---
    # In FSL MNI152 radiological space (-x sform), left-hemisphere structures sit
    # at SMALLER x (mm). Precentral_L should therefore have COG x < Precentral_R.
    if [ -f "$aal_lut" ]; then
        local left_idx right_idx
        left_idx=$(parse_atlas_lut "$aal_lut" | awk -F'\t' '$2=="Precentral_L"{print $1; exit}')
        right_idx=$(parse_atlas_lut "$aal_lut" | awk -F'\t' '$2=="Precentral_R"{print $1; exit}')
        if [ -n "$left_idx" ] && [ -n "$right_idx" ]; then
            local cog_l cog_r
            cog_l=$(fslstats "$out_dseg" -l "$((left_idx - 1))" -u "$((left_idx + 1))" -c 2>/dev/null | awk '{print $1}')
            cog_r=$(fslstats "$out_dseg" -l "$((right_idx - 1))" -u "$((right_idx + 1))" -c 2>/dev/null | awk '{print $1}')
            if [ -n "$cog_l" ] && [ -n "$cog_r" ]; then
                local flipped
                flipped=$(awk -v l="$cog_l" -v r="$cog_r" 'BEGIN{print (l>r)?"yes":"no"}')
                if [ "$flipped" = "yes" ]; then
                    log_formatted "WARNING" "AAL3 L-R sanity check: Precentral_L COG x ($cog_l) > _R ($cog_r) — possible L-R flip"
                else
                    log_message "  AAL3 L-R sanity check OK (Precentral_L x=$cog_l < _R x=$cog_r)"
                fi
            fi
        fi
    fi

    log_formatted "SUCCESS" "AAL3 normalized onto FSL MNI152 grid: $out_dseg"
    echo "$out_dseg"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# _multi_atlas_register_mni_to_subject <subject_t1> <reg_dir>
#   Ensure a cached MNI->subject SyN registration exists; echo the transform
#   prefix on success. Mirrors the hierarchical_joint_fusion pattern.
# ──────────────────────────────────────────────────────────────────────────────
_multi_atlas_register_mni_to_subject() {
    local subject_t1="$1"
    local reg_dir="$2"
    local prefix="${reg_dir}/mni_to_subject_"
    local affine="${prefix}0GenericAffine.mat"
    local warp="${prefix}1Warp.nii.gz"

    if [ -f "$affine" ] && [ -f "$warp" ]; then
        echo "$prefix"
        return 0
    fi

    # Concurrency-safe shared warp: in 'all' mode the orchestrator computes the
    # MNI->subject SyN warp ONCE up front (before the parallel fan-out) and
    # exports SEG_SHARED_MNI_REG_PREFIX. Seed this reg_dir from that cached
    # transform so the HO and multi-atlas paths reuse the SAME warp rather than
    # racing on / duplicating the expensive registration. Falls through to
    # computing a fresh warp when no shared prefix is available (single-method).
    local shared_prefix="${SEG_SHARED_MNI_REG_PREFIX:-}"
    if [ -n "$shared_prefix" ] && \
       [ -f "${shared_prefix}0GenericAffine.mat" ] && \
       [ -f "${shared_prefix}1Warp.nii.gz" ]; then
        mkdir -p "$reg_dir"
        if cp -f "${shared_prefix}0GenericAffine.mat" "$affine" 2>/dev/null && \
           cp -f "${shared_prefix}1Warp.nii.gz" "$warp" 2>/dev/null; then
            [ -f "${shared_prefix}1InverseWarp.nii.gz" ] && \
                cp -f "${shared_prefix}1InverseWarp.nii.gz" "${prefix}1InverseWarp.nii.gz" 2>/dev/null || true
            log_message "  Reusing pre-computed shared MNI->subject warp: ${shared_prefix}"
            echo "$prefix"
            return 0
        fi
        log_formatted "WARNING" "Could not seed multi-atlas reg_dir from shared warp; computing a fresh one"
    fi

    # Use TEMPLATE_RES when set (sibling modules export it as a side-effect),
    # else the authoritative DEFAULT_TEMPLATE_RES so a 2mm config is honoured even
    # when this module is used standalone.
    local tres="${TEMPLATE_RES:-${DEFAULT_TEMPLATE_RES:-1mm}}"
    local mni_template="${FSLDIR}/data/standard/MNI152_T1_${tres}_brain.nii.gz"
    [ -f "$mni_template" ] || mni_template="${FSLDIR}/data/standard/MNI152_T1_${tres}.nii.gz"
    if [ ! -f "$mni_template" ]; then
        log_formatted "WARNING" "MNI template not found for multi-atlas registration"
        return 1
    fi

    mkdir -p "$reg_dir"
    log_message "  Registering MNI template -> subject (SyN)"
    antsRegistrationSyN.sh -d 3 -f "$subject_t1" -m "$mni_template" \
        -o "$prefix" -t s -j 1 -n "${ANTS_THREADS:-1}" >/dev/null 2>&1

    if [ ! -f "$affine" ] || [ ! -f "$warp" ]; then
        log_formatted "WARNING" "MNI->subject registration failed for multi-atlas warp"
        return 1
    fi
    echo "$prefix"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# warp_atlas_dseg_to_subject <mni_dseg> <out_subject_dseg> <subject_t1> <reg_prefix> [is_label]
#   Warp an MNI-space dseg (or prob map) into subject T1 space using the cached
#   MNI->subject transform and label-aware interpolation. Reuses
#   apply_transformation (registration.sh) is_label path when available.
# ──────────────────────────────────────────────────────────────────────────────
warp_atlas_dseg_to_subject() {
    local mni_dseg="$1"
    local out_subject_dseg="$2"
    local subject_t1="$3"
    local reg_prefix="$4"
    local is_label="${5:-true}"

    if [ ! -f "$mni_dseg" ]; then
        log_formatted "WARNING" "warp_atlas_dseg_to_subject: input missing: $mni_dseg"
        return 1
    fi
    if [ ! -f "$subject_t1" ]; then
        log_formatted "WARNING" "warp_atlas_dseg_to_subject: subject T1 missing: $subject_t1"
        return 1
    fi

    local interp="Linear"
    [ "$is_label" = "true" ] && interp="${REG_LABEL_INTERPOLATION:-GenericLabel}"

    # The registration was built MNI->subject: antsRegistrationSyN.sh -f subject
    # -m mni_template, so MNI is the MOVING image and the FORWARD transform
    # (1Warp + 0GenericAffine, applied plainly) maps an MNI-space image into
    # subject space — exactly what hierarchical_joint_fusion.sh does. Hence
    # direction="forward" (NOT "inverse"; apply_transformation's "inverse" branch
    # would apply 1InverseWarp + [affine,1], the subject->MNI direction, and
    # silently mislabel everything).
    local affine="${reg_prefix}0GenericAffine.mat"
    local warp="${reg_prefix}1Warp.nii.gz"

    # Prefer the pipeline helper (handles SyN chain + label interpolation).
    if declare -f apply_transformation >/dev/null 2>&1; then
        # apply_transformation <input> <reference> <output> <transform> [interp] [direction] [is_label]
        if apply_transformation "$mni_dseg" "$subject_t1" "$out_subject_dseg" \
            "$affine" "$interp" "forward" "$is_label" \
            && [ -f "$out_subject_dseg" ]; then
            return 0
        fi
        log_formatted "WARNING" "apply_transformation failed; falling back to antsApplyTransforms"
    fi

    # Fallback: direct antsApplyTransforms (warp then affine, forward order).
    if [ ! -f "$affine" ] || [ ! -f "$warp" ]; then
        log_formatted "WARNING" "Transform files missing for warp: $reg_prefix"
        return 1
    fi
    antsApplyTransforms -d 3 -i "$mni_dseg" -r "$subject_t1" -o "$out_subject_dseg" \
        -t "$warp" -t "$affine" -n "$interp" >/dev/null 2>&1

    [ -f "$out_subject_dseg" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# _lut_image_offset <lut>
#   Returns the offset to add to a LUT index to get the dseg voxel value.
#   Some LUTs are 0-indexed by name (e.g. CIT168: index 0 = Pu) while the dseg
#   image reserves voxel value 0 for background, so the image value is index+1.
#   Detect this: if the LUT's smallest index is 0, the offset is 1; else 0.
# ──────────────────────────────────────────────────────────────────────────────
_lut_image_offset() {
    local lut="$1"
    local min_idx
    min_idx=$(parse_atlas_lut "$lut" 2>/dev/null | awk -F'\t' 'NR==1{m=$1} $1<m{m=$1} END{print m+0}')
    if [ "${min_idx:-1}" -le 0 ] 2>/dev/null; then
        echo 1
    else
        echo 0
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# split_dseg_to_region_masks <subject_dseg> <lut> <out_dir> [atlas_tag]
#   Split a subject-space dseg into per-region binary masks. Names nucleus-level
#   masks as <atlas_tag>_<name>_label<value>.nii.gz. For Bianciardi (atlas_tag=
#   bianciardi) nuclei are ALSO aggregated into the gross midbrain/pons/medulla
#   (+laterality) masks that find_all_atlas_regions (analysis.sh) discovers.
#   Handles 0-indexed LUTs (CIT168) via _lut_image_offset.
# ──────────────────────────────────────────────────────────────────────────────
split_dseg_to_region_masks() {
    local subject_dseg="$1"
    local lut="$2"
    local out_dir="$3"
    local atlas_tag="${4:-atlas}"

    if [ ! -f "$subject_dseg" ]; then
        log_formatted "WARNING" "split_dseg_to_region_masks: dseg missing: $subject_dseg"
        return 1
    fi
    if [ ! -f "$lut" ]; then
        log_formatted "WARNING" "split_dseg_to_region_masks: LUT missing: $lut"
        return 1
    fi

    mkdir -p "$out_dir"
    local offset
    offset=$(_lut_image_offset "$lut")
    log_message "  Splitting $atlas_tag dseg into per-region masks: $out_dir (lut->image offset=$offset)"

    local n_made=0
    local idx name val safe_name out_mask vox
    while IFS=$'\t' read -r idx name; do
        [ -z "$idx" ] && continue
        val=$((idx + offset))
        [ "$val" -le 0 ] 2>/dev/null && continue   # skip background / non-positive

        safe_name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' /' '__' | tr -cd 'a-z0-9_')
        out_mask="${out_dir}/${atlas_tag}_${safe_name}_label${val}.nii.gz"

        safe_fslmaths "split label $val ($name)" "$subject_dseg" \
            -thr "$val" -uthr "$val" -bin "$out_mask" >/dev/null 2>&1 || continue

        vox=$(fslstats "$out_mask" -V 2>/dev/null | awk '{print $1}')
        if [ -z "$vox" ] || [ "$vox" -le 0 ] 2>/dev/null; then
            rm -f "$out_mask"
            continue
        fi
        n_made=$((n_made + 1))
    done < <(parse_atlas_lut "$lut")

    log_message "  $atlas_tag: created $n_made nucleus-level region masks"

    if [ "$atlas_tag" = "bianciardi" ]; then
        _aggregate_bianciardi_subdivisions "$subject_dseg" "$lut" "$out_dir"
    fi

    [ "$n_made" -gt 0 ]
}

# Map Bianciardi nuclei -> gross brainstem subdivision (+laterality) and write
# the *_left_pons.nii.gz / *_right_midbrain.nii.gz / *_pons.nii.gz style masks
# that find_all_atlas_regions discovers.
_aggregate_bianciardi_subdivisions() {
    local subject_dseg="$1"
    local lut="$2"
    local out_dir="$3"

    log_message "  Aggregating Bianciardi nuclei into gross midbrain/pons/medulla subdivisions"

    local offset
    offset=$(_lut_image_offset "$lut")

    local idx name val stem lat sub tmp_lab

    while IFS=$'\t' read -r idx name; do
        [ -z "$idx" ] && continue
        val=$((idx + offset))
        [ "$val" -le 0 ] 2>/dev/null && continue

        lat=""
        stem="$name"
        case "$name" in
            *_l) lat="left";  stem="${name%_l}" ;;
            *_r) lat="right"; stem="${name%_r}" ;;
        esac

        sub=$(_bianciardi_nucleus_subdivision "$stem")
        [ -z "$sub" ] && continue   # not assigned to a gross subdivision

        tmp_lab="${out_dir}/.tmp_bianc_${val}.nii.gz"
        safe_fslmaths "tmp label $val" "$subject_dseg" -thr "$val" -uthr "$val" -bin "$tmp_lab" >/dev/null 2>&1 || continue

        _bianc_accumulate "${out_dir}/bianciardi_${sub}.nii.gz" "$tmp_lab"
        if [ -n "$lat" ]; then
            _bianc_accumulate "${out_dir}/bianciardi_${lat}_${sub}.nii.gz" "$tmp_lab"
        fi
        rm -f "$tmp_lab"
    done < <(parse_atlas_lut "$lut")

    local f v
    for f in "${out_dir}"/bianciardi_*midbrain.nii.gz "${out_dir}"/bianciardi_*pons.nii.gz "${out_dir}"/bianciardi_*medulla.nii.gz; do
        [ -f "$f" ] || continue
        v=$(fslstats "$f" -V 2>/dev/null | awk '{print $1}')
        log_message "    $(basename "$f"): ${v:-0} voxels"
    done
}

# OR-accumulate src into dst (creating dst if absent).
_bianc_accumulate() {
    local dst="$1" src="$2"
    if [ -f "$dst" ]; then
        safe_fslmaths "accumulate $(basename "$dst")" "$dst" -max "$src" -bin "$dst" >/dev/null 2>&1
    else
        safe_fslmaths "init $(basename "$dst")" "$src" -bin "$dst" >/dev/null 2>&1
    fi
}

# Map a Bianciardi nucleus stem (no laterality) to midbrain|pons|medulla|"".
# Based on Bianciardi BrainstemNavigator anatomical groupings (stems verified
# against the on-disk LUT). Bash `case` matches the FIRST pattern, so the
# medullary reticular nuclei mRta/mRtd are matched explicitly BEFORE the broad
# mesencephalic-reticular glob mRt*. Names are case-sensitive (mRTl != mRt*).
_bianciardi_nucleus_subdivision() {
    local stem="$1"
    case "$stem" in
        # ── Medulla (match mRta/mRtd before the mRt* midbrain glob below) ──
        ION|RMg|RPa|ROb|VSM|PMnR|mRta|mRtd)
            echo "medulla" ;;
        # ── Midbrain (mRTl has an uppercase T; mRt* covers mRt_l/mRt_r) ──
        CLi_RLi|DR|IC|MnR|PAG|SC|SN1|SN2|VTA_PBP|RN|mRt*|mRTl|isRt|MiTg_PBG|PTg)
            echo "midbrain" ;;
        # ── Pons ──
        CnF|LC|LDTg_CGPn|LPB|MPB|SubC|Ve|PnO*|PCRt*|sMRt*|iMRt|iMRtl|iMRtm)
            echo "pons" ;;
        *)
            echo "" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# run_multi_atlas_brainstem <subject_t1> <input_basename> [flair_file]
#   Orchestrator: for each enabled atlas ensure cached MNI dseg -> warp to
#   subject -> split -> emit masks discoverable by analysis.sh.
# ──────────────────────────────────────────────────────────────────────────────
run_multi_atlas_brainstem() {
    local subject_t1="$1"
    local input_basename="${2:-$(basename "$subject_t1" .nii.gz)}"
    local flair_file="${3:-}"

    log_formatted "INFO" "=== MULTI-ATLAS BRAINSTEM LABELING (Bianciardi/CIT168/AAL3) ==="
    log_message "Subject T1: $subject_t1"
    [ -n "$flair_file" ] && log_message "FLAIR: $flair_file"

    if [ ! -f "$subject_t1" ]; then
        log_formatted "ERROR" "Multi-atlas: subject T1 not found: $subject_t1"
        return "${ERR_DATA_MISSING:-31}"
    fi
    if [ -z "${FSLDIR:-}" ] || [ ! -d "$ATLAS_DIR" ]; then
        log_formatted "WARNING" "Atlas directory not available ($ATLAS_DIR) — skipping multi-atlas labeling"
        return 0
    fi

    # Output directory discovered by analysis.sh:find_all_atlas_regions.
    local region_out="${RESULTS_DIR}/segmentation/detailed_brainstem"
    local work_dir="${RESULTS_DIR}/segmentation/multi_atlas"
    local reg_dir="${work_dir}/registration"
    mkdir -p "$region_out" "$work_dir" "$reg_dir"

    # Single shared MNI->subject registration for all atlases.
    local reg_prefix
    reg_prefix=$(_multi_atlas_register_mni_to_subject "$subject_t1" "$reg_dir") || {
        log_formatted "WARNING" "Could not register MNI->subject — skipping multi-atlas labeling"
        return 0
    }

    local any=false

    # ── Bianciardi ──
    if [ "${USE_BIANCIARDI}" = "true" ]; then
        build_bianciardi_dseg
        local b_dseg="${ATLAS_DIR}/Bianciardi/derived/Bianciardi_MNI_brainstem-dien_dseg.nii.gz"
        local b_lut="${ATLAS_DIR}/Bianciardi/derived/Bianciardi_MNI_labels.txt"
        if [ -f "$b_dseg" ] && [ -f "$b_lut" ]; then
            local b_subj="${work_dir}/bianciardi_in_subject.nii.gz"
            if warp_atlas_dseg_to_subject "$b_dseg" "$b_subj" "$subject_t1" "$reg_prefix" "true"; then
                split_dseg_to_region_masks "$b_subj" "$b_lut" "$region_out" "bianciardi" && any=true
                _warp_bianciardi_overlay "$subject_t1" "$reg_prefix" "$work_dir"
            fi
        fi
    fi

    # ── CIT168 (no resample; sform == FSL MNI152) ──
    if [ "${USE_CIT168}" = "true" ]; then
        local c_dseg="${ATLAS_DIR}/CIT168/MNI152/tpl-MNI152NLin6Asym_atlas-CIT168_res-01_dseg.nii.gz"
        local c_lut="${ATLAS_DIR}/CIT168/MNI152/CIT168_labels.txt"
        [ -f "$c_lut" ] || c_lut="${ATLAS_DIR}/CIT168/CIT168_labels.txt"
        if [ -f "$c_dseg" ] && [ -f "$c_lut" ]; then
            local c_subj="${work_dir}/cit168_in_subject.nii.gz"
            if warp_atlas_dseg_to_subject "$c_dseg" "$c_subj" "$subject_t1" "$reg_prefix" "true"; then
                split_dseg_to_region_masks "$c_subj" "$c_lut" "$region_out" "cit168" && any=true
            fi
        else
            log_formatted "WARNING" "CIT168 dseg/LUT missing — skipping CIT168"
        fi
    fi

    # ── AAL3 (off by default; whole-brain, needs grid normalization) ──
    if [ "${USE_AAL3}" = "true" ]; then
        local a_norm
        a_norm=$(normalize_aal3_to_fsl_mni | tail -1)
        local a_lut="${ATLAS_DIR}/AAL3/AAL3/AAL3v1.nii.txt"
        if [ -n "$a_norm" ] && [ -f "$a_norm" ] && [ -f "$a_lut" ]; then
            local a_subj="${work_dir}/aal3_in_subject.nii.gz"
            if warp_atlas_dseg_to_subject "$a_norm" "$a_subj" "$subject_t1" "$reg_prefix" "true"; then
                split_dseg_to_region_masks "$a_subj" "$a_lut" "$region_out" "aal3" && any=true
            fi
        else
            log_formatted "WARNING" "AAL3 normalized dseg/LUT missing — skipping AAL3"
        fi
    fi

    if [ "$any" = "true" ]; then
        log_formatted "SUCCESS" "Multi-atlas brainstem labeling complete: $region_out"
        return 0
    fi

    log_formatted "WARNING" "Multi-atlas labeling produced no region masks (atlases unavailable?)"
    return 0
}

# Warp the Bianciardi overlay (reticular) nuclei prob maps into subject space so
# they are analyzed individually rather than dropped by the argmax dseg.
_warp_bianciardi_overlay() {
    local subject_t1="$1"
    local reg_prefix="$2"
    local work_dir="$3"

    local overlay_list="${ATLAS_DIR}/Bianciardi/derived/Bianciardi_MNI_overlay_nuclei.txt"
    [ -f "$overlay_list" ] || return 0

    local overlay_out="${work_dir}/overlay"
    mkdir -p "$overlay_out"
    local nm src out
    while IFS=$'\t' read -r nm src; do
        case "$nm" in \#*|"") continue ;; esac
        [ -f "$src" ] || continue
        out="${overlay_out}/bianciardi_overlay_${nm}.nii.gz"
        warp_atlas_dseg_to_subject "$src" "$out" "$subject_t1" "$reg_prefix" "true" || true
    done < "$overlay_list"
    log_message "  Warped Bianciardi overlay nuclei into subject space: $overlay_out"
}

# ── Exports ──────────────────────────────────────────────────────────────────
export -f parse_atlas_lut
export -f build_bianciardi_dseg
export -f normalize_aal3_to_fsl_mni
export -f warp_atlas_dseg_to_subject
export -f split_dseg_to_region_masks
export -f run_multi_atlas_brainstem

log_message "Multi-atlas module loaded (Bianciardi/CIT168/AAL3)"
