#!/usr/bin/env bash
# src/modules/segmentation.sh
# Brainstem segmentation: Harvard-Oxford gross extent + FreeSurfer substructures.
# (The legacy "hierarchical joint fusion" entry point is a single-atlas HO SyN
#  warp — see hierarchical_joint_fusion.sh for the naming note.)

source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"
source "config/default_config.sh"

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/hierarchical_joint_fusion.sh"
source "$(dirname "${BASH_SOURCE[0]}")/brainstem_freesurfer.sh"
source "$(dirname "${BASH_SOURCE[0]}")/multi_atlas.sh"

# Main segmentation function - Harvard-Oxford gross brainstem extraction
extract_brainstem() {
    local input_file="$1"
    local input_basename="$2"
    local flair_file=""  # Optional FLAIR file

    log_formatted "INFO" "=== BRAINSTEM SEGMENTATION (HARVARD-OXFORD GROSS EXTENT) ==="
    log_message "Processing: $input_file"
    log_message "Basename: $input_basename"
    [[ -n "$flair_file" ]] && log_message "FLAIR file: $flair_file"
    
    # Validate input file
    if [[ ! -f "$input_file" ]]; then
        log_formatted "ERROR" "Input file does not exist: $input_file"
        return 1
    fi
    
    # Create output directory structure
    local brainstem_dir="${RESULTS_DIR}/segmentation/brainstem"
    mkdir -p "$brainstem_dir"

    # Create temporary workspace
    local temp_dir="${RESULTS_DIR}/segmentation"

    # Set output prefix (directory + basename so files are named correctly)
    local output_prefix="${brainstem_dir}/${input_basename}"
    
    # Execute Harvard-Oxford gross brainstem extraction (single-atlas SyN warp;
    # the function name is legacy — see hierarchical_joint_fusion.sh).
    if execute_hierarchical_joint_fusion "$input_file" "$output_prefix" "$temp_dir"; then
        log_formatted "SUCCESS" "Harvard-Oxford gross brainstem extraction completed"
    else
        log_formatted "ERROR" "Harvard-Oxford gross brainstem extraction failed"
        #srm -rf "$temp_dir"
        return 1
    fi
    
    # Enhance with FLAIR data if available
    if [[ -n "$flair_file" ]] && [[ -f "$flair_file" ]]; then
        enhance_segmentation_with_flair "$output_prefix" "$flair_file" || {
            log_formatted "WARNING" "FLAIR enhancement failed, continuing with T1-based segmentation"
        }
    fi
    
    # Generate comprehensive segmentation report
    generate_segmentation_report "$output_prefix" "$input_file" "$flair_file" || {
        log_formatted "WARNING" "Report generation failed"
    }
    
    # Clean up temporary files
    #rm -rf "$temp_dir"
    
    log_formatted "SUCCESS" "Brainstem segmentation completed successfully"
    return 0
}

enhance_segmentation_with_flair() {
    local output_prefix="$1"
    local flair_file="$2"
    
    log_message "Enhancing segmentation with FLAIR intensity information..."
    
    local brainstem_mask="${output_prefix}_brainstem.nii.gz"
    local flair_intensity="${output_prefix}_brainstem_flair_intensity.nii.gz"
    
    if [[ ! -f "$brainstem_mask" ]]; then
        log_formatted "ERROR" "Brainstem mask not found for FLAIR enhancement"
        return 1
    fi
    
    # Create FLAIR intensity mask
    fslmaths "$flair_file" -mul "$brainstem_mask" "$flair_intensity"

    # Enhance FreeSurfer brainstem parcels with FLAIR (when present).
    local detailed_dir="${RESULTS_DIR}/segmentation/detailed_brainstem"
    if [[ -d "$detailed_dir" ]]; then
        local flair_detailed_dir="${detailed_dir}_flair"
        mkdir -p "$flair_detailed_dir"

        for region_mask in "$detailed_dir"/*.nii.gz; do
            [[ -f "$region_mask" ]] || continue
            local region_name=$(basename "$region_mask" .nii.gz)
            local flair_region="${flair_detailed_dir}/${region_name}_flair.nii.gz"
            fslmaths "$flair_file" -mul "$region_mask" "$flair_region"
        done

        log_message "  ✓ FLAIR-enhanced parcels: $flair_detailed_dir"
    fi

    log_message "  ✓ FLAIR intensity enhancement completed"
    return 0
}

generate_segmentation_report() {
    local output_prefix="$1"
    local input_file="$2"
    local flair_file="$3"
    
    log_message "Generating comprehensive segmentation report..."
    
    local report_file="${output_prefix}_segmentation_report.txt"
    local brainstem_mask="${output_prefix}_brainstem.nii.gz"
    
    local detailed_dir="${RESULTS_DIR}/segmentation/detailed_brainstem"

    cat > "$report_file" <<EOF
================================================================================
BRAINSTEM SEGMENTATION REPORT
================================================================================
Generated: $(date)
Subject: $(basename "$output_prefix")
Template Resolution: ${DEFAULT_TEMPLATE_RES:-1mm}
Brainstem method: $(_seg_method_report_line)

INPUT FILES
-----------
T1 Image: $input_file
$([ -n "$flair_file" ] && echo "FLAIR Image: $flair_file")

PRIMARY OUTPUTS
---------------
1. Unified Brainstem Mask: $brainstem_mask

2. Hemisphere Masks (for asymmetry analysis):
   - Left hemisphere: ${output_prefix}_left_hemisphere.nii.gz
   - Right hemisphere: ${output_prefix}_right_hemisphere.nii.gz

3. Brainstem Substructures (FreeSurfer parcels, when available):
   Directory: ${detailed_dir}/
   Regions: midbrain, pons, medulla, scp (plus left/right splits)

$([ -n "$flair_file" ] && echo "4. FLAIR-Enhanced Outputs:
   - FLAIR intensity mask: ${output_prefix}_brainstem_flair_intensity.nii.gz
   - FLAIR parcels: ${detailed_dir}_flair/")

SEGMENTATION STATISTICS
-----------------------
EOF
    
    # Add volume statistics
    if [[ -f "$brainstem_mask" ]]; then
        local total_voxels=$(fslstats "$brainstem_mask" -V | awk '{print $1}')
        local voxel_volume=$(fslval "$brainstem_mask" pixdim1)
        voxel_volume=$(echo "$voxel_volume * $(fslval "$brainstem_mask" pixdim2) * $(fslval "$brainstem_mask" pixdim3)" | bc -l)
        local total_volume_mm3=$(echo "$total_voxels * $voxel_volume" | bc -l)
        
        echo "Total brainstem voxels: $total_voxels" >> "$report_file"
        echo "Estimated volume (mm³): $(printf "%.1f" "$total_volume_mm3")" >> "$report_file"
        echo "" >> "$report_file"
    fi
    
    # Add substructure statistics (FreeSurfer parcels)
    if [[ -d "$detailed_dir" ]]; then
        echo "BRAINSTEM SUBSTRUCTURE STATISTICS" >> "$report_file"
        echo "---------------------------------" >> "$report_file"

        for region_file in "$detailed_dir"/*.nii.gz; do
            [[ -f "$region_file" ]] || continue
            local region_name=$(basename "$region_file" .nii.gz)
            local region_voxels=$(fslstats "$region_file" -V | awk '{print $1}')
            echo "  ${region_name}: ${region_voxels} voxels" >> "$report_file"
        done
        echo "" >> "$report_file"
    fi

    cat >> "$report_file" <<EOF

VISUALIZATION COMMANDS
----------------------
To view the segmentation results:

# Primary brainstem on T1:
fsleyes $input_file $brainstem_mask -cm red -a 0.5

$([ -n "$flair_file" ] && echo "# Primary brainstem on FLAIR:
fsleyes $flair_file $brainstem_mask -cm red -a 0.5")

# Brainstem substructures:
fsleyes $input_file ${detailed_dir}/*.nii.gz -cm random -a 0.6

================================================================================
EOF
    
    log_message "  ✓ Segmentation report: $report_file"
    return 0
}

# ============================================================================
# MISSING FUNCTIONS FROM ORIGINAL - ADDED FOR COMPATIBILITY
# ============================================================================

# Enhanced FLAIR integration (from original)
extract_brainstem_with_flair() {
    local t1_file="$1"
    local flair_file="$2"
    local output_prefix="${3:-${RESULTS_DIR}/segmentation/brainstem/$(basename "$t1_file" .nii.gz)}"
    
    log_formatted "INFO" "=== ENHANCED SEGMENTATION WITH FLAIR INTEGRATION ==="
    
    # First get hierarchical joint fusion segmentation from T1
    local t1_brainstem="${output_prefix}_brainstem_t1based.nii.gz"
    if ! extract_brainstem "$t1_file" "$(basename "$t1_file" .nii.gz)" "$flair_file"; then
        log_formatted "ERROR" "T1-based hierarchical joint fusion segmentation failed"
        return 1
    fi
    
    # The new approach already integrates FLAIR if available
    log_formatted "SUCCESS" "Enhanced segmentation with FLAIR integration completed"
    return 0
}

# ---------------------------------------------------------------------------
# _seg_method_report_line - human-readable "Method:" descriptor for the reports
#
# For the parallel 'all' mode it lists which paths were ENABLED and (when the
# parallel run has populated SEG_ALL_PATHS_OK) which actually SUCCEEDED, so the
# report reflects the real provenance of the masks. For the exclusive methods it
# returns the legacy single-method description.
# ---------------------------------------------------------------------------
_seg_method_report_line() {
    local m="${BRAINSTEM_SEGMENTATION_METHOD:-all}"
    if [ "$m" != "all" ]; then
        echo "$m"
        return 0
    fi
    local enabled=""
    [ "${SEG_RUN_HARVARD_OXFORD:-true}" = "true" ] && enabled="${enabled}harvard_oxford "
    [ "${SEG_RUN_MULTI_ATLAS:-true}" = "true" ]    && enabled="${enabled}multi_atlas "
    [ "${SEG_RUN_FREESURFER:-true}" = "true" ]     && enabled="${enabled}freesurfer "
    enabled="${enabled% }"
    local line="all (parallel paths enabled: ${enabled:-none})"
    # Append the succeeded-paths list once the parallel run has populated the
    # array. Use the array length (not "${SEG_ALL_PATHS_OK:-}", which only tests
    # element 0) so an empty array is detected correctly. `declare -p` guards the
    # case where the variable was never set (set -u safe).
    if declare -p SEG_ALL_PATHS_OK >/dev/null 2>&1 && [ "${#SEG_ALL_PATHS_OK[@]}" -gt 0 ]; then
        line="${line}; succeeded: ${SEG_ALL_PATHS_OK[*]}"
    fi
    echo "$line"
}

# ---------------------------------------------------------------------------
# _compute_shared_mni_to_subject_warp - compute the MNI->subject SyN warp ONCE
#
# CONCURRENCY SAFETY: in 'all' mode the Harvard-Oxford path and the multi-atlas
# path both need the SAME MNI->subject SyN transform. If two background jobs each
# ran antsRegistrationSyN.sh into a shared cache prefix concurrently they could
# corrupt the half-written transform. We instead compute it ONCE here, BEFORE the
# parallel fan-out, into a canonical shared dir and export SEG_SHARED_MNI_REG_PREFIX.
# Both paths then COPY (read-only) from that prefix into their own workspace, so
# the background jobs never write the same registration file.
#
# Args: <subject_t1>
# Echoes the shared transform prefix on success (also exported); returns 0 on
# success, 1 if the warp could not be produced (callers fall back to computing
# their own — still correct, just no longer shared).
# ---------------------------------------------------------------------------
_compute_shared_mni_to_subject_warp() {
    local subject_t1="$1"

    local shared_dir="${RESULTS_DIR}/segmentation/shared_mni_registration"
    local prefix="${shared_dir}/mni_to_subject_"
    local affine="${prefix}0GenericAffine.mat"
    local warp="${prefix}1Warp.nii.gz"

    # Cached / resumable: reuse an existing shared warp.
    if [ -f "$affine" ] && [ -f "$warp" ]; then
        export SEG_SHARED_MNI_REG_PREFIX="$prefix"
        log_message "Shared MNI->subject warp already present (cached): $prefix"
        echo "$prefix"
        return 0
    fi

    local tres="${TEMPLATE_RES:-${DEFAULT_TEMPLATE_RES:-1mm}}"
    local mni_template="${FSLDIR}/data/standard/MNI152_T1_${tres}_brain.nii.gz"
    [ -f "$mni_template" ] || mni_template="${FSLDIR}/data/standard/MNI152_T1_${tres}.nii.gz"
    if [ ! -f "$mni_template" ]; then
        log_formatted "WARNING" "MNI template not found ($tres) — cannot pre-compute shared warp; paths will register independently"
        return 1
    fi

    mkdir -p "$shared_dir"
    log_formatted "INFO" "Pre-computing shared MNI->subject SyN warp (computed ONCE, reused by HO + multi-atlas paths)"
    log_message "  Template: $mni_template"
    antsRegistrationSyN.sh -d 3 -f "$subject_t1" -m "$mni_template" \
        -o "$prefix" -t s -j 1 -n "${ANTS_THREADS:-1}" >/dev/null 2>&1

    if [ ! -f "$affine" ] || [ ! -f "$warp" ]; then
        log_formatted "WARNING" "Shared MNI->subject registration failed; paths will register independently"
        return 1
    fi

    export SEG_SHARED_MNI_REG_PREFIX="$prefix"
    log_formatted "SUCCESS" "Shared MNI->subject warp computed: $prefix"
    echo "$prefix"
    return 0
}

# Comprehensive segmentation with multiple methods (from original)
#
# Default method 'all' runs every ENABLED path (Harvard-Oxford gross extent,
# multi-atlas warp, FreeSurfer substructures) as CONCURRENT PARALLEL paths. The
# single-method values (freesurfer / multi_atlas / bianciardi / atlas /
# harvard_oxford) remain mutually exclusive and behave exactly as before.
extract_brainstem_final() {
    local input_file="$1"
    local input_basename=$(basename "$input_file" .nii.gz)
    local seg_method="${BRAINSTEM_SEGMENTATION_METHOD:-all}"

    log_formatted "INFO" "===== COMPREHENSIVE BRAINSTEM SEGMENTATION ====="
    log_message "Brainstem segmentation method: $seg_method"

    # Define output directory
    local brainstem_dir="${RESULTS_DIR}/segmentation/brainstem"
    mkdir -p "$brainstem_dir"

    if [ "$seg_method" = "all" ]; then
        _extract_brainstem_all_parallel "$input_file" "$input_basename" "$brainstem_dir"
    else
        _extract_brainstem_single_method "$input_file" "$input_basename" "$brainstem_dir" "$seg_method"
    fi

    # Validate segmentation
    validate_segmentation_outputs "$input_file" "$input_basename"

    # Generate comprehensive visualization report
    generate_comprehensive_report "$input_file" "$input_basename"

    log_formatted "SUCCESS" "Comprehensive segmentation complete"
    return 0
}

# ---------------------------------------------------------------------------
# _extract_brainstem_single_method - legacy mutually-exclusive dispatch
#
# Preserves the historical behaviour for the exclusive method values. Always
# produces the Harvard-Oxford gross extent first (the fallback mask + the
# FS<->HO agreement reference), then layers on the requested substructure source.
# ---------------------------------------------------------------------------
_extract_brainstem_single_method() {
    local input_file="$1"
    local input_basename="$2"
    local brainstem_dir="$3"
    local seg_method="$4"

    # Always produce the Harvard-Oxford gross brainstem extent. It is the
    # fallback mask AND the reference for the FS-HO agreement QC gate.
    if extract_brainstem "$input_file" "$input_basename"; then
        log_formatted "SUCCESS" "Harvard-Oxford gross brainstem extraction successful"
    else
        log_formatted "ERROR" "Harvard-Oxford gross brainstem extraction failed"
        return 1
    fi

    # Map files to expected names
    map_segmentation_files "$input_basename" "$brainstem_dir"

    # Brainstem substructures: FreeSurfer parcels when requested + available;
    # otherwise the gross HO mask stands alone (subdivisions absent).
    if [ "$seg_method" = "freesurfer" ]; then
        local output_prefix="${brainstem_dir}/${input_basename}"
        local ho_brainstem_mask="${output_prefix}_brainstem.nii.gz"

        if extract_brainstem_freesurfer "$input_file" "$output_prefix" "$ho_brainstem_mask"; then
            log_formatted "SUCCESS" "FreeSurfer brainstem substructures produced (pons/midbrain/medulla/scp)"
        else
            log_formatted "WARNING" "FreeSurfer brainstem substructures unavailable or low-confidence; using Harvard-Oxford gross mask only (no subdivisions, low spatial granularity)"
        fi
    elif [ "$seg_method" = "multi_atlas" ] || [ "$seg_method" = "bianciardi" ]; then
        # Multi-atlas nucleus-level labeling (Bianciardi + CIT168 + optional AAL3)
        # layered on top of the Harvard-Oxford gross extent produced above. Per-
        # atlas enables live in config (USE_BIANCIARDI / USE_CIT168 / USE_AAL3).
        # Degrades gracefully when atlases or external tools are unavailable.
        if run_multi_atlas_brainstem "$input_file" "$input_basename"; then
            log_formatted "SUCCESS" "Multi-atlas brainstem labeling produced per-region masks"
        else
            log_formatted "WARNING" "Multi-atlas brainstem labeling unavailable; using Harvard-Oxford gross mask only"
        fi
    elif [ "$seg_method" = "atlas" ] || [ "$seg_method" = "harvard_oxford" ]; then
        log_message "Atlas method selected: Harvard-Oxford gross mask only (no FreeSurfer substructures)"
    else
        log_formatted "WARNING" "Unknown BRAINSTEM_SEGMENTATION_METHOD='$seg_method'; defaulting to Harvard-Oxford gross mask only"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# _extract_brainstem_all_parallel - run all ENABLED paths as concurrent parallel
# paths (the new default 'all' mode).
#
# Paths (each gated by a SEG_RUN_* toggle, all default on):
#   - Harvard-Oxford gross extent (extract_brainstem)         — fast
#   - Multi-atlas warp (run_multi_atlas_brainstem)            — minutes, no recon
#   - FreeSurfer substructures (extract_brainstem_freesurfer) — MULTI-HOUR recon
#
# Concurrency design:
#   * The shared MNI->subject SyN warp is computed ONCE up front and reused by
#     both the HO and multi-atlas paths (no race on the cached transform).
#   * Each path runs in a BACKGROUND SUBSHELL writing to a per-path log; its exit
#     code is collected with `wait <pid>`. A failing background job is NON-FATAL:
#     it logs a WARNING and never aborts the parent or the other paths (the
#     parent never runs `wait` under a propagating errexit on the job's status).
#   * Heavy ANTs/recon thread counts are capped so concurrent paths don't
#     oversubscribe the CPU (ANTS_THREADS split across the heavy paths, honouring
#     MAX_CPU_INTENSIVE_JOBS).
#   * Final outputs are non-clobbering: HO -> segmentation/brainstem/<base>_*,
#     FS parcels -> segmentation/detailed_brainstem/<base>_{pons,midbrain,...},
#     multi-atlas masks -> segmentation/detailed_brainstem/{bianciardi,cit168}_*.
# ---------------------------------------------------------------------------
_extract_brainstem_all_parallel() {
    local input_file="$1"
    local input_basename="$2"
    local brainstem_dir="$3"

    local run_ho="${SEG_RUN_HARVARD_OXFORD:-true}"
    local run_ma="${SEG_RUN_MULTI_ATLAS:-true}"
    local run_fs="${SEG_RUN_FREESURFER:-true}"

    log_formatted "INFO" "=== PARALLEL BRAINSTEM SEGMENTATION (method=all) ==="
    log_message "Enabled paths: harvard_oxford=$run_ho  multi_atlas=$run_ma  freesurfer=$run_fs"

    # Compute the shared MNI->subject warp ONCE (before fan-out) so the HO and
    # multi-atlas paths reuse the same transform instead of racing on it.
    if [ "$run_ho" = "true" ] || [ "$run_ma" = "true" ]; then
        _compute_shared_mni_to_subject_warp "$input_file" >/dev/null || \
            log_formatted "WARNING" "Shared warp unavailable; HO/multi-atlas will each register independently (still correct, just slower)"
    fi

    # Cap heavy thread counts so concurrently-running ANTs/recon paths don't
    # oversubscribe. Count the heavy paths (HO + multi-atlas both run ANTs warps;
    # FreeSurfer runs recon-all) and divide the ANTS_THREADS budget across them.
    local heavy_paths=0
    [ "$run_ho" = "true" ] && heavy_paths=$((heavy_paths + 1))
    [ "$run_ma" = "true" ] && heavy_paths=$((heavy_paths + 1))
    [ "$run_fs" = "true" ] && heavy_paths=$((heavy_paths + 1))
    [ "$heavy_paths" -lt 1 ] && heavy_paths=1

    local total_threads="${ANTS_THREADS:-4}"
    [[ "$total_threads" =~ ^[0-9]+$ ]] || total_threads=4
    local per_path_threads=$(( total_threads / heavy_paths ))
    [ "$per_path_threads" -lt 1 ] && per_path_threads=1
    # Respect an explicit MAX_CPU_INTENSIVE_JOBS thread cap when set (>0).
    local max_cpu="${MAX_CPU_INTENSIVE_JOBS:-0}"
    if [[ "$max_cpu" =~ ^[0-9]+$ ]] && [ "$max_cpu" -gt 0 ] && [ "$per_path_threads" -gt "$max_cpu" ]; then
        per_path_threads="$max_cpu"
    fi
    log_message "Per-path ANTs/recon thread cap: $per_path_threads (of $total_threads across $heavy_paths heavy path(s))"

    local log_dir="${RESULTS_DIR}/logs/segmentation_parallel"
    mkdir -p "$log_dir"

    local output_prefix="${brainstem_dir}/${input_basename}"
    local ho_brainstem_mask="${output_prefix}_brainstem.nii.gz"

    # ── Launch background paths ─────────────────────────────────────────────
    local ho_pid="" ma_pid="" fs_pid=""

    if [ "$run_ho" = "true" ]; then
        (
            export ANTS_THREADS="$per_path_threads"
            log_formatted "INFO" "[parallel] Harvard-Oxford gross extent path starting"
            if extract_brainstem "$input_file" "$input_basename"; then
                map_segmentation_files "$input_basename" "$brainstem_dir"
                log_formatted "SUCCESS" "[parallel] Harvard-Oxford gross extent path complete"
            else
                log_formatted "WARNING" "[parallel] Harvard-Oxford gross extent path FAILED (non-fatal)"
                exit 1
            fi
        ) >"${log_dir}/harvard_oxford.log" 2>&1 &
        ho_pid=$!
        log_message "  HO path PID=$ho_pid (log: ${log_dir}/harvard_oxford.log)"
    else
        log_message "  HO path disabled (SEG_RUN_HARVARD_OXFORD=false)"
    fi

    if [ "$run_ma" = "true" ]; then
        (
            export ANTS_THREADS="$per_path_threads"
            log_formatted "INFO" "[parallel] Multi-atlas path starting"
            if run_multi_atlas_brainstem "$input_file" "$input_basename"; then
                log_formatted "SUCCESS" "[parallel] Multi-atlas path complete"
            else
                log_formatted "WARNING" "[parallel] Multi-atlas path FAILED (non-fatal)"
                exit 1
            fi
        ) >"${log_dir}/multi_atlas.log" 2>&1 &
        ma_pid=$!
        log_message "  Multi-atlas path PID=$ma_pid (log: ${log_dir}/multi_atlas.log)"
    else
        log_message "  Multi-atlas path disabled (SEG_RUN_MULTI_ATLAS=false)"
    fi

    if [ "$run_fs" = "true" ]; then
        (
            export ANTS_THREADS="$per_path_threads"
            log_formatted "INFO" "[parallel] FreeSurfer substructure path starting (recon-all may run for HOURS)"
            # Pass the HO mask path for the FS<->HO agreement gate. The gate is
            # skipped gracefully if the HO mask is not present when it runs (the
            # FS path is the long pole, so HO normally finishes well before).
            if extract_brainstem_freesurfer "$input_file" "$output_prefix" "$ho_brainstem_mask"; then
                log_formatted "SUCCESS" "[parallel] FreeSurfer substructure path complete"
            else
                log_formatted "WARNING" "[parallel] FreeSurfer substructure path unavailable/low-confidence (non-fatal)"
                exit 1
            fi
        ) >"${log_dir}/freesurfer.log" 2>&1 &
        fs_pid=$!
        log_message "  FreeSurfer path PID=$fs_pid (log: ${log_dir}/freesurfer.log)"
    else
        log_message "  FreeSurfer path disabled (SEG_RUN_FREESURFER=false) — skipping multi-hour recon-all"
    fi

    # ── Collect each path independently (failure is non-fatal) ──────────────
    # `wait <pid>` returns the job's exit status; we capture it without letting a
    # non-zero status abort the parent under set -e.
    SEG_ALL_PATHS_RAN=()
    SEG_ALL_PATHS_OK=()

    if [ -n "$ho_pid" ]; then
        local ho_rc=0; wait "$ho_pid" || ho_rc=$?
        cat "${log_dir}/harvard_oxford.log" 2>/dev/null || true
        SEG_ALL_PATHS_RAN+=("harvard_oxford")
        if [ "$ho_rc" -eq 0 ]; then
            SEG_ALL_PATHS_OK+=("harvard_oxford")
            log_formatted "SUCCESS" "Harvard-Oxford path: OK"
        else
            log_formatted "WARNING" "Harvard-Oxford path: FAILED (rc=$ho_rc) — non-fatal"
        fi
    fi

    if [ -n "$ma_pid" ]; then
        local ma_rc=0; wait "$ma_pid" || ma_rc=$?
        cat "${log_dir}/multi_atlas.log" 2>/dev/null || true
        SEG_ALL_PATHS_RAN+=("multi_atlas")
        if [ "$ma_rc" -eq 0 ]; then
            SEG_ALL_PATHS_OK+=("multi_atlas")
            log_formatted "SUCCESS" "Multi-atlas path: OK"
        else
            log_formatted "WARNING" "Multi-atlas path: FAILED (rc=$ma_rc) — non-fatal"
        fi
    fi

    if [ -n "$fs_pid" ]; then
        local fs_rc=0; wait "$fs_pid" || fs_rc=$?
        cat "${log_dir}/freesurfer.log" 2>/dev/null || true
        SEG_ALL_PATHS_RAN+=("freesurfer")
        if [ "$fs_rc" -eq 0 ]; then
            SEG_ALL_PATHS_OK+=("freesurfer")
            log_formatted "SUCCESS" "FreeSurfer path: OK"
        else
            log_formatted "WARNING" "FreeSurfer path: unavailable/low-confidence (rc=$fs_rc) — non-fatal"
        fi
    fi

    # NOTE: bash cannot export arrays; SEG_ALL_PATHS_RAN/OK remain plain shell
    # variables in this process. _seg_method_report_line (called in-process via
    # command substitution by the report generators) reads them via declare -p,
    # so no export is needed or possible.
    log_formatted "INFO" "Parallel segmentation paths ran: ${SEG_ALL_PATHS_RAN[*]:-none}; succeeded: ${SEG_ALL_PATHS_OK[*]:-none}"

    # The canonical gross brainstem mask (segmentation/brainstem/<base>_brainstem.nii.gz)
    # is a HARD pipeline requirement: pipeline.sh aborts the segmentation stage if
    # it is missing. Only the Harvard-Oxford path writes it. When the HO path is
    # disabled (SEG_RUN_HARVARD_OXFORD=false) or failed, but a substructure path
    # (FreeSurfer / multi-atlas) succeeded, SYNTHESISE the gross mask from the
    # union of the produced substructure masks so the contract holds and downstream
    # gets a real fallback extent — rather than silently aborting the whole run.
    if [ ! -f "$ho_brainstem_mask" ]; then
        log_formatted "WARNING" "Harvard-Oxford gross brainstem mask absent; synthesising it from the union of the substructure masks that succeeded"
        if _synthesize_gross_brainstem_from_substructures "$input_basename" "$ho_brainstem_mask"; then
            log_formatted "SUCCESS" "Synthesised gross brainstem mask from substructure union: $ho_brainstem_mask"
        else
            log_formatted "WARNING" "Could not synthesise a gross brainstem mask (no substructure masks available)"
        fi
    fi

    # Non-fatal overall: as long as SOMETHING ran, downstream find_all_atlas_regions
    # discovers the union of whatever masks the successful paths produced.
    if [ ${#SEG_ALL_PATHS_OK[@]} -eq 0 ]; then
        log_formatted "ERROR" "All parallel segmentation paths failed"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _synthesize_gross_brainstem_from_substructures - build the canonical gross
# brainstem mask + hemisphere splits from the union of substructure masks.
#
# Used in 'all' mode when the Harvard-Oxford path did not produce
# segmentation/brainstem/<base>_brainstem.nii.gz (HO disabled or failed) but a
# substructure path (FreeSurfer parcels and/or multi-atlas aggregated
# subdivisions) did. The union of those subdivision masks is a valid gross
# brainstem extent, so it satisfies the pipeline's mandatory-output contract and
# serves as the analysis fallback. Returns 0 on success (mask written), 1 if no
# substructure masks were available to union.
#
# Args: <input_basename> <out_brainstem_mask>
# ---------------------------------------------------------------------------
_synthesize_gross_brainstem_from_substructures() {
    local input_basename="$1"
    local out_mask="$2"

    local detailed_dir="${RESULTS_DIR}/segmentation/detailed_brainstem"
    [ -d "$detailed_dir" ] || return 1

    mkdir -p "$(dirname "$out_mask")"

    # Union the gross subdivision masks (FreeSurfer parcels + multi-atlas
    # aggregated subdivisions) — NOT the tiny individual nuclei — so the result
    # is a coherent gross extent. Match the *_pons/*_midbrain/*_medulla/*_scp
    # families (with optional left/right) from any source.
    local first=1 f
    local tmp_union; tmp_union=$(mktemp -d)/union.nii.gz
    shopt -s nullglob
    for f in \
        "$detailed_dir"/*_midbrain.nii.gz "$detailed_dir"/*_pons.nii.gz \
        "$detailed_dir"/*_medulla.nii.gz "$detailed_dir"/*_scp.nii.gz \
        "$detailed_dir"/*left_midbrain*.nii.gz "$detailed_dir"/*right_midbrain*.nii.gz \
        "$detailed_dir"/*left_pons*.nii.gz "$detailed_dir"/*right_pons*.nii.gz \
        "$detailed_dir"/*left_medulla*.nii.gz "$detailed_dir"/*right_medulla*.nii.gz \
        "$detailed_dir"/*left_scp*.nii.gz "$detailed_dir"/*right_scp*.nii.gz; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in *_intensity*|*_flair_*) continue ;; esac
        if [ "$first" -eq 1 ]; then
            safe_fslmaths "synth gross init" "$f" -bin "$tmp_union" >/dev/null 2>&1 || continue
            first=0
        else
            safe_fslmaths "synth gross add" "$tmp_union" -max "$f" -bin "$tmp_union" >/dev/null 2>&1 || true
        fi
    done
    shopt -u nullglob

    if [ "$first" -eq 1 ] || [ ! -f "$tmp_union" ]; then
        rm -rf "$(dirname "$tmp_union")"
        return 1
    fi

    cp -f "$tmp_union" "$out_mask"
    rm -rf "$(dirname "$tmp_union")"

    # Produce the hemisphere splits the report/QC reference, mirroring
    # generate_hemisphere_masks (hierarchical_joint_fusion.sh).
    local output_prefix="${out_mask%_brainstem.nii.gz}"
    if declare -f generate_hemisphere_masks >/dev/null 2>&1; then
        generate_hemisphere_masks "$out_mask" "$output_prefix" >/dev/null 2>&1 || true
    fi
    return 0
}

# File mapping functionality (from original)
map_segmentation_files() {
    local input_basename="$1"
    local brainstem_dir="$2"
    
    log_message "Mapping segmentation files to expected names..."
    
    # Remove any method suffixes from files
    for file in "${brainstem_dir}"/*_brainstem*.nii.gz; do
        if [ -f "$file" ]; then
            local basename=$(basename "$file")
            # Remove suffixes like _harvard, _juelich, _t1based, etc.
            local clean_name=$(echo "$basename" | sed -E 's/_(harvard|t1based|enhanced|talairach)//g')
            if [ "$basename" != "$clean_name" ]; then
                log_message "Renaming $basename to $clean_name"
                cp "$file" "${brainstem_dir}/${clean_name}"
            fi
        fi
    done
    
    return 0
}

# Validation functionality (from original)
validate_segmentation_outputs() {
    local input_file="$1"
    local basename="$2"
    
    log_message "Validating segmentation outputs..."
    
    local brainstem_file="${RESULTS_DIR}/segmentation/brainstem/${basename}_brainstem.nii.gz"
    local validation_passed=true
    
    # Check brainstem
    if [ -f "$brainstem_file" ]; then
        local brainstem_voxels=$(fslstats "$brainstem_file" -V | awk '{print $1}')
        log_message "Brainstem: $brainstem_voxels voxels"
        if [ "$brainstem_voxels" -lt 100 ]; then
            log_formatted "WARNING" "Brainstem segmentation may be too small"
            validation_passed=false
        fi
    else
        log_formatted "ERROR" "Brainstem segmentation file not found: $brainstem_file"
        validation_passed=false
    fi
    
    # Create validation report
    local validation_dir="${RESULTS_DIR}/validation/segmentation"
    mkdir -p "$validation_dir"
    {
        echo "Segmentation Validation Report"
        echo "=============================="
        echo "Date: $(date)"
        echo "Input: $input_file"
        echo "Files created:"
        ls -la "${RESULTS_DIR}/segmentation/brainstem/${basename}"*.nii.gz 2>/dev/null || echo "No brainstem files"
        echo "Validation: $([ "$validation_passed" = "true" ] && echo "PASSED" || echo "WARNINGS")"
    } > "${validation_dir}/segmentation_validation.txt"
    
    return 0
}

# Combined segmentation map creation (from original)
create_combined_segmentation_map() {
    local input_basename="$1"
    local brainstem_dir="$2"
    
    log_message "Creating combined segmentation label map..."
    
    local combined_dir="${RESULTS_DIR}/segmentation/combined"
    mkdir -p "$combined_dir"
    
    # Define label values
    local BRAINSTEM_LABEL=1
    
    # Get reference file for dimensions
    local ref_file="${brainstem_dir}/${input_basename}_brainstem_mask.nii.gz"
    if [ ! -f "$ref_file" ]; then
        log_formatted "WARNING" "Reference file not found for combined map"
        return 1
    fi
    
    # Start with empty map
    local combined_map="${combined_dir}/${input_basename}_segmentation_labels.nii.gz"
    fslmaths "$ref_file" -mul 0 "$combined_map"
    
    # Add brainstem (label 1)
    local brainstem_mask="${brainstem_dir}/${input_basename}_brainstem_mask.nii.gz"
    if [ -f "$brainstem_mask" ]; then
        fslmaths "$brainstem_mask" -mul $BRAINSTEM_LABEL -add "$combined_map" "$combined_map"
        log_message "Added brainstem to combined map (label=$BRAINSTEM_LABEL)"
    fi
    
    # Create label description file
    {
        echo "# Brainstem Segmentation Label Map"
        echo "# Label values:"
        echo "0 = Background"
        echo "1 = Brainstem (Hierarchical Joint Fusion)"
    } > "${combined_dir}/${input_basename}_segmentation_labels.txt"
    
    log_message "Combined segmentation map created: $combined_map"
    return 0
}

# Comprehensive report generation (from original)
generate_comprehensive_report() {
    local input_file="$1"
    local input_basename="$2"
    local report_dir="${RESULTS_DIR}/reports"
    
    log_message "Generating comprehensive segmentation report..."
    mkdir -p "$report_dir"
    
    local report_file="${report_dir}/segmentation_report_${input_basename}.txt"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Gather file information
    local t1_file="${RESULTS_DIR}/standardized/$(basename "$input_file")"
    local brainstem_intensity="${RESULTS_DIR}/segmentation/brainstem/${input_basename}_brainstem.nii.gz"
    local brainstem_mask="${RESULTS_DIR}/segmentation/brainstem/${input_basename}_brainstem_mask.nii.gz"
    
    # Calculate statistics
    local brainstem_voxels=0
    if [ -f "$brainstem_mask" ]; then
        brainstem_voxels=$(fslstats "$brainstem_mask" -V | awk '{print $1}')
    fi
    
    # Generate report
    cat > "$report_file" <<EOF
================================================================================
                        BRAINSTEM SEGMENTATION REPORT
================================================================================
Generated: $timestamp
Subject: $input_basename

SEGMENTATION SUMMARY
-------------------
Method: $(_seg_method_report_line) (gross extent: Harvard-Oxford; substructures: FreeSurfer brainstemSsLabels and/or multi-atlas nuclei)
Space: T1 Native Space
Brainstem voxels: $brainstem_voxels

FILES GENERATED
--------------
1. Binary Masks (for ROI analysis):
   - Brainstem mask: ${brainstem_mask}

2. Intensity Maps (T1 values within masks):
   - Brainstem intensities: ${brainstem_intensity}

VISUALIZATION INSTRUCTIONS
-------------------------
To visualize the segmentations overlaid on your images:

1. View segmentations on T1:
   fsleyes ${t1_file} \\
           ${brainstem_mask} -cm red -a 50

2. View with intensity overlay:
   fsleyes ${t1_file} \\
           ${brainstem_intensity} -cm hot -a 70

================================================================================
EOF

    log_formatted "SUCCESS" "Comprehensive segmentation report generated: $report_file"
    return 0
}

# Tissue segmentation (from original)
segment_tissues() {
    local input_file="$1"
    local output_dir="${2:-${RESULTS_DIR}/segmentation/tissue}"
    
    if [ ! -f "$input_file" ]; then
        log_formatted "ERROR" "Input file $1 does not exist"
        return 1
    fi
    
    mkdir -p "$output_dir"
    log_message "Performing tissue segmentation on $input_file"
    
    local basename=$(basename "$input_file" .nii.gz)
    
    # Try to find existing brain extraction files
    local brain_mask="${RESULTS_DIR}/brain_extraction/${basename}_brain_mask.nii.gz"
    local brain_file="${RESULTS_DIR}/brain_extraction/${basename}_brain.nii.gz"
    
    if [ ! -f "$brain_mask" ] || [ ! -f "$brain_file" ]; then
        log_message "Searching for available brain extraction files..."
        local available_brain_files=($(find "${RESULTS_DIR}/brain_extraction" -name "*_brain.nii.gz" 2>/dev/null))
        local available_mask_files=($(find "${RESULTS_DIR}/brain_extraction" -name "*_brain_mask.nii.gz" 2>/dev/null))
        
        if [ ${#available_brain_files[@]} -gt 0 ] && [ ${#available_mask_files[@]} -gt 0 ]; then
            brain_file="${available_brain_files[0]}"
            brain_mask="${available_mask_files[0]}"
            log_message "Using available brain extraction files"
        else
            log_formatted "ERROR" "Brain extraction files not found"
            return 1
        fi
    fi
    
    # Use FAST for tissue segmentation
    log_message "Running FAST segmentation..."
    fast -t 1 -n 3 -o "${output_dir}/${basename}_" "$brain_file"
    
    log_message "Tissue segmentation complete"
    return 0
}

# Legacy function wrappers for backward compatibility
extract_brainstem_harvard_oxford() {
    log_formatted "INFO" "Using Harvard-Oxford gross brainstem extraction"
    extract_brainstem "$@"
}

extract_brainstem_talairach() {
    log_formatted "WARNING" "extract_brainstem_talairach is deprecated (Talairach removed). Using Harvard-Oxford gross extraction; substructures come from FreeSurfer."
    extract_brainstem "$@"
}

# Legacy compatibility functions
extract_brainstem_standardspace() {
    log_formatted "WARNING" "extract_brainstem_standardspace is deprecated. Using hierarchical joint fusion."
    extract_brainstem "$@"
}

extract_brainstem_ants() {
    log_formatted "WARNING" "extract_brainstem_ants is deprecated. Using hierarchical joint fusion."
    extract_brainstem "$@"
}

# Simple validation function that doesn't block pipeline
validate_segmentation() {
    log_message "Running segmentation validation..."
    return 0
}

# File discovery and mapping
discover_and_map_segmentation_files() {
    local input_basename="$1"
    local brainstem_dir="$2"
    
    map_segmentation_files "$input_basename" "$brainstem_dir"
    return 0
}

# Main segmentation entry point called by pipeline
segment_brainstem() {
    local input_file="$1"
    local input_basename="$2"
    local flair_file="${3:-}"
    
    log_formatted "INFO" "=== BRAINSTEM SEGMENTATION MODULE ==="
    
    # Execute comprehensive brainstem segmentation
    extract_brainstem "$input_file" "$input_basename" "$flair_file"
}

# Export functions for use by other modules
export -f extract_brainstem
export -f enhance_segmentation_with_flair
export -f generate_segmentation_report
export -f extract_brainstem_with_flair
export -f extract_brainstem_final
export -f _extract_brainstem_single_method
export -f _extract_brainstem_all_parallel
export -f _synthesize_gross_brainstem_from_substructures
export -f _compute_shared_mni_to_subject_warp
export -f _seg_method_report_line
export -f map_segmentation_files
export -f validate_segmentation_outputs
export -f create_combined_segmentation_map
export -f generate_comprehensive_report
export -f segment_tissues

# Legacy exports for compatibility
export -f extract_brainstem_harvard_oxford
export -f extract_brainstem_talairach
export -f extract_brainstem_standardspace
export -f extract_brainstem_ants
export -f validate_segmentation
export -f discover_and_map_segmentation_files
export -f segment_brainstem

log_message "Segmentation module loaded (parallel paths: Harvard-Oxford + multi-atlas + FreeSurfer; default method=all)"
