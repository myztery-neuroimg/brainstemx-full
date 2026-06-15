#!/usr/bin/env bash
#
# reporting.sh - the aggregation / reporting layer over all merged capabilities.
#
# This is the FINAL pipeline stage. It discovers every artefact a run produced
# (wherever it landed) and aggregates it into:
#
#   * Summary tables (CSV/TSV + HTML) under  reports/tables/
#       - hyperintensity per region x source (per-region GMM + provenance)
#       - WMH-tool volumes (one row per enabled tool)
#       - segmentation / subregion volumes (HO gross / FS substructures /
#         multi-atlas nuclei / SynthSeg-aseg / thalamic-hypothalamic)
#       - cross-modal per-cluster corroboration table
#       - FreeSurfer morphometry (aseg volumes + eTIV)
#       - a run manifest (which paths / tools / modalities actually ran)
#   * A single top-level report:  reports/brainstemx_report.html (+ .md fallback)
#
# Heavy lifting (parsing + table/HTML rendering) is in the stdlib-only Python
# helper reporting_tables.py (run via uv). This bash layer owns ONLY the parts
# that need FSL: discovering masks and computing their volumes with fslstats,
# written to TSV sidecars the Python helper consumes.
#
# GRACEFUL: every section is gated on the existence of its inputs. A minimal
# T1+FLAIR run still produces a valid (smaller) report; absent sections are
# skipped cleanly. IDEMPOTENT: re-running overwrites the same outputs.
#
# Conventions: log_* / ERR_* from environment.sh, safe_fslmaths/fslstats, config
# toggles in config/default_config.sh (REPORTING_* block).

# Lightweight include guard.
if [ -n "${_REPORTING_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_REPORTING_LOADED=1

# Lightweight environment guard (fast no-op when the pipeline already loaded it).
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# ---------------------------------------------------------------------------
# _reporting_python
#   Echo a python launcher (prefer uv, then fslpython, then python3). The
#   reporting helper is stdlib-only, so any of these works. Returns non-zero
#   only if none is usable.
# ---------------------------------------------------------------------------
_reporting_python() {
    if command -v uv >/dev/null 2>&1 && uv run python -c "import sys" >/dev/null 2>&1; then
        echo "uv run python"
        return 0
    fi
    if [ -n "${FSLDIR:-}" ] && [ -x "${FSLDIR}/bin/fslpython" ]; then
        echo "${FSLDIR}/bin/fslpython"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        echo "python3"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# _reporting_mask_volume <mask.nii.gz>
#   Echo "<n_voxels>\t<volume_mm3>" for a (possibly labelled) mask. fslstats -V
#   counts non-zero voxels regardless of label value, so no binarisation copy is
#   needed. For a 4D input fslstats -V emits one nvox/vol pair PER timepoint on a
#   single line; we sum all the pairs (every even/odd field) so a 4D label stack
#   is counted in full rather than only its first volume. Echoes nothing on
#   failure (caller skips the row).
# ---------------------------------------------------------------------------
_reporting_mask_volume() {
    local mask="$1"
    [ -n "$mask" ] && [ -f "$mask" ] || { echo ""; return 1; }
    local stats
    stats=$(fslstats "$mask" -V 2>/dev/null) || { echo ""; return 1; }
    # Sum nvox (odd fields) and vol (even fields); for the common 3D case this is
    # just field1/field2. Empty stats => no fields => empty output (caller skips).
    local summed
    summed=$(echo "$stats" | awk 'NF>=2 {n=0; v=0; for(i=1;i+1<=NF;i+=2){n+=$i; v+=$(i+1)} printf "%s\t%s", n, v}')
    [ -n "$summed" ] || { echo ""; return 1; }
    printf '%s\n' "$summed"
    return 0
}

# ---------------------------------------------------------------------------
# _reporting_same_grid <a.nii.gz> <b.nii.gz>
#   True (0) when both volumes share dim1/dim2/dim3 (so a voxelwise -mas is
#   valid). Conservative: any failure to read dims returns false.
# ---------------------------------------------------------------------------
_reporting_same_grid() {
    command -v fslval >/dev/null 2>&1 || return 1
    local a="$1" b="$2" d
    for d in dim1 dim2 dim3; do
        local av bv
        av=$(fslval "$a" "$d" 2>/dev/null | tr -d ' ')
        bv=$(fslval "$b" "$d" 2>/dev/null | tr -d ' ')
        [ -n "$av" ] && [ "$av" = "$bv" ] || return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# _reporting_source_for_mask <mask_path>
#   Classify a detailed_brainstem / segmentation mask by provenance source from
#   its filename, mirroring analysis.sh's _region_source_from_path tagging.
# ---------------------------------------------------------------------------
_reporting_source_for_mask() {
    local base
    base=$(basename "$1")
    case "$base" in
        bianciardi_*) echo "bianciardi" ;;
        cit168_*)     echo "cit168" ;;
        aal3_*)       echo "aal3" ;;
        synthseg_*)   echo "synthseg" ;;
        aseg_*)       echo "aseg" ;;
        *)            echo "freesurfer" ;;
    esac
}

# ---------------------------------------------------------------------------
# build_segmentation_volume_sidecar <results_dir> <out_tsv>
#   Discover every segmentation mask (HO gross, FS substructures, multi-atlas
#   nuclei, SynthSeg/aseg, thalamic/hypothalamic) and write a
#   region<TAB>source<TAB>volume_mm3<TAB>n_voxels sidecar for the Python helper.
#   GRACEFUL: writes a header-only file if nothing is found.
# ---------------------------------------------------------------------------
build_segmentation_volume_sidecar() {
    local results_dir="$1"
    local out_tsv="$2"

    printf 'region\tsource\tvolume_mm3\tn_voxels\n' > "$out_tsv"

    local seg_dir="${results_dir}/segmentation"
    local detailed="${seg_dir}/detailed_brainstem"
    local brainstem="${seg_dir}/brainstem"
    local count=0

    # --- HO gross brainstem (segmentation/brainstem) ----------------------
    local f
    if [ -d "$brainstem" ]; then
        for f in "$brainstem"/*_brainstem.nii.gz "$brainstem"/*_hemisphere.nii.gz; do
            [ -f "$f" ] || continue
            _reporting_emit_volume_row "$f" "harvard_oxford" "$out_tsv" && count=$((count + 1))
        done
    fi

    # --- detailed_brainstem (FS parcels + multi-atlas nuclei) -------------
    if [ -d "$detailed" ]; then
        for f in "$detailed"/*.nii.gz; do
            [ -f "$f" ] || continue
            case "$(basename "$f")" in
                *intensity*|*_zscore*|*_resampled*|*brainstemSsLabels*) continue ;;
            esac
            local src
            src=$(_reporting_source_for_mask "$f")
            _reporting_emit_volume_row "$f" "$src" "$out_tsv" && count=$((count + 1))
        done
    fi

    # --- SynthSeg / aseg label volumes + subregions (FreeSurfer harvest) --
    local harvest="${results_dir}/freesurfer/harvest"
    for f in \
        "${harvest}/synthseg/synthseg_seg.nii.gz" \
        "${harvest}/subregions/thalamus_labels.nii.gz" \
        "${harvest}/subregions/hypothalamus_labels.nii.gz" \
        "${harvest}/subregions/hippo_amygdala_lh_labels.nii.gz" \
        "${harvest}/subregions/hippo_amygdala_rh_labels.nii.gz"; do
        [ -f "$f" ] || continue
        local src="freesurfer"
        case "$(basename "$f")" in synthseg_*) src="synthseg" ;; esac
        _reporting_emit_volume_row "$f" "$src" "$out_tsv" && count=$((count + 1))
    done

    log_message "Reporting: segmentation volume sidecar rows=$count -> $out_tsv"
    return 0
}

# Helper: append one "region<TAB>source<TAB>vol<TAB>nvox" row. Region name is the
# mask basename with source prefix and .nii.gz stripped for readability.
_reporting_emit_volume_row() {
    local mask="$1" source="$2" out_tsv="$3"
    local vol_line
    vol_line=$(_reporting_mask_volume "$mask") || return 1
    [ -n "$vol_line" ] || return 1
    local nvox vol region
    nvox=$(printf '%s' "$vol_line" | cut -f1)
    vol=$(printf '%s' "$vol_line" | cut -f2)
    region=$(basename "$mask" .nii.gz)
    # Strip a leading atlas/source prefix so the region column is anatomy-focused.
    region="${region#bianciardi_}"
    region="${region#cit168_}"
    region="${region#aal3_}"
    region="${region#synthseg_}"
    region="${region#aseg_}"
    printf '%s\t%s\t%s\t%s\n' "$region" "$source" "$vol" "$nvox" >> "$out_tsv"
    return 0
}

# ---------------------------------------------------------------------------
# build_per_region_stats_sidecar <results_dir>
#   For each analysed per-region GMM output (out_prefix_<tag>_GMM.nii.gz) compute
#   volume + cluster count and write per_region_analysis/region_stats.tsv keyed
#   by region_tag (matching region_provenance.tsv). GRACEFUL no-op if the
#   per-region dir / provenance manifest is absent.
# ---------------------------------------------------------------------------
build_per_region_stats_sidecar() {
    local results_dir="$1"
    local prdir=""
    if [ -d "${results_dir}/per_region_analysis" ]; then
        prdir="${results_dir}/per_region_analysis"
    elif [ -d "${results_dir}/analysis/per_region" ]; then
        prdir="${results_dir}/analysis/per_region"
    else
        log_message "Reporting: per-region analysis dir absent - skipping region stats"
        return 0
    fi

    local prov="${prdir}/region_provenance.tsv"
    if [ ! -f "$prov" ]; then
        log_message "Reporting: region_provenance.tsv absent - skipping region stats"
        return 0
    fi

    local out_tsv="${prdir}/region_stats.tsv"
    printf 'region_tag\tvolume_mm3\tn_voxels\tcluster_count\tmean_z\tpeak_z\n' > "$out_tsv"

    # Per-region GMM masks are written next to the hyperintensities prefix as
    # <prefix>_<region_tag>_GMM.nii.gz. Discover them under the hyperintensities
    # dir; fall back to any *_GMM.nii.gz beneath the per-region work dirs.
    local hyper_dir="${results_dir}/hyperintensities"
    local rows=0 region_tag mask
    while IFS=$'\t' read -r region_tag _region_base _source _mask_path; do
        [ -n "$region_tag" ] || continue
        [ "$region_tag" = "region_tag" ] && continue   # skip header

        mask=""
        local work_dir="${prdir}/${region_tag}_FLAIR_analysis"
        # Preferred: the canonical per-region GMM output named by tag.
        if [ -d "$hyper_dir" ]; then
            mask=$(find "$hyper_dir" -maxdepth 1 -name "*_${region_tag}_GMM.nii.gz" 2>/dev/null | head -1 || true)
        fi
        # Fallback: the connectivity output kept inside the region work dir. Use a
        # grouped expression with explicit precedence (find ... \( A -o B \)) so
        # the GMM mask is preferred deterministically, not whatever find emits first.
        if [ -z "$mask" ] && [ -d "$work_dir" ]; then
            mask=$(find "$work_dir" \( -name "*_GMM.nii.gz" -o -name "*_connectivity.nii.gz" \) 2>/dev/null | sort | head -1 || true)
        fi
        [ -n "$mask" ] && [ -f "$mask" ] || continue

        local vol_line nvox vol clusters mean_z peak_z
        vol_line=$(_reporting_mask_volume "$mask") || continue
        [ -n "$vol_line" ] || continue
        nvox=$(printf '%s' "$vol_line" | cut -f1)
        vol=$(printf '%s' "$vol_line" | cut -f2)

        # Cluster count via FSL cluster (binarised); tolerate absence of tool.
        clusters=""
        if command -v cluster >/dev/null 2>&1; then
            clusters=$(cluster --in="$mask" --thresh=0.0001 --connectivity=26 --no_table 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || true)
        fi

        # mean/peak z of the DETECTION, sampled from the region z-score image
        # (the GMM mask is BINARY, so sampling it would always yield ~1). Mask the
        # zscore image by the detection then take -M (mean over >0) and -R (max).
        # Falls back to blank when the zscore image is unavailable.
        mean_z=""
        peak_z=""
        local zscore=""
        if [ -d "$work_dir" ]; then
            zscore=$(find "$work_dir" -maxdepth 1 -name "*_zscore.nii.gz" 2>/dev/null | head -1 || true)
        fi
        if [ -n "$zscore" ] && [ -f "$zscore" ] && _reporting_same_grid "$zscore" "$mask"; then
            local z_in_det="${work_dir}/.reporting_z_in_detection.nii.gz"
            if fslmaths "$zscore" -mas "$mask" "$z_in_det" >/dev/null 2>&1; then
                mean_z=$(fslstats "$z_in_det" -l 0.0000001 -M 2>/dev/null || echo "")
                peak_z=$(fslstats "$z_in_det" -R 2>/dev/null | awk '{print $2}' || echo "")
                rm -f "$z_in_det" 2>/dev/null
            fi
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$region_tag" "$vol" "$nvox" "${clusters:-}" "${mean_z:-}" "${peak_z:-}" >> "$out_tsv"
        rows=$((rows + 1))
    done < "$prov"

    log_message "Reporting: per-region stats sidecar rows=$rows -> $out_tsv"
    return 0
}

# ---------------------------------------------------------------------------
# backfill_wmh_summaries <results_dir>
#   Some WMH tools leave a lesion mask but NO key=value summary (BIANCA logs its
#   volumes to stdout only). For any such tool we synthesize a summary the Python
#   aggregator can read, so a tool that actually ran is never silently omitted
#   from the WMH table. GRACEFUL no-op when fslstats is unavailable or the tool
#   left no mask.
# ---------------------------------------------------------------------------
backfill_wmh_summaries() {
    local results_dir="$1"
    command -v fslstats >/dev/null 2>&1 || return 0
    local wmh_root="${results_dir}/analysis/wmh"
    [ -d "$wmh_root" ] || return 0

    # Each spec: tool_subdir : summary_filename : whole-brain mask glob :
    # brainstem mask glob. Only tools that leave a mask but NO summary need an
    # entry here (currently just BIANCA, which logs volumes to stdout only).
    local specs=(
        "bianca:bianca_wmh_summary.txt:bianca_wmh_thr*_bin.nii.gz:bianca_wmh_brainstem.nii.gz"
    )
    local spec
    for spec in "${specs[@]}"; do
        local subdir sumname wb_glob bs_glob
        IFS=':' read -r subdir sumname wb_glob bs_glob <<< "$spec"
        local dir="${wmh_root}/${subdir}"
        [ -d "$dir" ] || continue
        # Respect an existing summary (idempotent; don't clobber the tool's own).
        [ -f "${dir}/${sumname}" ] && continue

        local wb_mask
        wb_mask=$(find "$dir" -maxdepth 1 -name "$wb_glob" 2>/dev/null | head -1 || true)
        [ -n "$wb_mask" ] && [ -f "$wb_mask" ] || continue

        local wb_line wb_vol wb_clusters
        wb_line=$(_reporting_mask_volume "$wb_mask") || continue
        wb_vol=$(printf '%s' "$wb_line" | cut -f2)
        wb_clusters=""
        if command -v cluster >/dev/null 2>&1; then
            wb_clusters=$(cluster --in="$wb_mask" --thresh=0.5 --connectivity=26 --no_table 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || true)
        fi

        local bs_vol="" bs_clusters=""
        local bs_mask
        bs_mask=$(find "$dir" -maxdepth 1 -name "$bs_glob" 2>/dev/null | head -1 || true)
        if [ -n "$bs_mask" ] && [ -f "$bs_mask" ]; then
            local bs_line
            bs_line=$(_reporting_mask_volume "$bs_mask" || true)
            [ -n "$bs_line" ] && bs_vol=$(printf '%s' "$bs_line" | cut -f2)
            if command -v cluster >/dev/null 2>&1; then
                bs_clusters=$(cluster --in="$bs_mask" --thresh=0.5 --connectivity=26 --no_table 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || true)
            fi
        fi

        {
            printf 'tool=%s\n' "$subdir"
            printf 'note=summary synthesized by reporting.sh (tool wrote no summary)\n'
            printf 'lesion_mask=%s\n' "$wb_mask"
            printf 'whole_brain_wmh_mm3=%s\n' "$wb_vol"
            [ -n "$wb_clusters" ] && printf 'whole_brain_wmh_clusters=%s\n' "$wb_clusters"
            [ -n "$bs_vol" ] && printf 'brainstem_wmh_mm3=%s\n' "$bs_vol"
            [ -n "$bs_clusters" ] && printf 'brainstem_wmh_clusters=%s\n' "$bs_clusters"
        } > "${dir}/${sumname}"
        log_message "Reporting: synthesized WMH summary for '${subdir}' -> ${dir}/${sumname}"
    done
    return 0
}

# ---------------------------------------------------------------------------
# generate_summary_report <subject_id> <results_dir>
#   Top-level entry point for the reporting stage. Builds the volume sidecars,
#   then runs the Python aggregator to emit the tables + the top-level report.
#   GRACEFUL: missing inputs => smaller report; never aborts the pipeline.
# ---------------------------------------------------------------------------
generate_summary_report() {
    local subject_id="$1"
    local results_dir="$2"

    if [ "${REPORTING_ENABLED:-true}" != "true" ]; then
        log_message "Reporting disabled (REPORTING_ENABLED != true) - skipping"
        return 0
    fi

    log_formatted "INFO" "===== REPORTING: AGGREGATION + SUMMARY TABLES + REPORT ====="

    if [ -z "$results_dir" ] || [ ! -d "$results_dir" ]; then
        log_formatted "WARNING" "Reporting: results dir not found ($results_dir) - skipping"
        return 0
    fi

    local tables_dir="${results_dir}/reports/tables"
    mkdir -p "$tables_dir"

    # 1) Segmentation volume sidecar (needs FSL; owned by bash).
    local seg_sidecar="${tables_dir}/segmentation_volume_sidecar.tsv"
    if command -v fslstats >/dev/null 2>&1; then
        build_segmentation_volume_sidecar "$results_dir" "$seg_sidecar" || \
            log_formatted "WARNING" "Reporting: segmentation sidecar build reported a non-fatal failure"
        build_per_region_stats_sidecar "$results_dir" || \
            log_formatted "WARNING" "Reporting: per-region stats build reported a non-fatal failure"
        backfill_wmh_summaries "$results_dir" || \
            log_formatted "WARNING" "Reporting: WMH summary backfill reported a non-fatal failure"
    else
        log_formatted "WARNING" "Reporting: fslstats unavailable - volume columns will be blank"
        printf 'region\tsource\tvolume_mm3\tn_voxels\n' > "$seg_sidecar"
    fi

    # 2) Run the Python aggregator (stdlib only).
    local py
    if ! py="$(_reporting_python)"; then
        log_formatted "WARNING" "Reporting: no python available - skipping table aggregation (non-fatal)"
        return 0
    fi

    local script
    script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reporting_tables.py"
    if [ ! -f "$script" ]; then
        log_formatted "WARNING" "Reporting: aggregator script not found ($script) - skipping"
        return 0
    fi

    local report_html="${results_dir}/reports/brainstemx_report.html"
    local report_md="${results_dir}/reports/brainstemx_report.md"

    log_message "Reporting: aggregating tables + building report via: $py"
    local rep_status=0
    # shellcheck disable=SC2086
    $py "$script" \
        --results-dir "$results_dir" \
        --out-dir "$tables_dir" \
        --subject-id "$subject_id" \
        --seg-volumes "$seg_sidecar" \
        --cross-modal-subdir "${CROSS_MODAL_SUBDIR:-cross_modal}" \
        --report-html "$report_html" \
        --report-md "$report_md" \
        2>"${tables_dir}/reporting.log" || rep_status=$?

    # Surface the aggregator diagnostics into the pipeline log.
    if [ -f "${tables_dir}/reporting.log" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && log_message "Reporting: $line"
        done < "${tables_dir}/reporting.log"
    fi

    if [ "$rep_status" -ne 0 ]; then
        log_formatted "WARNING" "Reporting: aggregator exited non-zero (status $rep_status) - non-fatal"
        return 0
    fi

    [ -f "$report_html" ] && log_formatted "SUCCESS" "Top-level report: $report_html"
    [ -f "$report_md" ] && log_message "Markdown report: $report_md"
    log_message "Summary tables (CSV/TSV + HTML): $tables_dir"
    return 0
}

export -f _reporting_python
export -f _reporting_mask_volume
export -f _reporting_same_grid
export -f _reporting_source_for_mask
export -f _reporting_emit_volume_row
export -f build_segmentation_volume_sidecar
export -f build_per_region_stats_sidecar
export -f backfill_wmh_summaries
export -f generate_summary_report

log_message "Reporting module loaded (aggregation + summary tables + top-level report)"
