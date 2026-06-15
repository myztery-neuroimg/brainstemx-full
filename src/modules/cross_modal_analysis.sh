#!/usr/bin/env bash
#
# cross_modal_analysis.sh - per-cluster cross-modal corroboration of FLAIR
#                           hyperintensities using co-registered SWI/DWI/T2/ADC.
#
# This is the step that makes BrainStemX genuinely MULTI-modal. The PRIMARY
# detection (analysis.sh detect_hyperintensities) finds and clusters brainstem
# FLAIR hyperintensities. AFTER that, this module samples the co-registered
# SECONDARY modalities inside each cluster ROI and annotates corroboration:
#
#   DWI restriction (trace UP + ADC DOWN) -> acute / ischemic
#   SWI hypointensity                     -> hemorrhage / microbleed
#   T2 hyperintensity                     -> corroborates the FLAIR finding
#
# It NEVER re-detects lesions and NEVER alters the primary mask — it is pure
# corroboration on top of the primary clusters, with full per-cluster provenance.
#
# GRACEFUL: with no co-registered secondary modality present (e.g. a T1+FLAIR-only
# study) the step logs "nothing to corroborate" and returns success (no-op). Each
# modality is gated on its own presence, so partial sets (say SWI but no DWI)
# work fine.
#
# Conventions: log_* / ERR_* from environment.sh, safe_fslmaths/apply_transform
# wrappers, config toggles in config/default_config.sh (CROSS_MODAL_* block).

# Lightweight include guard.
if [ -n "${_CROSS_MODAL_ANALYSIS_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_CROSS_MODAL_ANALYSIS_LOADED=1

# Lightweight environment guard (fast no-op when the pipeline already loaded it;
# fails fast with instructions if a user sources this module standalone).
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# ---------------------------------------------------------------------------
# _cross_modal_python
#   Echo a python launcher that has numpy + nibabel (prefer uv, then fslpython,
#   then python3). Returns non-zero if none is usable.
# ---------------------------------------------------------------------------
_cross_modal_python() {
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
    if command -v python3 >/dev/null 2>&1 && \
       python3 -c "import numpy, nibabel" >/dev/null 2>&1; then
        echo "python3"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# _cross_modal_find_coregistered <modality_name> <reg_dir>
#   Find the best co-registered volume for a secondary modality produced by the
#   contrast-matched cascade. Prefers the FLAIR-anchor-space resample
#   (<base>_to_flairWarped.nii.gz) since the analysis runs in (a regrid of)
#   FLAIR space; falls back to the composed-to-T1 resample. Echoes the path or
#   empty. The cascade names outputs from the source basename, so we match on
#   the modality keyword family within the contrast_matched dir.
# ---------------------------------------------------------------------------
_cross_modal_find_coregistered() {
    local modality="$1"
    local reg_dir="$2"
    local cm_dir="${reg_dir}/${CONTRAST_MATCHED_SUBDIR:-contrast_matched}"
    [ -d "$cm_dir" ] || { echo ""; return 1; }

    # Keyword set per modality (mirrors scan selection / detect_modality).
    local kw
    case "${modality^^}" in
        T2)  kw="T2 SPACE" ;;
        SWI) kw="SWI SWAN susceptib t2_hemo venobold" ;;
        DWI) kw="DWI trace TRACE b1000 diffusion" ;;
        ADC) kw="ADC adc" ;;
        *)   kw="$modality" ;;
    esac

    # The DWI trace and the ADC map can share the "DWI" keyword (e.g. an ADC map
    # named EPI_DWI_ADC). Exclude any ADC match from the DWI trace slot BEFORE
    # collapsing to one result, so the trace is never lost to find ordering.
    local dwi_excl="cat"
    [ "${modality^^}" = "DWI" ] && dwi_excl="grep -vi adc"

    local k found suffix
    # Pass 1: FLAIR-anchor-space resample (closest to the analysis space).
    # Pass 2: composed-to-T1 resample.
    for suffix in "_to_flairWarped.nii.gz" "_to_t1_composedWarped.nii.gz"; do
        for k in $kw; do
            found=$(find "$cm_dir" -maxdepth 1 -type f -iname "*${k}*${suffix}" \
                        ! -iname "*FLAIR*to_flair*" 2>/dev/null \
                        | $dwi_excl | head -1)
            [ -n "$found" ] && { echo "$found"; return 0; }
        done
    done
    echo ""
    return 1
}

# ---------------------------------------------------------------------------
# run_cross_modal_analysis
#   <clusters_index_nifti> <brainstem_mask> <flair_analysis_space> <reg_dir>
#   <output_dir>
#
#   clusters_index_nifti : integer cluster-label volume from the primary
#                          detection (analyze_hyperintensity_clusters' clusters.nii.gz),
#                          in the analysis (FLAIR) space.
#   brainstem_mask       : brainstem segmentation in the analysis space (ROI for
#                          z-scoring); falls back to whole-volume if missing.
#   flair_analysis_space : the FLAIR intensity image the clusters were detected on.
#   reg_dir              : RESULTS_DIR/registered (holds contrast_matched/ outputs).
#   output_dir           : where the per-cluster table + summary are written.
#
# Returns 0 on success or graceful no-op; non-zero only on hard failure with the
# feature enabled and inputs present but unusable.
# ---------------------------------------------------------------------------
run_cross_modal_analysis() {
    local clusters="$1"
    local brainstem_mask="$2"
    local flair_img="$3"
    local reg_dir="$4"
    local output_dir="$5"

    if [ "${CROSS_MODAL_ANALYSIS_ENABLED:-true}" != "true" ]; then
        log_message "Cross-modal analysis disabled (CROSS_MODAL_ANALYSIS_ENABLED != true) - skipping"
        return 0
    fi

    log_formatted "INFO" "===== CROSS-MODAL CORROBORATION ANALYSIS ====="

    if [ -z "$clusters" ] || [ ! -f "$clusters" ]; then
        log_formatted "WARNING" "Cross-modal: cluster index volume not found ($clusters) - nothing to corroborate"
        return 0
    fi
    if [ -z "$flair_img" ] || [ ! -f "$flair_img" ]; then
        log_formatted "WARNING" "Cross-modal: FLAIR image not found ($flair_img) - skipping"
        return 0
    fi

    mkdir -p "$output_dir"
    local resampled_dir="${output_dir}/resampled"
    mkdir -p "$resampled_dir"

    # Discover + regrid the co-registered secondary modalities onto the cluster
    # grid. Each modality is gated on its own presence (graceful partial sets).
    # Default the list element-by-element (NOT "${arr[@]:-a b c}", which collapses
    # the fallback into a single 'a b c' element when the array is unset).
    # ${var+x} is the set-test that is safe under `set -u` even when fully unset.
    local mods=()
    if [ -n "${MULTIMODAL_SECONDARY_MODALITIES+x}" ] && \
       [ "${#MULTIMODAL_SECONDARY_MODALITIES[@]}" -gt 0 ]; then
        mods=("${MULTIMODAL_SECONDARY_MODALITIES[@]}")
    else
        mods=(T2 SWI DWI ADC)
    fi
    local mod_args=()
    local mod found resampled present_count=0
    for mod in "${mods[@]}"; do
        found="$(_cross_modal_find_coregistered "$mod" "$reg_dir" 2>/dev/null || true)"
        if [ -z "$found" ] || [ ! -f "$found" ]; then
            log_message "Cross-modal: ${mod} not co-registered (skipping)"
            continue
        fi
        log_message "Cross-modal: ${mod} co-registered volume: $found"

        # Regrid onto the EXACT cluster grid so voxelwise sampling is valid.
        resampled="${resampled_dir}/${mod}_on_clusters.nii.gz"
        if apply_transform "$found" "$clusters" "-usesqform" "$resampled" "trilinear" \
                && [ -f "$resampled" ]; then
            mod_args+=("--modality" "${mod}:${resampled}")
            present_count=$((present_count + 1))
        else
            log_formatted "WARNING" "Cross-modal: failed to regrid ${mod} onto cluster grid (skipping)"
        fi
    done

    if [ "$present_count" -eq 0 ]; then
        log_message "Cross-modal: no co-registered secondary modalities present; nothing to corroborate (T1+FLAIR-only behaviour)"
        # Leave a stub so downstream tools find a deterministic path. The header
        # MUST match cross_modal_sample.py's zero-modality schema (build_header
        # with no modality columns) so the same filename never has two schemas.
        local stub="${output_dir}/cross_modal_clusters.csv"
        printf 'cluster_id,n_voxels,cog_x,cog_y,cog_z,flair_mean,flair_z,corroboration,n_corroborating\n' > "$stub"
        log_message "Cross-modal: wrote empty table stub: $stub"
        return 0
    fi

    # Resolve a python launcher with numpy + nibabel.
    local py
    if ! py="$(_cross_modal_python)"; then
        log_formatted "WARNING" "Cross-modal: no python with numpy+nibabel available - skipping (non-fatal)"
        return 0
    fi

    local script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cross_modal_sample.py"
    if [ ! -f "$script" ]; then
        log_formatted "WARNING" "Cross-modal: sampler script not found ($script) - skipping"
        return 0
    fi

    # Brainstem ROI for z-scoring; tolerate absence. Pass the sentinel "NONE"
    # (NOT the cluster volume) so the sampler z-scores over the nonzero-FLAIR
    # brain extent rather than only the lesion voxels (which would make every
    # cluster z degenerate toward 0 and suppress all corroboration flags).
    local bs_arg="$brainstem_mask"
    if [ -z "$bs_arg" ] || [ ! -f "$bs_arg" ]; then
        log_message "Cross-modal: brainstem mask unavailable; sampler will z-score over the nonzero-FLAIR brain extent"
        bs_arg="NONE"
    fi

    local out_csv="${output_dir}/cross_modal_clusters.csv"
    local out_summary="${output_dir}/cross_modal_summary.txt"

    log_message "Cross-modal: sampling ${present_count} modality(ies) over clusters via: $py"
    local cm_out cm_status=0
    # shellcheck disable=SC2086
    cm_out=$($py "$script" "$clusters" "$bs_arg" "$flair_img" \
        "${mod_args[@]}" \
        --out-csv "$out_csv" \
        --out-summary "$out_summary" \
        --min-voxels "${CROSS_MODAL_MIN_CLUSTER_VOXELS:-5}" \
        --dwi-trace-z "${CROSS_MODAL_DWI_TRACE_Z:-1.0}" \
        --adc-z "${CROSS_MODAL_ADC_Z:--1.0}" \
        --swi-z "${CROSS_MODAL_SWI_Z:--1.5}" \
        --t2-z "${CROSS_MODAL_T2_Z:-1.0}" \
        2>"${output_dir}/cross_modal_sampler.log") || cm_status=$?

    # Surface the sampler diagnostics into the pipeline log.
    if [ -f "${output_dir}/cross_modal_sampler.log" ]; then
        while IFS= read -r line; do
            log_message "Cross-modal: $line"
        done < "${output_dir}/cross_modal_sampler.log"
    fi

    if [ "$cm_status" -ne 0 ]; then
        log_formatted "WARNING" "Cross-modal sampler exited non-zero (status $cm_status) - non-fatal"
        return 0
    fi

    # Echo the key=value summary the sampler emitted on stdout.
    if [ -n "$cm_out" ]; then
        while IFS= read -r kv; do
            [ -n "$kv" ] && log_message "Cross-modal result: $kv"
        done <<< "$cm_out"
    fi

    if [ -f "$out_csv" ]; then
        log_formatted "SUCCESS" "Cross-modal per-cluster table: $out_csv"
    fi
    if [ -f "$out_summary" ]; then
        log_message "Cross-modal corroboration summary: $out_summary"
    fi
    return 0
}

export -f _cross_modal_python
export -f _cross_modal_find_coregistered
export -f run_cross_modal_analysis

log_message "Cross-modal analysis module loaded (SWI/DWI/T2 per-cluster corroboration)"
