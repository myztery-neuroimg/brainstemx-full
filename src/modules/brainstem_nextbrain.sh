#!/usr/bin/env bash
#
# brainstem_nextbrain.sh - Brainstem nuclei from FreeSurfer's NextBrain
#                          histological-atlas segmentation
#                          (mri_histo_atlas_segment_fireants).
#
# NextBrain (Casamitjana A, et al. "A probabilistic histological atlas of the
# human brain for MRI segmentation", Nature 2025; fast version: Puonti O, et al.
# Imaging Neuroscience 2026) is FreeSurfer's next-generation probabilistic atlas:
# ~300 ROIs per hemisphere from serial histology, including the brainstem at
# nucleus level (pontine nuclei, locus coeruleus, raphe, reticular formation,
# cranial-nerve nuclei, lemnisci, peduncles, ...). Segmentation is Bayesian and
# therefore contrast-agnostic (T1/T2/FLAIR) and does NOT need a recon-all: it
# takes the scan directly:
#     mri_histo_atlas_segment_fireants --i SCAN --o OUTDIR --device cpu \
#         --side left|right --mode invivo
# and writes seg.<side>.nii.gz (0.4 mm by default), lut.txt and vols.<side>.csv
# (https://surfer.nmr.mgh.harvard.edu/fswiki/HistoAtlasSegmentation).
#
# What this module does (all NON-fatal, cached/idempotent):
#   1. gate: BRAINSTEM_NEXTBRAIN_ENABLED + command on PATH + FS license;
#   2. run both sides sequentially (SuperSynth preprocessing is reused), with
#      stdin closed so the tool's first-run "download the atlas?" prompt fails
#      fast instead of hanging the pipeline (pre-run it ONCE interactively);
#   3. resample each side's label volume onto the subject grid (NN);
#   4. keep only brainstem labels (NEXTBRAIN_LABEL_REGEX on lut.txt names) and
#      split them into segmentation/detailed_brainstem/nextbrain_<name>_<l|r>_label<v>.nii.gz
#      — discovered by analysis.sh:find_all_atlas_regions (source tag
#      'nextbrain', SEG_TOOL_SOURCE_TAGS) for per-region GMM detection;
#   5. a combined subject-space dseg for the viewer + volume CSVs + provenance.
#
# Caveats: NextBrain is a 2025/2026 method; brainstem nucleus labels are
# histology-derived priors and are NOT lesion-validated — treat them as
# corroborating anatomy, not ground truth. Runtime is ~15-30 min per side on
# CPU (needs a few GB RAM; --skip 2 lowers memory).
#
# NOTE: sourced module — no `set -e -u -o pipefail` here (would leak into the
# pipeline shell). Every path returns 0 unless explicitly stated.
#

if [ -n "${_BRAINSTEM_NEXTBRAIN_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_BRAINSTEM_NEXTBRAIN_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# Defaults (config/default_config.sh normally provides these).
: "${BRAINSTEM_NEXTBRAIN_ENABLED:=true}"
: "${NEXTBRAIN_MODE:=invivo}"
: "${NEXTBRAIN_DEVICE:=cpu}"
: "${NEXTBRAIN_SIDES:=left right}"
: "${NEXTBRAIN_THREADS:=}"
: "${NEXTBRAIN_EXTRA_ARGS:=}"
: "${NEXTBRAIN_OUTPUT_DIR:=}"
: "${NEXTBRAIN_LABEL_REGEX:=pons|pontine|locus|coeruleus|raphe|reticular|lemnisc|peduncle|corticospinal|pyramid|trigemin|abducens|facial|vestibul|cochlear|oliv|trapezoid|parabrachial|pedunculopontine|tegment|medulla|midbrain|nigra|red_nucleus|periaqueductal|central_gray|colliculus|oculomotor|trochlear|hypoglossal|solitar|cuneate|gracile|ambiguus|vagus|brainstem|brain_stem|interpeduncular|cuneiform|laterodorsal|dorsal_motor|area_postrema|substantia|tectum|cerebellar_peduncle}"

# _nextbrain_detect_command -> echoes the command path (fast FireANTs entry
# point preferred; legacy full-Bayesian command accepted). Returns 1 if absent.
_nextbrain_detect_command() {
    local c
    for c in mri_histo_atlas_segment_fireants mri_histo_atlas_segment; do
        if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
        if [ -n "${FREESURFER_HOME:-}" ] && [ -x "${FREESURFER_HOME}/bin/${c}" ]; then
            printf '%s\n' "${FREESURFER_HOME}/bin/${c}"; return 0
        fi
    done
    return 1
}

# _nextbrain_license_ok -> 0 when a FreeSurfer license is discoverable.
_nextbrain_license_ok() {
    [ -n "${FS_LICENSE:-}" ] && [ -f "${FS_LICENSE}" ] && return 0
    [ -n "${FREESURFER_HOME:-}" ] && { [ -f "${FREESURFER_HOME}/license.txt" ] || [ -f "${FREESURFER_HOME}/.license" ]; } && return 0
    return 1
}

# _nextbrain_parse_lut <lut.txt> <side_suffix> [regex] -> "value<TAB>name_<side>"
#   FreeSurfer LUT format: "<idx> <Name> R G B A"; keeps rows whose sanitised
#   name matches the (case-insensitive) brainstem regex.
_nextbrain_parse_lut() {
    local lut="$1" side="$2" regex="${3:-${NEXTBRAIN_LABEL_REGEX}}"
    [ -f "$lut" ] || return 1
    awk -v side="$side" -v re="$regex" '
        { sub(/\r$/, "") }
        /^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next }
        $1 ~ /^[0-9]+$/ && $1 > 0 {
            name = $2
            # Names may contain spaces before the RGB columns: join fields until a numeric run of 3-4.
            for (i = 3; i <= NF; i++) { if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^[0-9]+$/ && $(i+2) ~ /^[0-9]+$/) break; name = name "_" $i }
            gsub(/[ \/-]+/, "_", name); gsub(/[^A-Za-z0-9_]/, "", name)
            lname = tolower(name)
            if (lname ~ re) printf "%d\t%s_%s\n", $1, name, side
        }' "$lut"
}

# _nextbrain_resample <seg.nii.gz> <reference> <out> — NN onto the subject grid.
_nextbrain_resample() {
    local seg="$1" ref="$2" out="$3"
    if command -v mri_convert >/dev/null 2>&1; then
        mri_convert -rl "$ref" -rt nearest "$seg" "$out" >/dev/null 2>&1 && [ -f "$out" ] && return 0
    fi
    if command -v flirt >/dev/null 2>&1; then
        flirt -in "$seg" -ref "$ref" -applyxfm -usesqform -interp nearestneighbour -out "$out" >/dev/null 2>&1 && [ -f "$out" ] && return 0
    fi
    return 1
}

# _nextbrain_combine_sides <left_dseg> <right_dseg> <out> — one dseg for the
# viewer (right-hemisphere values offset by 100000). Best-effort (python).
_nextbrain_combine_sides() {
    local l="$1" r="$2" out="$3"
    local py=""
    if declare -f _multi_atlas_python >/dev/null 2>&1; then py=$(_multi_atlas_python 2>/dev/null || true); fi
    [ -n "$py" ] || { command -v uv >/dev/null 2>&1 && py="uv run python"; }
    [ -n "$py" ] || return 1
    # shellcheck disable=SC2086
    $py - "$l" "$r" "$out" <<'PYEOF' >/dev/null 2>&1
import sys, numpy as np, nibabel as nib
l, r, out = sys.argv[1:4]
li = nib.load(l); L = np.asanyarray(li.dataobj).astype(np.int64)
R = np.asanyarray(nib.load(r).dataobj).astype(np.int64) if r and r != '-' else np.zeros_like(L)
if R.shape != L.shape:
    sys.exit(2)
C = L.copy(); m = R > 0; C[m] = R[m] + 100000
nib.save(nib.Nifti1Image(C.astype(np.int32), li.affine, li.header), out)
PYEOF
    [ -f "$out" ]
}

# run_nextbrain_brainstem <input_t1> [input_basename] [out_dir]
#   Orchestrator. Returns 0 on success/skip; 1 only when it ran but produced
#   nothing usable (the caller treats that as a non-fatal path failure).
run_nextbrain_brainstem() {
    local input_t1="${1:-}"
    local input_basename="${2:-$(basename "${input_t1:-x}" .nii.gz)}"
    local out_dir="${3:-${NEXTBRAIN_OUTPUT_DIR:-}}"

    log_formatted "INFO" "=== NEXTBRAIN HISTOLOGICAL-ATLAS BRAINSTEM SEGMENTATION (FreeSurfer mri_histo_atlas_segment) ==="

    if [ "${BRAINSTEM_NEXTBRAIN_ENABLED:-true}" != "true" ]; then
        log_formatted "INFO" "BRAINSTEM_NEXTBRAIN_ENABLED != true — skipping NextBrain (non-fatal)"
        return 0
    fi
    if [ -z "$input_t1" ] || [ ! -f "$input_t1" ]; then
        log_formatted "WARNING" "run_nextbrain_brainstem: input scan missing (${input_t1:-<none>}) — skipping (non-fatal)"
        return 0
    fi
    local cmd
    if ! cmd=$(_nextbrain_detect_command); then
        log_formatted "WARNING" "NextBrain command (mri_histo_atlas_segment_fireants) not found — install a FreeSurfer 8 dev build (fswiki/HistoAtlasSegmentation); skipping (non-fatal)"
        return 0
    fi
    if ! _nextbrain_license_ok; then
        log_formatted "WARNING" "FreeSurfer license not found (FS_LICENSE / \$FREESURFER_HOME/license.txt) — NextBrain skipped (non-fatal)"
        return 0
    fi

    [ -n "$out_dir" ] || out_dir="${RESULTS_DIR:-../mri_results}/segmentation/nextbrain"
    local region_out="${RESULTS_DIR:-../mri_results}/segmentation/detailed_brainstem"
    mkdir -p "$out_dir" "$region_out" 2>/dev/null || {
        log_formatted "WARNING" "Cannot create NextBrain workspace $out_dir — skipping (non-fatal)"
        return 0
    }
    log_message "Input: $input_t1"
    log_message "Workspace: $out_dir  (mode=${NEXTBRAIN_MODE}, device=${NEXTBRAIN_DEVICE}, sides=${NEXTBRAIN_SIDES})"

    local threads="${NEXTBRAIN_THREADS:-${ANTS_THREADS:-}}"
    local side rc=0 produced=0 any_seg=0
    local -a extra=()
    # shellcheck disable=SC2206
    [ -n "${NEXTBRAIN_EXTRA_ARGS:-}" ] && extra=( ${NEXTBRAIN_EXTRA_ARGS} )

    for side in ${NEXTBRAIN_SIDES}; do
        local seg="${out_dir}/seg.${side}.nii.gz"
        if [ -f "$seg" ]; then
            log_message "  ${side}: reusing cached $seg (delete to re-run)"
        else
            log_message "  ${side}: running NextBrain (this takes ~15-30 min per side on CPU)"
            local -a args=(--i "$input_t1" --o "$out_dir" --device "${NEXTBRAIN_DEVICE}" --side "$side" --mode "${NEXTBRAIN_MODE}")
            [ -n "$threads" ] && args+=(--threads "$threads")
            rc=0
            # stdin closed: the first-run atlas-download prompt must fail fast, never hang.
            "$cmd" "${args[@]}" "${extra[@]}" </dev/null >"${out_dir}/nextbrain_${side}.log" 2>&1 || rc=$?
            if [ "$rc" -ne 0 ] || [ ! -f "$seg" ]; then
                log_formatted "WARNING" "NextBrain ${side} failed (rc=$rc; log: ${out_dir}/nextbrain_${side}.log). If this is the first run, execute '$cmd' once interactively to download the atlas + SuperSynth model. Skipping ${side} (non-fatal)."
                continue
            fi
        fi
        any_seg=1
    done
    [ "$any_seg" -eq 1 ] || { log_formatted "WARNING" "NextBrain produced no segmentation"; return 1; }

    local lut="${out_dir}/lut.txt"
    [ -f "$lut" ] || lut=$(find "$out_dir" -maxdepth 2 -name 'lut*.txt' -print -quit 2>/dev/null)
    if [ -z "$lut" ] || [ ! -f "$lut" ]; then
        log_formatted "WARNING" "NextBrain lut.txt not found in $out_dir — cannot name labels; skipping split (non-fatal)"
        return 1
    fi

    local combined_left="" combined_right=""
    for side in ${NEXTBRAIN_SIDES}; do
        local seg="${out_dir}/seg.${side}.nii.gz"
        [ -f "$seg" ] || continue
        local suffix="l"; [ "$side" = "right" ] && suffix="r"
        local side_lut="${out_dir}/nextbrain_brainstem_labels_${side}.txt"
        { printf '# value\tname\t(NextBrain lut.txt filtered by NEXTBRAIN_LABEL_REGEX)\n'
          _nextbrain_parse_lut "$lut" "$suffix"; } > "$side_lut"
        local n; n=$(grep -vc '^#' "$side_lut" 2>/dev/null || echo 0)
        if [ "${n:-0}" -eq 0 ]; then
            log_formatted "WARNING" "NextBrain ${side}: no label name matched NEXTBRAIN_LABEL_REGEX — nothing to split"
            continue
        fi
        log_message "  ${side}: $n brainstem labels selected from lut.txt"
        local subj="${out_dir}/nextbrain_${side}_in_subject.nii.gz"
        if ! _nextbrain_resample "$seg" "$input_t1" "$subj"; then
            log_formatted "WARNING" "NextBrain ${side}: resample onto the subject grid failed (mri_convert/flirt) — skipping"
            continue
        fi
        if declare -f split_dseg_to_region_masks >/dev/null 2>&1; then
            split_dseg_to_region_masks "$subj" "$side_lut" "$region_out" "nextbrain" && produced=$((produced + 1))
        else
            log_formatted "WARNING" "split_dseg_to_region_masks unavailable (multi_atlas.sh not loaded) — masks not split"
        fi
        [ "$side" = "left" ] && combined_left="$subj" || combined_right="$subj"
        [ -f "${out_dir}/vols.${side}.csv" ] && log_message "  ${side}: volumes -> ${out_dir}/vols.${side}.csv"
    done

    # Combined dseg for the viewer (best effort).
    if [ -n "$combined_left" ] || [ -n "$combined_right" ]; then
        _nextbrain_combine_sides "${combined_left:-$combined_right}" "${combined_right:--}" "${out_dir}/nextbrain_in_subject.nii.gz" || true
        if declare -f _emit_atlas_view >/dev/null 2>&1 && [ -f "${out_dir}/nextbrain_in_subject.nii.gz" ]; then
            _emit_atlas_view "$input_t1" "${out_dir}/nextbrain_in_subject.nii.gz" "${out_dir}/views" "nextbrain"
        fi
    fi

    {
        printf 'tool\t%s\n' "$cmd"
        printf 'input\t%s\n' "$input_t1"
        printf 'mode\t%s\ndevice\t%s\nsides\t%s\n' "$NEXTBRAIN_MODE" "$NEXTBRAIN_DEVICE" "$NEXTBRAIN_SIDES"
        printf 'label_regex\t%s\n' "$NEXTBRAIN_LABEL_REGEX"
        printf 'citation\tCasamitjana A, et al. Nature 2025; Puonti O, et al. Imaging Neuroscience 2026\n'
        printf 'region_masks\t%s/nextbrain_*_label*.nii.gz\n' "$region_out"
    } > "${out_dir}/nextbrain_provenance.tsv" 2>/dev/null || true

    if [ "$produced" -gt 0 ]; then
        log_formatted "SUCCESS" "NextBrain brainstem nuclei written to $region_out (nextbrain_*_label*.nii.gz)"
        return 0
    fi
    log_formatted "WARNING" "NextBrain ran but no brainstem region masks were produced"
    return 1
}

export -f run_nextbrain_brainstem _nextbrain_parse_lut _nextbrain_detect_command
log_message "NextBrain module loaded (BRAINSTEM_NEXTBRAIN_ENABLED=${BRAINSTEM_NEXTBRAIN_ENABLED})"
