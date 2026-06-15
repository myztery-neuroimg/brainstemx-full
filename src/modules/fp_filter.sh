#!/usr/bin/env bash
#
# fp_filter.sh - Post-detection false-positive suppression for hyperintensity masks
#
# This module provides reusable, independently config-gated FP-suppression
# functions that take a binary lesion/cluster mask (plus supporting masks) and
# return a *filtered* binary mask.  It is the "cheapest win" complementing the
# merged CSF/partial-volume (CSF/PV) exclusion (#114).
#
#   #114  excludes CSF / partial-volume voxels from each region mask *BEFORE*
#         GMM / z-score detection (analysis.sh build_csf_exclusion_mask()).
#   THIS  module operates *AFTER* detection: it filters the already-detected
#         lesion/cluster mask to remove residual false positives that survive
#         pre-detection exclusion (near-edge / peri-CSF residuals, tiny
#         spurious clusters, CSF-pulsation artifacts around the 4th ventricle
#         and basal cisterns).
#
# All filter functions here are PURE: input mask -> output mask, no global
# state mutation, no reliance on caller-set variables beyond config + args.
#
# RATIONALE / LITERATURE
# ----------------------
# - Posterior-fossa CSF pulsation & inflow around the 4th ventricle / basal
#   cisterns is the dominant FALSE-POSITIVE source for brainstem FLAIR
#   (consistent with the #114 CSF/PV rationale; Valdes Hernandez 2016).
# - Pai et al. 2025 / Bawil et al. 2026: small-vessel-disease / brainstem WMH
#   pipelines benefit from layered, conservative post-hoc FP suppression
#   (geometric brain-edge erosion + CSF-distance gating) rather than aggressive
#   blanket thresholds.
# - Molchanova et al. 2024: BLANKET removal of small lesion instances DELETES
#   TRUE small lesions.  Min-cluster size filtering is therefore CONSERVATIVE
#   by default and LOUDLY logs how much was removed so the loss is auditable.
# - Atlason et al., PLOS ONE 2022;17(8):e0274212 (SegAE; open source
#   lmellingsen/Ventricle_WMH_segmentation): CSF-pulsation artifacts can be
#   estimated from the element-wise product of a CSF soft-segmentation and the
#   lesion soft-segmentation.  fp_filter_segae_pulsation adapts (does NOT copy)
#   that idea to subtract estimated pulsation-artifact voxels from the mask.
#
# DEFAULT OFF: this module is LOSSY by construction.  FP_FILTER_ENABLED defaults
# to false in config/default_config.sh; each sub-stage is independently gated.
#
# NOT WIRED INTO THE PIPELINE.  analysis.sh / pipeline.sh are intentionally not
# edited here.  To use after cluster detection, the one-line hook is:
#   run_fp_filter "$detected_mask" "$filtered_mask" "$brain_mask" "$csf_prob"
#
# Standalone debugging:
#   source src/modules/environment.sh && source src/modules/fp_filter.sh
#

# Include guard - prevent redundant re-sourcing by modules
if [ -n "${_FP_FILTER_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_FP_FILTER_LOADED=1

# Lightweight environment guard (fast no-op when pipeline already loaded).
# NOTE: deliberately NO `set -e` here - this file is sourced, and a hard -e in a
# sourced module would change the caller's shell behaviour.
source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# ------------------------------------------------------------------------------
# Internal helpers (pure; no global state)
# ------------------------------------------------------------------------------

# Wrapper around safe_fslmaths whose stdout+stderr are redirected to LOG_FILE
# (or /dev/null when LOG_FILE is unset).
#
# WHY: safe_fslmaths (environment.sh) spawns a background watchdog
# `( sleep 300; ... ) &`.  On macOS that `sleep` child is reparented and keeps
# the inherited stdout/stderr file descriptors open for up to 5 minutes.  If a
# CALLER captures this module's output via command substitution `$(...)` or a
# pipe, bash blocks until ALL writers to that fd close - so it would hang for
# 300s.  Sending safe_fslmaths' fds to a regular file (LOG_FILE) means the
# watchdog never holds the caller's captured pipe.  The diagnostics still land
# in LOG_FILE, and this module's own log_* lines (foreground, no watchdog) still
# reach stderr for visibility.
_fp_fslmaths() {
    local sink="${LOG_FILE:-/dev/null}"
    safe_fslmaths "$@" >>"$sink" 2>&1
}

# Count non-zero voxels in a binary mask (field 1 of `fslstats -V`).
# Echoes "0" on any failure so callers can do integer arithmetic safely.
_fp_count_voxels() {
    local mask="$1"
    if [ -z "$mask" ] || [ ! -f "$mask" ]; then
        echo "0"
        return 0
    fi
    local v
    v=$(fslstats "$mask" -V 2>/dev/null | awk '{print $1}')
    # Guard against empty / non-numeric output
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        echo "$v"
    else
        echo "0"
    fi
}

# Validate that an input mask path is usable.  Returns ERR_DATA_MISSING when not.
_fp_require_mask() {
    local label="$1"
    local mask="$2"
    if [ -z "$mask" ] || [ ! -f "$mask" ]; then
        log_formatted "ERROR" "$label: input mask not found: ${mask:-<empty>}"
        return "${ERR_DATA_MISSING:-31}"
    fi
    if ! fslinfo "$mask" >/dev/null 2>&1; then
        log_formatted "ERROR" "$label: input mask is not a valid NIfTI: $mask"
        return "${ERR_DATA_CORRUPT:-30}"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 1. Minimum connected-component size filter
# ------------------------------------------------------------------------------
# Drop connected components smaller than FP_MIN_CLUSTER_VOXELS using FSL
# `cluster` (26-connectivity by default, matching analysis.sh detection).
#
# CRITICAL CAVEAT (Molchanova 2024): blanket small-instance removal DELETES TRUE
# SMALL LESIONS.  The default threshold is deliberately CONSERVATIVE (see
# config: FP_MIN_CLUSTER_VOXELS) and the amount removed (voxels AND clusters) is
# logged at WARNING level so the information loss is always visible.
#
# Pure: <in_mask> -> <out_mask>.
fp_filter_min_cluster() {
    local in_mask="$1"
    local out_mask="$2"
    local min_voxels="${3:-${FP_MIN_CLUSTER_VOXELS:-2}}"
    local connectivity="${4:-${FP_CLUSTER_CONNECTIVITY:-26}}"

    log_message "fp_filter_min_cluster: in=$in_mask out=$out_mask min_voxels=$min_voxels connectivity=$connectivity"

    local _rc
    _fp_require_mask "fp_filter_min_cluster" "$in_mask"; _rc=$?
    if [ "$_rc" -ne 0 ]; then return "$_rc"; fi

    mkdir -p "$(dirname "$out_mask")" 2>/dev/null || true

    local voxels_before
    voxels_before=$(_fp_count_voxels "$in_mask")

    # Empty input (no detected lesions) is common for brainstem ROIs and makes
    # FSL `cluster` exit non-zero - handle it explicitly so it is NOT reported as
    # a cluster failure (mirrors the empty-mask handling in fp_filter_csf_distance).
    if [ "$voxels_before" -le 0 ]; then
        log_message "fp_filter_min_cluster: input mask empty; nothing to filter"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        return 0
    fi

    # `cluster --minextent` keeps only components with >= min_voxels voxels.
    # --oindex writes a labelled component image; we re-binarise it.
    local tmp_index
    tmp_index="$(dirname "$out_mask")/.fp_min_cluster_index_$$.nii.gz"

    if ! cluster --in="$in_mask" --thresh=0.5 --connectivity="$connectivity" \
                 --minextent="$min_voxels" --oindex="$tmp_index" > /dev/null 2>&1; then
        log_formatted "WARNING" "fp_filter_min_cluster: FSL cluster failed; passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        rm -f "$tmp_index" 2>/dev/null || true
        return 0
    fi

    # Re-binarise the surviving labelled components into the output mask.
    if ! _fp_fslmaths "Binarise min-cluster-filtered mask" \
            "$tmp_index" -bin "$out_mask"; then
        log_formatted "WARNING" "fp_filter_min_cluster: failed to binarise cluster output; passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        rm -f "$tmp_index" 2>/dev/null || true
        return 0
    fi
    rm -f "$tmp_index" 2>/dev/null || true

    local voxels_after
    voxels_after=$(_fp_count_voxels "$out_mask")
    local removed=$(( voxels_before - voxels_after ))
    if [ "$removed" -lt 0 ]; then removed=0; fi

    if [ "$removed" -gt 0 ]; then
        log_formatted "WARNING" \
            "fp_filter_min_cluster REMOVED $removed voxel(s) (components < ${min_voxels} voxels): ${voxels_before} -> ${voxels_after}. CAVEAT (Molchanova 2024): small TRUE lesions may have been deleted."
    else
        log_message "fp_filter_min_cluster: no voxels removed (all components >= ${min_voxels} voxels)"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 2. Brain-mask erosion filter
# ------------------------------------------------------------------------------
# Erode the brain mask by FP_BRAINMASK_EROSION_MM and drop lesion voxels that
# fall OUTSIDE the eroded brain.  Removes near-edge / peri-CSF residuals that
# hug the brain boundary (Pai 2025 geometric edge suppression).
#
# Pure: <in_mask> + <brain_mask> -> <out_mask>.  Degrades gracefully (pass
# through) if the brain mask is missing.
fp_filter_brainmask_erosion() {
    local in_mask="$1"
    local brain_mask="$2"
    local out_mask="$3"
    local erosion_mm="${4:-${FP_BRAINMASK_EROSION_MM:-1}}"

    log_message "fp_filter_brainmask_erosion: in=$in_mask brain=$brain_mask out=$out_mask erosion_mm=$erosion_mm"

    local _rc
    _fp_require_mask "fp_filter_brainmask_erosion" "$in_mask"; _rc=$?
    if [ "$_rc" -ne 0 ]; then return "$_rc"; fi

    mkdir -p "$(dirname "$out_mask")" 2>/dev/null || true

    if [ -z "$brain_mask" ] || [ ! -f "$brain_mask" ]; then
        log_formatted "WARNING" "fp_filter_brainmask_erosion: brain mask not available ($brain_mask); passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        return 0
    fi

    local voxels_before
    voxels_before=$(_fp_count_voxels "$in_mask")

    local eroded_brain
    eroded_brain="$(dirname "$out_mask")/.fp_brain_eroded_$$.nii.gz"

    # Erode using a spherical kernel of radius erosion_mm (matches PV-band
    # erosion convention in analysis.sh: -kernel sphere <mm> -ero).
    if ! _fp_fslmaths "Erode brain mask for FP edge suppression" \
            "$brain_mask" -bin -kernel sphere "$erosion_mm" -ero "$eroded_brain"; then
        log_formatted "WARNING" "fp_filter_brainmask_erosion: brain-mask erosion failed; passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        rm -f "$eroded_brain" 2>/dev/null || true
        return 0
    fi

    # Keep only lesion voxels inside the eroded brain.
    if ! _fp_fslmaths "Restrict lesion mask to eroded brain" \
            "$in_mask" -mas "$eroded_brain" -bin "$out_mask"; then
        log_formatted "WARNING" "fp_filter_brainmask_erosion: masking failed; passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        rm -f "$eroded_brain" 2>/dev/null || true
        return 0
    fi
    rm -f "$eroded_brain" 2>/dev/null || true

    local voxels_after
    voxels_after=$(_fp_count_voxels "$out_mask")
    local removed=$(( voxels_before - voxels_after ))
    if [ "$removed" -lt 0 ]; then removed=0; fi

    if [ "$removed" -gt 0 ]; then
        log_formatted "WARNING" \
            "fp_filter_brainmask_erosion REMOVED $removed near-edge voxel(s) (outside brain eroded by ${erosion_mm}mm): ${voxels_before} -> ${voxels_after}"
    else
        log_message "fp_filter_brainmask_erosion: no voxels removed"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 3. CSF-distance filter
# ------------------------------------------------------------------------------
# Exclude lesion CLUSTERS that lie within FP_CSF_DISTANCE_MM of a CSF mask.
# Reuses the FAST CSF PVE map the pipeline already produces for #114
# (${out_prefix}_csf_prob.nii.gz).  Builds a CSF "proximity band" by dilating
# the binarised CSF mask outward by FP_CSF_DISTANCE_MM and drops any lesion
# component that overlaps the band (Pai 2025 peri-CSF residual suppression).
#
# A whole-CLUSTER drop (rather than per-voxel) is used so a single touching
# voxel removes the spurious peri-CSF blob, not just its rim.
#
# Pure: <in_mask> + <csf_prob_or_mask> -> <out_mask>.  Degrades gracefully
# (pass through) if the CSF map is missing.
fp_filter_csf_distance() {
    local in_mask="$1"
    local csf_map="$2"
    local out_mask="$3"
    local distance_mm="${4:-${FP_CSF_DISTANCE_MM:-1}}"
    local csf_threshold="${5:-${CSF_PVE_THRESHOLD:-0.5}}"
    local connectivity="${6:-${FP_CLUSTER_CONNECTIVITY:-26}}"

    log_message "fp_filter_csf_distance: in=$in_mask csf=$csf_map out=$out_mask distance_mm=$distance_mm csf_thr=$csf_threshold"

    local _rc
    _fp_require_mask "fp_filter_csf_distance" "$in_mask"; _rc=$?
    if [ "$_rc" -ne 0 ]; then return "$_rc"; fi

    mkdir -p "$(dirname "$out_mask")" 2>/dev/null || true

    if [ -z "$csf_map" ] || [ ! -f "$csf_map" ]; then
        log_formatted "WARNING" "fp_filter_csf_distance: CSF map not available ($csf_map); passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        return 0
    fi

    local voxels_before
    voxels_before=$(_fp_count_voxels "$in_mask")

    local work_dir
    work_dir="$(dirname "$out_mask")"
    local csf_bin="${work_dir}/.fp_csf_bin_$$.nii.gz"
    local csf_band="${work_dir}/.fp_csf_band_$$.nii.gz"
    local lesion_index="${work_dir}/.fp_csf_index_$$.nii.gz"

    # Binarise CSF map (handles both a probability PVE map and an already-binary
    # CSF mask: -thr <csf_threshold> -bin).
    if ! _fp_fslmaths "Binarise CSF map for distance band" \
            "$csf_map" -thr "$csf_threshold" -bin "$csf_bin"; then
        log_formatted "WARNING" "fp_filter_csf_distance: CSF binarisation failed; passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        rm -f "$csf_bin" "$csf_band" "$lesion_index" 2>/dev/null || true
        return 0
    fi

    # Build a CSF proximity band by dilating the CSF mask outward.
    # `-kernel sphere <mm> -dilM` dilates by a spherical mm radius, giving a
    # true distance band that respects voxel geometry.
    if ! _fp_fslmaths "Dilate CSF mask into proximity band" \
            "$csf_bin" -kernel sphere "$distance_mm" -dilM -bin "$csf_band"; then
        log_formatted "WARNING" "fp_filter_csf_distance: CSF dilation failed; passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        rm -f "$csf_bin" "$csf_band" "$lesion_index" 2>/dev/null || true
        return 0
    fi

    # Label the lesion mask into connected components.
    if ! cluster --in="$in_mask" --thresh=0.5 --connectivity="$connectivity" \
                 --oindex="$lesion_index" > /dev/null 2>&1; then
        log_formatted "WARNING" "fp_filter_csf_distance: lesion clustering failed; passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        rm -f "$csf_bin" "$csf_band" "$lesion_index" 2>/dev/null || true
        return 0
    fi

    # Highest component label = number of components.
    local max_label
    max_label=$(fslstats "$lesion_index" -R 2>/dev/null | awk '{print $2}')
    local max_label_int=0
    if [[ "$max_label" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        max_label_int=$(printf '%.0f' "$max_label" 2>/dev/null || echo 0)
    fi

    if [ "$max_label_int" -le 0 ]; then
        log_message "fp_filter_csf_distance: input mask empty / no components; mask unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        rm -f "$csf_bin" "$csf_band" "$lesion_index" 2>/dev/null || true
        return 0
    fi

    # Build keep mask by iterating components and dropping any that overlap the
    # CSF band.  Component count is small for brainstem ROIs, so per-component
    # testing is cheap and robust across FSL versions.
    local keep_mask="${work_dir}/.fp_csf_keep_$$.nii.gz"
    _fp_fslmaths "Init CSF-distance keep mask" "$in_mask" -mul 0 "$keep_mask" || true

    local label
    local kept_components=0
    local dropped_components=0
    for (( label=1; label<=max_label_int; label++ )); do
        local comp="${work_dir}/.fp_csf_comp_${label}_$$.nii.gz"
        local comp_band="${work_dir}/.fp_csf_compband_${label}_$$.nii.gz"
        # Isolate this component: voxels equal to `label`.
        if ! _fp_fslmaths "Isolate component $label" \
                "$lesion_index" -thr "$label" -uthr "$label" -bin "$comp"; then
            rm -f "$comp" 2>/dev/null || true
            continue
        fi
        # Does it overlap the CSF band?
        _fp_fslmaths "Test component $label against CSF band" \
            "$comp" -mas "$csf_band" "$comp_band" || true
        local band_overlap
        band_overlap=$(_fp_count_voxels "$comp_band")
        if [ "$band_overlap" -gt 0 ]; then
            dropped_components=$(( dropped_components + 1 ))
        else
            # Keep this component (add it into the keep mask).
            _fp_fslmaths "Keep component $label" \
                "$keep_mask" -add "$comp" -bin "$keep_mask" || true
            kept_components=$(( kept_components + 1 ))
        fi
        rm -f "$comp" "$comp_band" 2>/dev/null || true
    done

    # Final output is the union of kept components.
    if ! _fp_fslmaths "Binarise CSF-distance-filtered mask" \
            "$keep_mask" -bin "$out_mask"; then
        log_formatted "WARNING" "fp_filter_csf_distance: failed to write filtered mask; passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
    fi

    rm -f "$csf_bin" "$csf_band" "$lesion_index" "$keep_mask" 2>/dev/null || true

    local voxels_after
    voxels_after=$(_fp_count_voxels "$out_mask")
    local removed=$(( voxels_before - voxels_after ))
    if [ "$removed" -lt 0 ]; then removed=0; fi

    if [ "$removed" -gt 0 ] || [ "$dropped_components" -gt 0 ]; then
        log_formatted "WARNING" \
            "fp_filter_csf_distance REMOVED $dropped_components cluster(s) / $removed voxel(s) within ${distance_mm}mm of CSF: ${voxels_before} -> ${voxels_after} (kept $kept_components cluster(s))"
    else
        log_message "fp_filter_csf_distance: no clusters removed"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 4. SegAE / Atlason CSF-pulsation-artifact filter
# ------------------------------------------------------------------------------
# Adapt the SegAE / Atlason CSF-pulsation-artifact approach (Atlason et al.,
# PLOS ONE 2022;17(8):e0274212; open source lmellingsen/Ventricle_WMH_segmentation).
# Algorithm is ADAPTED, not copied (license unclear): compute an element-wise
# CSF x lesion SOFT-segmentation product to estimate pulsation-artifact voxels,
# then SUBTRACT those voxels from the lesion mask.
#
# Intuition: a voxel that is simultaneously assigned non-trivial CSF probability
# AND flagged as lesion is, in periventricular / peri-cisternal regions, very
# likely a CSF-pulsation artifact rather than a true parenchymal lesion.  The
# product p_csf * p_lesion is high exactly at those artifact voxels; thresholding
# the product and removing it suppresses pulsation FPs while leaving deep,
# low-CSF-probability lesions intact.
#
# Requires a CSF PROBABILITY map (soft segmentation).  Gated behind
# FP_SEGAE_ENABLED; degrades gracefully (pass through) if the CSF prob map is
# absent or the stage is disabled.
#
# DESIGN NOTE on gating asymmetry: the other three stage functions
# (min_cluster / brainmask_erosion / csf_distance) are pure filters that ALWAYS
# act when called directly - their FP_*_ENABLED flags are honoured only by
# run_fp_filter.  This function is the deliberate exception: it self-checks
# FP_SEGAE_ENABLED because SegAE is OFF by default (it is the most experimental
# stage and needs a soft probability map), so a direct call must not silently
# run it.  FP_SEGAE_ENABLED therefore doubles as the SegAE stage gate.
#
# Pure: <in_mask> + <csf_prob> -> <out_mask>.
fp_filter_segae_pulsation() {
    local in_mask="$1"
    local csf_prob="$2"
    local out_mask="$3"
    local product_threshold="${4:-${FP_SEGAE_PRODUCT_THRESHOLD:-0.5}}"

    log_message "fp_filter_segae_pulsation: in=$in_mask csf_prob=$csf_prob out=$out_mask product_thr=$product_threshold"

    local _rc
    _fp_require_mask "fp_filter_segae_pulsation" "$in_mask"; _rc=$?
    if [ "$_rc" -ne 0 ]; then return "$_rc"; fi

    mkdir -p "$(dirname "$out_mask")" 2>/dev/null || true

    if [ "${FP_SEGAE_ENABLED:-false}" != "true" ]; then
        log_message "fp_filter_segae_pulsation: disabled (FP_SEGAE_ENABLED != true); passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        return 0
    fi

    if [ -z "$csf_prob" ] || [ ! -f "$csf_prob" ]; then
        log_formatted "WARNING" "fp_filter_segae_pulsation: CSF probability map not available ($csf_prob); SegAE pulsation filter skipped (mask unchanged)"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        return 0
    fi

    local voxels_before
    voxels_before=$(_fp_count_voxels "$in_mask")

    local work_dir
    work_dir="$(dirname "$out_mask")"
    local product="${work_dir}/.fp_segae_product_$$.nii.gz"
    local artifact="${work_dir}/.fp_segae_artifact_$$.nii.gz"

    # Element-wise CSF(soft) x lesion(soft/binary) product.  The lesion mask is
    # binary here (post-detection), so the product equals the CSF probability at
    # lesion voxels and 0 elsewhere - exactly the "lesion-weighted CSF evidence"
    # SegAE uses to localise pulsation artifacts.
    if ! _fp_fslmaths "Compute CSF x lesion soft product (SegAE)" \
            "$csf_prob" -mul "$in_mask" "$product"; then
        log_formatted "WARNING" "fp_filter_segae_pulsation: product computation failed; passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        rm -f "$product" "$artifact" 2>/dev/null || true
        return 0
    fi

    # Threshold the product to estimate pulsation-artifact voxels.
    if ! _fp_fslmaths "Threshold CSF x lesion product into artifact mask" \
            "$product" -thr "$product_threshold" -bin "$artifact"; then
        log_formatted "WARNING" "fp_filter_segae_pulsation: artifact thresholding failed; passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        rm -f "$product" "$artifact" 2>/dev/null || true
        return 0
    fi

    # Subtract estimated artifact voxels from the lesion mask.
    if ! _fp_fslmaths "Subtract SegAE pulsation artifact from lesion mask" \
            "$in_mask" -sub "$artifact" -thr 0 -bin "$out_mask"; then
        log_formatted "WARNING" "fp_filter_segae_pulsation: subtraction failed; passing mask through unchanged"
        cp "$in_mask" "$out_mask" 2>/dev/null || true
        rm -f "$product" "$artifact" 2>/dev/null || true
        return 0
    fi
    rm -f "$product" "$artifact" 2>/dev/null || true

    local voxels_after
    voxels_after=$(_fp_count_voxels "$out_mask")
    local removed=$(( voxels_before - voxels_after ))
    if [ "$removed" -lt 0 ]; then removed=0; fi

    if [ "$removed" -gt 0 ]; then
        log_formatted "WARNING" \
            "fp_filter_segae_pulsation REMOVED $removed estimated CSF-pulsation-artifact voxel(s) (product > ${product_threshold}): ${voxels_before} -> ${voxels_after}"
    else
        log_message "fp_filter_segae_pulsation: no artifact voxels removed"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Dispatcher
# ------------------------------------------------------------------------------
# run_fp_filter <in_mask> <out_mask> [<brain_mask>] [<csf_prob>]
#
# Applies the ENABLED FP-suppression stages in a fixed order, threading the
# output of each stage into the next, logging counts removed at every stage.
# Master switch FP_FILTER_ENABLED gates the whole pipeline (default OFF).  Each
# stage is additionally gated by its own config flag / availability of inputs.
#
# Stage order (cheapest / least-lossy first):
#   1. brain-mask erosion   (geometric, only drops near-edge voxels)
#   2. CSF-distance         (drops peri-CSF clusters)
#   3. SegAE pulsation      (drops CSF x lesion product voxels)
#   4. min-cluster size     (LAST, most lossy - Molchanova 2024 caveat)
#
# Pure: <in_mask> -> <out_mask>.  Leaves a passthrough copy if disabled.
run_fp_filter() {
    local in_mask="$1"
    local out_mask="$2"
    local brain_mask="${3:-}"
    local csf_prob="${4:-}"

    log_message "run_fp_filter: in=$in_mask out=$out_mask brain=${brain_mask:-<none>} csf=${csf_prob:-<none>}"

    local _rc
    _fp_require_mask "run_fp_filter" "$in_mask"; _rc=$?
    if [ "$_rc" -ne 0 ]; then return "$_rc"; fi

    mkdir -p "$(dirname "$out_mask")" 2>/dev/null || true

    if [ "${FP_FILTER_ENABLED:-false}" != "true" ]; then
        log_message "run_fp_filter: FP_FILTER_ENABLED != true; passing mask through unchanged (no-op)"
        if ! cp "$in_mask" "$out_mask" 2>/dev/null; then
            log_error "run_fp_filter: failed to write passthrough output $out_mask" "${ERR_IO_ERROR:-5}"
            return "${ERR_IO_ERROR:-5}"
        fi
        return 0
    fi

    local voxels_start
    voxels_start=$(_fp_count_voxels "$in_mask")
    log_formatted "INFO" "run_fp_filter: starting with $voxels_start lesion voxel(s)"

    local work_dir
    work_dir="$(dirname "$out_mask")"
    local stage_in="$in_mask"
    local stage_out=""
    local applied_any=false

    # --- Stage 1: brain-mask erosion -----------------------------------------
    if [ "${FP_BRAINMASK_EROSION_ENABLED:-true}" = "true" ] && [ -n "$brain_mask" ] && [ -f "$brain_mask" ]; then
        stage_out="${work_dir}/.fp_stage_brainero_$$.nii.gz"
        if fp_filter_brainmask_erosion "$stage_in" "$brain_mask" "$stage_out"; then
            stage_in="$stage_out"
            applied_any=true
        fi
    else
        log_message "run_fp_filter: skipping brain-mask erosion (disabled or no brain mask)"
    fi

    # --- Stage 2: CSF-distance -----------------------------------------------
    if [ "${FP_CSF_DISTANCE_ENABLED:-true}" = "true" ] && [ -n "$csf_prob" ] && [ -f "$csf_prob" ]; then
        stage_out="${work_dir}/.fp_stage_csfdist_$$.nii.gz"
        if fp_filter_csf_distance "$stage_in" "$csf_prob" "$stage_out"; then
            stage_in="$stage_out"
            applied_any=true
        fi
    else
        log_message "run_fp_filter: skipping CSF-distance filter (disabled or no CSF map)"
    fi

    # --- Stage 3: SegAE pulsation --------------------------------------------
    if [ "${FP_SEGAE_ENABLED:-false}" = "true" ] && [ -n "$csf_prob" ] && [ -f "$csf_prob" ]; then
        stage_out="${work_dir}/.fp_stage_segae_$$.nii.gz"
        if fp_filter_segae_pulsation "$stage_in" "$csf_prob" "$stage_out"; then
            stage_in="$stage_out"
            applied_any=true
        fi
    else
        log_message "run_fp_filter: skipping SegAE pulsation filter (disabled or no CSF prob map)"
    fi

    # --- Stage 4: min-cluster size (LAST; most lossy) ------------------------
    if [ "${FP_MIN_CLUSTER_ENABLED:-true}" = "true" ]; then
        stage_out="${work_dir}/.fp_stage_mincluster_$$.nii.gz"
        if fp_filter_min_cluster "$stage_in" "$stage_out"; then
            stage_in="$stage_out"
            applied_any=true
        fi
    else
        log_message "run_fp_filter: skipping min-cluster filter (disabled)"
    fi

    # Materialise final result.  Pick the source: the last successful stage
    # output if one exists, otherwise the original input (passthrough).
    local final_src="$in_mask"
    if [ "$applied_any" = "true" ] && [ -f "$stage_in" ]; then
        final_src="$stage_in"
    else
        # No stage produced usable output (all disabled / unavailable / a stage
        # silently failed to write): fall back to the original mask.
        log_formatted "WARNING" "run_fp_filter: no stage produced output; passing mask through unchanged"
    fi
    # Surface a real copy failure (unwritable dir, ENOSPC) instead of swallowing
    # it - otherwise the caller gets a 0 return with no/stale out_mask.
    if ! cp "$final_src" "$out_mask" 2>/dev/null; then
        log_error "run_fp_filter: failed to write output mask $out_mask" "${ERR_IO_ERROR:-5}"
        return "${ERR_IO_ERROR:-5}"
    fi

    # Clean up intermediate stage files.
    rm -f "${work_dir}/.fp_stage_brainero_$$.nii.gz" \
          "${work_dir}/.fp_stage_csfdist_$$.nii.gz" \
          "${work_dir}/.fp_stage_segae_$$.nii.gz" \
          "${work_dir}/.fp_stage_mincluster_$$.nii.gz" 2>/dev/null || true

    local voxels_end
    voxels_end=$(_fp_count_voxels "$out_mask")
    local total_removed=$(( voxels_start - voxels_end ))
    if [ "$total_removed" -lt 0 ]; then total_removed=0; fi
    log_formatted "INFO" "run_fp_filter: finished. $voxels_start -> $voxels_end voxel(s) (TOTAL removed: $total_removed)"
    return 0
}

# Export functions so subshells / parallel jobs can use them (matches pipeline
# convention, e.g. `export -f safe_fslmaths`).
export -f _fp_count_voxels 2>/dev/null || true
export -f _fp_require_mask 2>/dev/null || true
export -f fp_filter_min_cluster 2>/dev/null || true
export -f fp_filter_brainmask_erosion 2>/dev/null || true
export -f fp_filter_csf_distance 2>/dev/null || true
export -f fp_filter_segae_pulsation 2>/dev/null || true
export -f run_fp_filter 2>/dev/null || true
