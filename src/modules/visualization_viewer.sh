#!/usr/bin/env bash
#
# visualization_viewer.sh - Interactive web (NiiVue) viewer + 3D-renderable outputs
#
# Generates a self-contained, browser-based viewer over the pipeline's NIfTI
# outputs: background T1/registered-FLAIR, segmentation masks, per-atlas nuclei
# dsegs, hyperintensity clusters across thresholds, the cross-source consensus /
# agreement maps, and a registration-QC overlay. Everything is .nii.gz, so the
# viewer's "3D Render" mode is the requested 3D visualization (no extra format).
#
# Outputs under <RESULTS_DIR>/reports/viewer/:
#   index.html        - the NiiVue viewer (vendored JS, CDN fallback)
#   niivue.umd.js      - vendored viewer engine (offline-capable)
#   manifest.json      - discovered layers (grouped), URLs relative to RESULTS_DIR
#   serve_viewer.sh    - launches `python3 -m http.server` rooted at RESULTS_DIR
#
# Browsers cannot fetch local .nii.gz over file://, so the viewer is meant to be
# served (serve_viewer.sh); opened directly it falls back to drag-and-drop.
#
# Gated by VIEWER_ENABLED (default true) and SKIP_VISUALIZATION. Fully graceful:
# absent layers are simply omitted; a minimal T1+FLAIR run still yields a viewer.

if [ -n "${_VISUALIZATION_VIEWER_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_VISUALIZATION_VIEWER_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/require_env.sh"

# Emit a manifest layer JSON object. Args: name url colormap opacity
_vw_layer_json() {
    printf '{"name":"%s","url":"%s","colormap":"%s","opacity":%s}' "$1" "$2" "$3" "$4"
}

# Echo a viewer-relative URL for an absolute/relative path under RESULTS_DIR.
# The http server roots at RESULTS_DIR; the page lives at reports/viewer/, so a
# file at <RESULTS_DIR>/X is reachable as ../../X. Empty if not under RESULTS_DIR.
_vw_rel_url() {
    local p="$1" root="$2"
    # Normalise both to absolute where possible for a clean prefix strip.
    case "$p" in
        "$root"/*) echo "../../${p#"$root"/}" ;;
        /*)        echo "" ;;                       # absolute but outside root
        *)         echo "../../${p#./}" ;;          # already relative to root
    esac
}

# Find first existing file matching any of the given patterns (case-INSENSITIVE,
# top level only). Returns the first hit across the patterns, in order.
_vw_find() {
    local dir="$1"; shift
    [ -d "$dir" ] || return 1
    local pat f
    for pat in "$@"; do
        f=$(find "$dir" -maxdepth 1 -iname "$pat" -print -quit 2>/dev/null)
        [ -n "$f" ] && [ -f "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# generate_interactive_viewer <subject_id> <results_dir>
# ---------------------------------------------------------------------------
generate_interactive_viewer() {
    local subject_id="$1"
    local results_dir="${2:-$RESULTS_DIR}"

    if [ "${VIEWER_ENABLED:-true}" != "true" ]; then
        log_message "Interactive viewer disabled (VIEWER_ENABLED!=true); skipping"
        return 0
    fi
    if [ "${SKIP_VISUALIZATION:-false}" = "true" ]; then
        log_message "SKIP_VISUALIZATION=true; skipping interactive viewer"
        return 0
    fi

    log_formatted "INFO" "===== INTERACTIVE VIEWER (NiiVue) ====="

    local web_src; web_src="$(dirname "${BASH_SOURCE[0]}")/../web"
    local viewer_dir="${results_dir}/reports/viewer"
    mkdir -p "$viewer_dir" || { log_formatted "WARNING" "Viewer: cannot create $viewer_dir; skipping"; return 0; }

    # --- assets (HTML + vendored JS) -----------------------------------------
    if [ -f "${web_src}/niivue_viewer.html" ]; then
        cp -f "${web_src}/niivue_viewer.html" "${viewer_dir}/index.html"
    else
        log_formatted "WARNING" "Viewer template missing (${web_src}/niivue_viewer.html); skipping"
        return 0
    fi
    if [ -f "${web_src}/vendor/niivue.umd.js" ]; then
        cp -f "${web_src}/vendor/niivue.umd.js" "${viewer_dir}/niivue.umd.js"
    else
        log_message "  (vendored niivue.umd.js absent — viewer will use the CDN fallback)"
    fi

    # --- discover layers ------------------------------------------------------
    local seg="${results_dir}/segmentation"
    local detail="${seg}/detailed_brainstem"
    local hyper="${results_dir}/hyperintensities"
    local reg="${results_dir}/registered"
    local std="${results_dir}/standardized"

    local bex="${results_dir}/brain_extraction"
    local t1_std flair_std flair_orig t1_orig flair_warp brainstem
    t1_std=$(_vw_find "$std" "*t1*_std.nii.gz" 2>/dev/null || true)
    flair_std=$(_vw_find "$std" "*flair*_std.nii.gz" 2>/dev/null || true)
    flair_orig=$(_vw_find "$bex" "*flair*brain.nii.gz" 2>/dev/null || true)
    t1_orig=$(_vw_find "$bex" "*t1*brain.nii.gz" 2>/dev/null || true)
    flair_warp=$(_vw_find "$reg" "*_to_flair*Warped.nii.gz" "*flair*Warped.nii.gz" "t1_to_flairWarped.nii.gz" 2>/dev/null || true)
    brainstem=$(_vw_find "${seg}/brainstem" "*_brainstem.nii.gz" 2>/dev/null || true)

    # Group accumulators (arrays of JSON objects).
    local -a G_bg=() G_seg=() G_atlas=() G_hyper=() G_cons=() G_reg=()
    local u

    # background (radio): standardized images share the segmentation/atlas space;
    # the original-space FLAIR matches the hyperintensity masks. Pick whichever
    # aligns with the overlay you're viewing.
    [ -n "$t1_std" ]    && { u=$(_vw_rel_url "$t1_std" "$results_dir");    [ -n "$u" ] && G_bg+=("$(_vw_layer_json "T1 (standardized)" "$u" gray 100)"); }
    [ -n "$flair_std" ] && { u=$(_vw_rel_url "$flair_std" "$results_dir"); [ -n "$u" ] && G_bg+=("$(_vw_layer_json "FLAIR (standardized)" "$u" gray 100)"); }
    [ -n "$flair_orig" ] && { u=$(_vw_rel_url "$flair_orig" "$results_dir"); [ -n "$u" ] && G_bg+=("$(_vw_layer_json "FLAIR (original/analysis)" "$u" gray 100)"); }
    [ -n "$t1_orig" ]   && { u=$(_vw_rel_url "$t1_orig" "$results_dir");   [ -n "$u" ] && G_bg+=("$(_vw_layer_json "T1 (original)" "$u" gray 100)"); }

    # segmentation: gross brainstem + whole subdivisions (skip left/right + nucleus labels for clarity)
    [ -n "$brainstem" ] && { u=$(_vw_rel_url "$brainstem" "$results_dir"); [ -n "$u" ] && G_seg+=("$(_vw_layer_json "Brainstem (gross)" "$u" red 50)"); }
    local subf sub
    for sub in midbrain pons medulla; do
        # whole subdivision only (exclude left/right partials + nucleus labels)
        subf=$(find "$detail" -maxdepth 1 -name "*_${sub}.nii.gz" ! -iname "*left*" ! -iname "*right*" ! -iname "*label*" -print -quit 2>/dev/null || true)
        if [ -n "$subf" ] && [ -f "$subf" ]; then
            u=$(_vw_rel_url "$subf" "$results_dir"); [ -n "$u" ] && G_seg+=("$(_vw_layer_json "$sub" "$u" "$( [ "$sub" = pons ] && echo green || echo blue )" 55)")
        fi
    done

    # atlases (exclusive): per-atlas subject-space dseg (all nuclei, colour-coded)
    local af aname
    for aname in bianciardi cit168 aal3; do
        af="${seg}/multi_atlas/${aname}_in_subject.nii.gz"
        if [ -f "$af" ]; then u=$(_vw_rel_url "$af" "$results_dir"); [ -n "$u" ] && G_atlas+=("$(_vw_layer_json "${aname} (nuclei)" "$u" random 70)"); fi
    done

    # hyperintensity (exclusive): GMM union + per-threshold masks
    local gmm
    gmm=$(_vw_find "$hyper" "*_brainstem_threshATLAS_GMM_bin.nii.gz" 2>/dev/null || true)
    [ -n "$gmm" ] && { u=$(_vw_rel_url "$gmm" "$results_dir"); [ -n "$u" ] && G_hyper+=("$(_vw_layer_json "GMM union (primary)" "$u" hot 70)"); }
    local tf t
    for t in 1.2 1.25 1.3 1.5 2.0 2.5 3.0; do
        tf=$(find "$hyper" -maxdepth 1 \( -name "*_brainstem_thresh${t}_bin.nii.gz" -o -name "*_pons_thresh${t}.nii.gz" \) -print -quit 2>/dev/null || true)
        if [ -n "$tf" ] && [ -f "$tf" ]; then u=$(_vw_rel_url "$tf" "$results_dir"); [ -n "$u" ] && G_hyper+=("$(_vw_layer_json "threshold ${t}" "$u" hot 70)"); fi
    done

    # consensus / agreement (#1)
    local agf consf
    agf=$(_vw_find "$hyper" "*_agreement_count.nii.gz" 2>/dev/null || true)
    [ -n "$agf" ] && { u=$(_vw_rel_url "$agf" "$results_dir"); [ -n "$u" ] && G_cons+=("$(_vw_layer_json "agreement count (#sources)" "$u" warm 80)"); }
    for consf in "$hyper"/*_consensus_min*.nii.gz; do
        [ -f "$consf" ] || continue
        u=$(_vw_rel_url "$consf" "$results_dir"); [ -n "$u" ] && G_cons+=("$(_vw_layer_json "$(basename "$consf" .nii.gz | sed -E 's/.*_(consensus_min[0-9]+)$/\1/')" "$u" hot 75)")
    done

    # registration QC: overlay the two standardized modalities (blend slider) +
    # the warped/moved image if present. Aligned overlay = good registration.
    [ -n "$t1_std" ]    && { u=$(_vw_rel_url "$t1_std" "$results_dir");    [ -n "$u" ] && G_reg+=("$(_vw_layer_json "T1 (standardized)" "$u" gray 100)"); }
    [ -n "$flair_std" ] && { u=$(_vw_rel_url "$flair_std" "$results_dir"); [ -n "$u" ] && G_reg+=("$(_vw_layer_json "FLAIR (standardized)" "$u" gray 50)"); }
    [ -n "$flair_warp" ] && { u=$(_vw_rel_url "$flair_warp" "$results_dir"); [ -n "$u" ] && G_reg+=("$(_vw_layer_json "warped/moved (to reference)" "$u" gray 50)"); }

    # --- assemble manifest.json ----------------------------------------------
    local manifest="${viewer_dir}/manifest.json"
    {
        printf '{\n  "subject": "%s",\n  "groups": [\n' "$subject_id"
        local first_group=1
        _vw_emit_group() {  # id label arr...
            local id="$1" label="$2"; shift 2
            [ "$#" -gt 0 ] || return 0
            [ "$first_group" -eq 1 ] || printf ',\n'
            first_group=0
            local joined oldIFS="$IFS"
            IFS=,; joined="$*"; IFS="$oldIFS"
            printf '    {"id":"%s","label":"%s","layers":[%s]}' "$id" "$label" "$joined"
        }
        _vw_emit_group background "Background"                "${G_bg[@]}"
        _vw_emit_group segmentation "Segmentation"            "${G_seg[@]}"
        _vw_emit_group atlases "Atlases (nuclei)"             "${G_atlas[@]}"
        _vw_emit_group hyperintensity "Hyperintensity × threshold" "${G_hyper[@]}"
        _vw_emit_group consensus "Consensus / agreement"      "${G_cons[@]}"
        _vw_emit_group registration "Registration check"      "${G_reg[@]}"
        printf '\n  ]\n}\n'
    } > "$manifest"

    # --- serve script ---------------------------------------------------------
    local serve="${viewer_dir}/serve_viewer.sh"
    {
        echo "#!/usr/bin/env bash"
        echo "# Serve the BrainStemX interactive viewer. Browsers cannot fetch local"
        echo "# .nii.gz over file://, so this roots a tiny HTTP server at the results dir."
        echo "set -e"
        echo "PORT=\"\${1:-8765}\""
        echo "ROOT=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")/../..\" && pwd)\""
        echo "echo \"Serving \$ROOT at http://localhost:\$PORT\""
        echo "echo \"Open: http://localhost:\$PORT/reports/viewer/index.html\""
        echo "cd \"\$ROOT\""
        echo "exec python3 -m http.server \"\$PORT\""
    } > "$serve"
    chmod +x "$serve"

    local n_layers
    n_layers=$(( ${#G_bg[@]} + ${#G_seg[@]} + ${#G_atlas[@]} + ${#G_hyper[@]} + ${#G_cons[@]} + ${#G_reg[@]} ))
    log_formatted "SUCCESS" "Interactive viewer ready: ${viewer_dir}/index.html (${n_layers} layers)"
    log_message "  View it:  bash ${serve}   then open the printed localhost URL"
    return 0
}

export -f _vw_layer_json _vw_rel_url _vw_find generate_interactive_viewer
log_message "Interactive viewer module loaded"
