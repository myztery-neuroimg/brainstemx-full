#!/usr/bin/env bash
#
# default_config.sh - Default configuration for the brain MRI processing pipeline
#
# This file contains default configuration parameters for the pipeline.
# Users can override these parameters by creating a custom configuration file
# and passing it to the pipeline using the -c/--config option.
#

# Include guard — prevent re-sourcing from clobbering user arguments
if [ -n "${_DEFAULT_CONFIG_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_DEFAULT_CONFIG_LOADED=1

# Moved from environment.sh
# ------------------------------------------------------------------------------
# Key Environment Variables (Paths & Directories)
# ------------------------------------------------------------------------------
export DICOM_PRIMARY_PATTERN='I*'   # Primary pattern to try first (matches Siemens MAGNETOM Image-00985 format)
export PIPELINE_SUCCESS=true       # Track overall pipeline success
export PIPELINE_ERROR_COUNT=0      # Count of errors in pipeline

# Parallelization configuration (defaults, can be overridden by config file)
export PARALLEL_JOBS=0             # Number of parallel jobs (0 = auto-detect)
export MAX_CPU_INTENSIVE_JOBS=1    # Number of jobs for CPU-intensive operations
export PARALLEL_TIMEOUT=0          # Timeout for parallel operations (0 = no timeout)
export PARALLEL_HALT_MODE="soon"   # How to handle failed parallel jobs

export EXTRACT_DIR="../extracted"
export RESULTS_DIR="../mri_results"
mkdir -p "$RESULTS_DIR"
mkdir -p "$EXTRACT_DIR"

# Set ANTs Path relative to the script location
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Ensure ANTS_PATH is properly expanded
export ANTS_PATH="${ANTS_PATH}"
# Replace tilde with $HOME if present
export ANTS_PATH="${ANTS_PATH/#\~/$HOME}"
export ANTS_BIN="${ANTS_PATH}/bin"
# Log ANTs paths for debugging
log_message "ANTs paths: ANTS_PATH=$ANTS_PATH, ANTS_BIN=$ANTS_BIN"
# Flag to toggle ANTs SyN vs FLIRT linear registration
export USE_ANTS_SYN="${USE_ANTS_SYN:-true}"
log_message "USE_ANTS_SYN=$USE_ANTS_SYN"

export CORES="$(cpuinfo  | grep -i count | sed 's/.* //')"
export ANTS_THREADS=$CORES  # Use most but not all cores

# Add ANTs to PATH if it exists
if [ -d "$ANTS_BIN" ]; then
  export PATH="$PATH:${ANTS_BIN}"
  log_formatted "INFO" "Added ANTs bin directory to PATH: $ANTS_BIN"
  # Set ANTs/ITK threading variables for proper parallelization
  export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$ANTS_THREADS"
  export OMP_NUM_THREADS="$ANTS_THREADS"
  export ANTS_RANDOM_SEED=1234
  log_formatted "INFO" "Set parallel processing variables: ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=$ANTS_THREADS, OMP_NUM_THREADS=$ANTS_THREADS"
else
  log_formatted "ERROR" "ANTs bin directory not found: $ANTS_BIN"
fi

export SRC_DIR="${HOME}/DICOM"        # DICOM input directory
export LOG_DIR="${RESULTS_DIR}/logs"
# ------------------------------------------------------------------------------
# Pipeline Parameters / Presets
# ------------------------------------------------------------------------------
export PROCESSING_DATATYPE="float"  # internal float
export OUTPUT_DATATYPE="int"        # final int16

# Atlas and template configuration
export DEFAULT_TEMPLATE_RES="${DEFAULT_TEMPLATE_RES:-1mm}"

# ---------------------------------------------------------------------------
# Brainstem segmentation method
# ---------------------------------------------------------------------------
# Controls how the brainstem and its substructures (midbrain/pons/medulla/SCP)
# are obtained.
#   freesurfer : recon-all + segmentBS (Iglesias 2015) for the substructures,
#                with the Harvard-Oxford gross Brain-Stem mask as the extent and
#                the FS<->HO agreement QC gate. Falls back gracefully to the HO
#                gross mask when FreeSurfer/recon-all/license is unavailable or
#                the FS<->HO agreement is too low.
#   atlas      : Harvard-Oxford gross Brain-Stem mask only (no substructures).
#                (alias: harvard_oxford)
#   multi_atlas: nucleus-level labeling from the Bianciardi BrainstemNavigator
#                (+ CIT168, + optional AAL3) warped to subject space, layered on
#                the Harvard-Oxford gross extent. Per-atlas enables below.
#                (alias: bianciardi). Requires the atlases on disk under
#                $FSLDIR/data/atlases — see multi_atlas.sh / docs.
# Talairach has been removed entirely (single 1988 post-mortem brain; largest
# MNI-mapping error inferiorly/posteriorly — worst exactly in the brainstem).
export BRAINSTEM_SEGMENTATION_METHOD="${BRAINSTEM_SEGMENTATION_METHOD:-freesurfer}"

# FreeSurfer brainstem-segmentation knobs (used by brainstem_freesurfer.sh).
# FREESURFER_HOME / FS_LICENSE are honoured from the environment; the module
# detects them and degrades to the HO gross mask when absent.
export FS_RECON_ALL_FLAG="${FS_RECON_ALL_FLAG:--all}"   # recon-all level (segmentBS needs aseg/norm)
# FS<->HO agreement gate (mirrors the existing brain-mask Dice QC style):
export FS_BS_AGREEMENT_DICE_MIN="${FS_BS_AGREEMENT_DICE_MIN:-0.7}"        # min Dice(FS union, HO Brain-Stem)
export FS_BS_AGREEMENT_LEAKAGE_MAX="${FS_BS_AGREEMENT_LEAKAGE_MAX:-0.2}"  # max fraction of FS union outside HO

# ---------------------------------------------------------------------------
# Multi-atlas brainstem labeling (used when BRAINSTEM_SEGMENTATION_METHOD is
# 'multi_atlas' or 'bianciardi'; see multi_atlas.sh and
# docs/multi_atlas_integration_spec.md).
# ---------------------------------------------------------------------------
# Atlases must be pre-downloaded under $FSLDIR/data/atlases:
#   Bianciardi/BrainstemNavigatorv1.0/1.0/{2a,2b}.* (MNI dirs only; IIT 1a/1b excluded)
#   CIT168/MNI152/tpl-MNI152NLin6Asym_atlas-CIT168_res-01_dseg.nii.gz + CIT168_labels.txt
#   AAL3/AAL3/AAL3v1_1mm.nii.gz + AAL3v1.nii.txt
export ATLAS_DIR="${ATLAS_DIR:-${FSLDIR}/data/atlases}"
# Derived/cached MNI dsegs live under each atlas's */derived subdir by default.
export MULTI_ATLAS_CACHE_DIR="${MULTI_ATLAS_CACHE_DIR:-${ATLAS_DIR}}"
# Per-atlas enables. AAL3 is whole-brain and OFF by default (brainstem subset
# only when on); CIT168 + Bianciardi are brainstem/subcortical-focused.
export USE_BIANCIARDI="${USE_BIANCIARDI:-true}"
export USE_CIT168="${USE_CIT168:-true}"
export USE_AAL3="${USE_AAL3:-false}"
# Bianciardi thresholded-probabilistic level (matches the on-disk subdir name).
export BIANCIARDI_PROB_THRESHOLD="${BIANCIARDI_PROB_THRESHOLD:-0.35}"
# Bianciardi MNI source subdirs (relative to the BrainstemNavigator 1.0 root).
export BIANCIARDI_MNI_SUBDIRS="${BIANCIARDI_MNI_SUBDIRS:-2a.BrainstemNucleiAtlas_MNI/labels_thresholded_probabilistic_${BIANCIARDI_PROB_THRESHOLD} 2b.DiencephalicNucleiAtlas_MNI/labels_thresholded_probabilistic_${BIANCIARDI_PROB_THRESHOLD}}"

# Harvard-Oxford subcortical maxprob probability threshold for the gross
# Brain-Stem extent. thr25 is tighter than the most-dilated thr0 variant; the
# maxprob label index is independent of this threshold.
export HO_SUB_MAXPROB_THR="${HO_SUB_MAXPROB_THR:-thr25}"

# --- Atlas availability (report-only; consumed by check_atlas_availability) ---
# Paths are RELATIVE to "${FSLDIR}/data/atlases". The startup atlas check reports
# presence/absence of each; absence is non-fatal (the pipeline degrades to the
# atlases it can find). Override here only if your FSL install lays atlases out
# differently.
export ATLAS_BIANCIARDI_REL="${ATLAS_BIANCIARDI_REL:-Bianciardi/BrainstemNavigatorv1.0/1.0/2a.BrainstemNucleiAtlas_MNI}"
export ATLAS_CIT168_REL="${ATLAS_CIT168_REL:-CIT168/MNI152}"
export ATLAS_AAL3_REL="${ATLAS_AAL3_REL:-AAL3/AAL3}"
export ATLAS_HARVARDOXFORD_REL="${ATLAS_HARVARDOXFORD_REL:-HarvardOxford}"

# ANTs registration parameters (existing)
# REG_TRANSFORM_TYPE is set in the "Registration & motion correction" section below
# N4 Bias Field Correction presets: "iterations,convergence_threshold,spline_distance_mm,shrink_factor"
#
# N4 -b CONVENTION (single source of truth for this pipeline):
#   The 3rd field is the b-spline mesh element spacing expressed as a single
#   ISOTROPIC SPLINE DISTANCE IN MM, fed to N4 as -b "[<spline_distance_mm>]".
#   This is the ANTs-recommended convention (a single scalar mm value rather
#   than a per-dimension mesh resolution like 2x2x3). For human brain the value
#   should sit between ~100 and ~200 mm (ANTs N4 wiki / Tustison 2010).
#   Larger distance = coarser/smoother bias field = faster; smaller distance =
#   finer fit = slower and more detailed. The spline distance is HALVED at each
#   subsequent convergence level (one level per "x"-separated iteration count).
export N4_PRESET_VERY_LOW="20x20x20,0.0001,180,2"
export N4_PRESET_LOW="35x35x35,0.00025,180,2"
export N4_PRESET_MEDIUM="70x70x70,0.0001,150,2"
export N4_PRESET_HIGH="100x100x100,0.00005,120,2"
export N4_PRESET_ULTRA="250x250x250x3,0.00001,100,2"
# FLAIR-specific N4 preset is derived per QUALITY_PRESET in the block below.
# It is deliberately GENTLER than the matching general preset (coarser mesh =>
# larger spline distance => smoother bias field, plus fewer iterations) because
# N4 can absorb diffuse FLAIR lesion contrast into the estimated bias field under
# lesion load (Valdes Hernandez 2016, PMC4846712). A smoother field is far less
# likely to soak up real lesion signal. Placeholder default; overwritten below.
export N4_PRESET_FLAIR="$N4_PRESET_HIGH"

# DICOM-specific parallel processing (only affects DICOM import)
export DICOM_IMPORT_PARALLEL=12

export QUALITY_PRESET="HIGH"


export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=$CORES
export OMP_NUM_THREADS=$CORES
export VECLIB_MAXIMUM_THREADS=$CORES
export OPENBLAS_NUM_THREADS=$CORES

if [[ "$CORES" -le 20 ]]; then  
  # VM or container -level optimisations 
  export MACHINE_SPEC="VERY_LOW"
  export QUALITY_PRESET="VERY_LOW"
  export ANTS_MEMORY_LIMIT="4G"
elif [[ "$CORES" -le 8 ]]; then   
  # Larger VM or lower-spec Mac 
  export MACHINE_SPEC="LOW"
  export QUALITY_PRESET="LOW"
  export ANTS_MEMORY_LIMIT="8G"
elif [[ "$CORES" -le 18 ]]; then   
  # MacBook Pro -level optimisations
  export MACHINE_SPEC="MEDIUM"
  export QUALITY_PRESET="MEDIUM"
  # Use all available memory efficiently
  export ANTS_MEMORY_LIMIT="14G"  # Adjust based on actual RAM
  # Optimize for Apple Silicon
else   
  # Mac Studio-level optimizations
  export MACHINE_SPEC="HIGH"
  export QUALITY_PRESET="MEDIUM"
  export ANTS_THREADS=28  # Use most but not all cores
  export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=28
  export OMP_NUM_THREADS=28
  export ANTS_MEMORY_LIMIT="64G"  # Adjust based on actual RAM
  export VECLIB_MAXIMUM_THREADS=28
  export OPENBLAS_NUM_THREADS=28
fi

echo "QUALITY_PRESET: ${QUALITY_PRESET} ANTS_THREADS:${ANTS_THREADS}" >&2

# Set default N4_PARAMS by QUALITY_PRESET.
#
# FLAIR gets a GENUINELY gentler preset (NOT a copy of the general one): a larger
# spline distance (coarser/smoother bias field) and fewer iterations than the
# matching general preset, so the estimated field cannot absorb diffuse FLAIR
# lesion contrast. Convergence threshold and shrink factor are kept aligned with
# the general preset; only the field smoothness and effort are relaxed.
if [ "$QUALITY_PRESET" == "ULTRA" ]; then
    export N4_PARAMS="$N4_PRESET_ULTRA"
    export N4_PRESET_FLAIR="150x150x150,0.00001,160,2"
elif [ "$QUALITY_PRESET" == "HIGH" ]; then
    export N4_PARAMS="$N4_PRESET_HIGH"
    export N4_PRESET_FLAIR="75x75x75,0.00005,180,2"
elif [ "$QUALITY_PRESET" == "MEDIUM" ]; then
    export N4_PARAMS="$N4_PRESET_MEDIUM"
    export N4_PRESET_FLAIR="50x50x50,0.0001,200,2"
elif [ "$QUALITY_PRESET" == "LOW" ]; then
    export N4_PARAMS="$N4_PRESET_MEDIUM"
    export N4_PRESET_FLAIR="50x50x50,0.0001,200,2"
else
    export N4_PARAMS="$N4_PRESET_VERY_LOW"
    export N4_PRESET_FLAIR="15x15x15,0.0001,200,2"
fi
# Parse out the fields for general sequences
export N4_ITERATIONS=$(echo "$N4_PARAMS"      | cut -d',' -f1)
export N4_CONVERGENCE=$(echo "$N4_PARAMS"    | cut -d',' -f2)
export N4_BSPLINE=$(echo "$N4_PARAMS"        | cut -d',' -f3)
export N4_SHRINK=$(echo "$N4_PARAMS"         | cut -d',' -f4)

# Parse out FLAIR-specific fields
export N4_ITERATIONS_FLAIR=$(echo "$N4_PRESET_FLAIR"  | cut -d',' -f1)
export N4_CONVERGENCE_FLAIR=$(echo "$N4_PRESET_FLAIR" | cut -d',' -f2)
export N4_BSPLINE_FLAIR=$(echo "$N4_PRESET_FLAIR"     | cut -d',' -f3)
export N4_SHRINK_FLAIR=$(echo "$N4_PRESET_FLAIR"      | cut -d',' -f4)

# Optional lesion-weight mask for FLAIR N4 (two-pass workflow).
#   Default empty => FLAIR N4 just uses the gentler preset above.
#   When set to a path to an existing NIfTI weight image, it is passed to N4 as
#   -w <mask> so high-weight (lesion) voxels are DOWN-weighted during bias-field
#   estimation, preventing N4 from fitting the field to lesion contrast.
# Intended two-pass workflow (lesions are unknown at first preprocessing):
#   1. Run the pipeline once with N4_FLAIR_LESION_MASK="" (gentler preset only).
#   2. Detect lesions on the first-pass output (analysis.sh).
#   3. Re-run preprocessing with N4_FLAIR_LESION_MASK=<lesion-derived weight>
#      so the second-pass bias field ignores lesion voxels.
# The weight image must already be in the same space/geometry as the FLAIR being
# corrected (i.e. the denoised, oriented FLAIR fed to N4).
export N4_FLAIR_LESION_MASK="${N4_FLAIR_LESION_MASK:-}"

# Multi-axial integration parameters (antsMultivariateTemplateConstruction2.sh)
export TEMPLATE_ITERATIONS=3
export TEMPLATE_GRADIENT_STEP=0.05
export TEMPLATE_TRANSFORM_MODEL="SyN"
export TEMPLATE_SIMILARITY_METRIC="CC"
export TEMPLATE_SHRINK_FACTORS="6x4x2x1"
export TEMPLATE_SMOOTHING_SIGMAS="3x2x1x0"
export TEMPLATE_WEIGHTS="100x100x100x10"

# Registration & motion correction
export REG_TRANSFORM_TYPE=2  # antsRegistrationSyN.sh: 2 => rigid+affine+syn
export REG_METRIC_CROSS_MODALITY="MI"  # Mutual Information - for cross-modality (T1-FLAIR)
export REG_METRIC_SAME_MODALITY="CC"   # Cross Correlation - for same modality
export REG_PRECISION=1                 # Registration precision

# Per-metric tuning shared by all stages of perform_multistage_registration().
# CC radius applies when CC is used (same-modality SyN); MI bins apply when MI is
# used (cross-modality rigid/affine/SyN). The SyN stage now selects MI for
# cross-modality pairs (e.g. FLAIR↔T1) since CC assumes correlated intensities.
export REG_MI_BINS=32                   # Histogram bins for Mutual Information metric
export REG_CC_RADIUS=4                  # Neighbourhood radius for Cross Correlation metric

# Intensity winsorization (antsRegistrationSyN.sh community standard).
# Clamps the intensity tails before registration to suppress outliers; applied to
# the global antsRegistration command in perform_multistage_registration().
export REG_WINSORIZE_LOWER=0.005        # Lower winsorize quantile
export REG_WINSORIZE_UPPER=0.995        # Upper winsorize quantile

# Interpolation used by apply_transformation() when warping discrete label/atlas/
# mask volumes (is_label=true). GenericLabel is the modern label-aware default
# (anti-aliased, preserves discrete values); continuous intensity images keep Linear.
export REG_LABEL_INTERPOLATION="GenericLabel"

# ANTs specific parameters - if not set, ANTs will use defaults
# export METRIC_SAMPLING_STRATEGY="NONE"  # Options: NONE (use all voxels), REGULAR, RANDOM
# export METRIC_SAMPLING_PERCENTAGE=1.0   # Percentage of voxels to sample (when not NONE)

# ---------------------------------------------------------------------------
# Hyperintensity detection
# ---------------------------------------------------------------------------
# This is the single authoritative threshold used as the fallback whenever a
# data-driven method (GMM, percentile) fails or has too few voxels.  Both the
# GMM path and the non-GMM detect_hyperintensities() path reference this value,
# so changing it here changes all fallback behaviour consistently.
export THRESHOLD_WM_SD_MULTIPLIER=1.2   # SD multiplier from local norm; used by GMM fallback + legacy path
export MIN_HYPERINTENSITY_SIZE=3        # Minimum cluster size in voxels (FSL cluster --minextent)

# ---------------------------------------------------------------------------
# CSF / partial-volume exclusion (posterior-fossa false-positive reduction)
# ---------------------------------------------------------------------------
# Posterior-fossa CSF pulsation/inflow around the 4th ventricle and basal
# cisterns is the dominant FALSE-POSITIVE source for brainstem FLAIR.  FSL FAST
# already produces a CSF PVE map (fast_pve_0 -> *_csf_prob.nii.gz) that was
# previously computed but never used for detection.  When enabled, the per-region
# GMM/z-score path removes high-CSF-probability voxels and the CSF-parenchyma
# partial-volume boundary band from each region mask BEFORE z-scoring/GMM.
export CSF_EXCLUSION_ENABLED=true       # Master switch; false = legacy behaviour
export CSF_PVE_THRESHOLD=0.5            # Voxels with CSF PVE > this are excluded from detection
export PV_EROSION_MM=1                  # Erode region mask by this many mm to drop CSF-parenchyma PV boundary

# Connectivity-weighting SD multipliers (apply_connectivity_weighting in analysis.sh).
# A voxel is kept if it is connected to a hyperintense seed AND above
# CONNECTIVITY_CONNECTED_SD_MULT, OR is very high intensity (above
# CONNECTIVITY_HIGH_SD_MULT) regardless of connectivity.
export CONNECTIVITY_HIGH_SD_MULT=2.0       # mean + this*std: standalone "very high" threshold
export CONNECTIVITY_CONNECTED_SD_MULT=1.5  # mean + this*std: lower threshold for connected voxels

# ---------------------------------------------------------------------------
# GMM per-region thresholding  (gmm_threshold.py --help for full docs)
# ---------------------------------------------------------------------------
# Maps 1:1 to gmm_threshold.py CLI args: GMM_<NAME> -> --<name> (underscores
# become hyphens).  analysis.sh passes these env vars to the Python script.
#
# WHY THESE VALUES:
# - SD multipliers (1.0, 1.5, 2.0, 2.5): Standard choices in lesion
#   literature for outlier detection on z-scored intensities.  2-component
#   models need a tighter multiplier because there's no "low" component
#   absorbing the left tail. These have NOT been validated on this pipeline's
#   data and should be tuned per-cohort.
# - Weight cutoffs (0.05, 0.15): Heuristic boundaries.  Below 5% the
#   "hyperintense" component is likely noise; below 15% it's small enough
#   to warrant caution.  Source: empirical, not literature.
# - Floor/fallback percentiles (95, 97.5): Conservative floors that prevent
#   the GMM from producing thresholds below the population tail.
# - Min voxels (20), voxels-per-component (30): Minimum sample sizes for
#   stable EM convergence.  sklearn's GaussianMixture will technically fit
#   with fewer, but results become unreliable.
#
export GMM_MAX_COMPONENTS=3             # --max-components: max Gaussian components (2 or 3)
export GMM_MIN_VOXELS=20                # --min-voxels: below this, skip GMM and use fallback
export GMM_VOXELS_PER_COMPONENT=30      # --voxels-per-component: adaptive n_comp = min(max, voxels/this)
export GMM_SD_2COMP=1.0                 # --sd-2comp: threshold = upper_mean + this * upper_std (2-comp)
export GMM_SD_3COMP=1.5                 # --sd-3comp: threshold = upper_mean + this * upper_std (3-comp)
export GMM_SMALL_WEIGHT_CUTOFF=0.05     # --small-weight-cutoff: upper weight < this -> conservative
export GMM_SMALL_WEIGHT_SD=2.5          # --small-weight-sd: conservative multiplier
export GMM_MODERATE_WEIGHT_CUTOFF=0.15  # --moderate-weight-cutoff: upper weight < this -> moderate
export GMM_MODERATE_WEIGHT_SD=2.0       # --moderate-weight-sd: moderate multiplier
export GMM_FLOOR_PERCENTILE=95          # --floor-percentile: threshold never below this data percentile
export GMM_FALLBACK_PERCENTILE=97.5     # --fallback-percentile: used when GMM fit fails but data exists
# NOTE: GMM_FALLBACK_THRESHOLD is intentionally NOT set here.
# It defaults to THRESHOLD_WM_SD_MULTIPLIER (above) so there is ONE
# authoritative fallback value.  Override only if you need them to diverge.

# ---------------------------------------------------------------------------
# Supervised WMH detection - FSL BIANCA  (src/modules/wmh_bianca.sh)
# ---------------------------------------------------------------------------
# BIANCA is a k-NN supervised classifier (Griffanti et al., NeuroImage 2016).
# Unlike the unsupervised GMM/intensity-threshold path above, it requires
# manually-labelled TRAINING data (a masterfile of subjects each having a FLAIR
# (+optionally T1) and a MANUAL lesion mask), OR a previously-saved classifier.
#
# DEFAULT OFF: with no training data / classifier configured, the module logs a
# clear warning and skips gracefully (non-fatal).  Enable only once you have
# either BIANCA_TRAINING_MASTERFILE or BIANCA_LOAD_CLASSIFIER set.
#
# Entry point: run_bianca_wmh <flair_std> <out_prefix> [<t1_std>] [<flair_to_mni.mat>]
export WMH_BIANCA_ENABLED=false          # master switch; true = run BIANCA in analysis stage

# --- Training data (choose ONE; both empty = graceful skip) -----------------
# Path to a BIANCA training masterfile. Each row lists, in consistent column
# order, a training subject's feature images, brain mask, manual lesion mask and
# (optionally) a FLAIR->MNI .mat. Manual lesion masks are mandatory for training.
export BIANCA_TRAINING_MASTERFILE=""     # e.g. /data/bianca_training/masterfile.txt
export BIANCA_TRAINING_DIR=""            # optional base dir holding the training images
# Path to a previously-saved classifier (from a prior --saveclassifierdata run).
# When set, BIANCA loads it instead of re-training (much faster, no manual masks).
export BIANCA_LOAD_CLASSIFIER=""         # e.g. /data/bianca_training/classifier_data
# When training, persist the classifier here so subsequent runs can --loadclassifierdata.
export BIANCA_SAVE_CLASSIFIER=""         # e.g. /data/bianca_training/classifier_data

# --- Training masterfile column layout (match YOUR training masterfile) ------
# These MUST match the column order of BIANCA_TRAINING_MASTERFILE, because BIANCA
# applies ONE global column layout to every row (training rows + the query row
# the module appends). The module builds the query row as
#   FLAIR, [T1,] brainmask, [FLAIR->MNI .mat]
# and inserts a PLACEHOLDER at BIANCA_LABEL_FEATURENUM so the query row aligns
# with the label column your training rows carry (the query's label is ignored).
# If your training layout differs, set BIANCA_FEATURESUBSET /
# BIANCA_BRAINMASK_FEATURENUM / BIANCA_MATFEATURENUM to the training columns.
export BIANCA_LABEL_FEATURENUM=4         # --labelfeaturenum: column with manual lesion masks
export BIANCA_BRAINMASK_FEATURENUM=""    # --brainmaskfeaturenum (empty = auto from query layout)
export BIANCA_FEATURESUBSET=""           # --featuresubset: intensity feature cols (empty = auto)
export BIANCA_MATFEATURENUM=""           # --matfeaturenum: FLAIR->MNI .mat col (empty = auto)
# --trainingnums: rows to train on. "all" (or empty) trains on every training
# row (1..N) and NEVER includes the appended query row. Or give an explicit list
# like "1,2,3".
export BIANCA_TRAININGNUMS="all"

# --- Classifier / feature options -------------------------------------------
export BIANCA_THRESHOLD=0.9              # probability-map threshold -> binary WMH mask (0-1)
export BIANCA_SPATIALWEIGHT=1            # --spatialweight: weight of MNI spatial features
export BIANCA_PATCHSIZES="3"             # --patchsizes: patch sizes (voxels) for local averaging
export BIANCA_PATCH3D=false             # --patch3D: true = 3D patches, false = 2D (default)
export BIANCA_TRAININGPTS=2000           # --trainingpts: max lesion points per training subject
export BIANCA_NONLESPTS=10000            # --nonlespts: max non-lesion points per training subject
export BIANCA_SELECTPTS="noborder"       # --selectpts: any | noborder | surround
export BIANCA_VERBOSE=true               # pass -v to bianca

# --- Post-processing --------------------------------------------------------
export BIANCA_MIN_CLUSTER_SIZE=0         # drop WMH clusters below this many voxels (0 = off)

# ---------------------------------------------------------------------------
# Supervised / learned WMH detection (LST-AI + FreeSurfer SAMSEG)
# ---------------------------------------------------------------------------
# Optional, pretrained, training-data-free WMH/lesion segmentation back-ends
# implemented in src/modules/wmh_lst_samseg.sh.  Both are OFF by default and
# require external tools that are NOT part of the core pipeline dependency set:
#   - LST-AI : deep-learning successor to SPM-LST. Install via 'pip install
#              lst-ai' (Python, no MATLAB) or pull the Docker image. Needs
#              co-registered FLAIR + T1; ships pretrained weights.
#   - SAMSEG : FreeSurfer >=7.x 'run_samseg --lesion' (needs $FREESURFER_HOME).
#              Synergizes with the FreeSurfer brainstem segmentation added in a
#              sibling unit (shared FreeSurfer install + brainstem labels).
# Each back-end intersects its whole-brain lesion mask with the pipeline's
# brainstem mask to report a brainstem-restricted WMH burden separately.
export WMH_LSTAI_ENABLED=false          # true => run LST-AI when available
export WMH_SAMSEG_ENABLED=false         # true => run FreeSurfer SAMSEG when available

# LST-AI options
export LSTAI_THRESHOLD=0.5              # lesion probability threshold (0-1; LST-AI default 0.5)
export LSTAI_DEVICE="cpu"              # "cpu" or a GPU id (e.g. "0")
export LSTAI_DOCKER_IMAGE="jqmcginnis/lst-ai:latest"  # used only if Docker back-end is selected

# SAMSEG options
export SAMSEG_LESION_THRESHOLD=0.3     # lesion posterior threshold (run_samseg default 0.3)
export SAMSEG_LESION_MASK_PATTERN="0 1" # one number per input (T1 FLAIR): 0=no constraint, 1=brighter-than-GM
export SAMSEG_LESION_LABEL=99          # lesion label value in SAMSEG seg.mgz
export SAMSEG_EXTRA_OPTS="--pallidum-separate"  # extra run_samseg flags (recommended when FLAIR shows pallidum)

# ===========================================================================
# Contrast-agnostic WMH detection — FreeSurfer WMH-SynthSeg (mri_WMHsynthseg)
# ---------------------------------------------------------------------------
# Optional, pretrained, contrast/resolution-agnostic WMH + whole-brain
# segmentation implemented in src/modules/wmh_synthseg.sh (entry fn:
# run_wmh_synthseg). OFF by default; requires FreeSurfer (>=7.4.x) with the
# WMH-SynthSeg model installed at
# $FREESURFER_HOME/models/WMH-SynthSeg_v10_231110.pth — NOT part of the core
# pipeline dependency set.
#
# WMH-SynthSeg (Laso et al., ISBI 2024; arXiv:2312.05119) is a domain-
# randomized SynthSeg variant that jointly segments WMH (FreeSurfer LUT label
# 77) plus ~36 brain regions on ANY contrast/resolution (incl. low-field), with
# no retraining, at 1mm isotropic.
#
# CAVEAT: independent evals find it the LEAST accurate for boundary delineation
# and it tends to OVER-FLAG hyperintense pathology as WMH — dangerous near
# brainstem CSF-flow artifacts. Position it as a ROBUSTNESS/PORTABILITY +
# ANATOMY/NORMALIZATION option, NOT the primary lesion mask; ALWAYS pair its
# output with the FP-filter.
# ===========================================================================
export WMH_SYNTHSEG_ENABLED=false       # master switch; true => run WMH-SynthSeg when available
export WMH_SYNTHSEG_LABEL=77            # WMH label value in the mri_WMHsynthseg output (FreeSurfer LUT 77)
export WMH_SYNTHSEG_DEVICE="cpu"        # "cpu" or a GPU id (e.g. "0") passed to --device
# ===========================================================================

# ---------------------------------------------------------------------------
# Deep-learning WMH detection - segcsvdWMH (AICONSlab)   (src/modules/wmh_segcsvd.sh)
# ---------------------------------------------------------------------------
# segcsvdWMH is a two-stage CNN for quantifying WMH in heterogeneous cohorts
# (Gibson et al., Human Brain Mapping 2024;45(18):e70104, DOI 10.1002/hbm.70104;
# https://github.com/AICONSlab/segcsvd).  It is FLAIR-ONLY for the lesion CNN
# (T1 is used only for upstream SynthSeg / ICV) and ships pretrained weights,
# most conveniently as the AICONSlab container (Apptainer/Singularity .sif, or
# Docker).  It requires a FreeSurfer SynthSeg v2 (with CSF) parcellation of the
# subject as a second input; the module builds this with 'mri_synthseg' when one
# is not supplied.
#
# DEFAULT OFF: with no container image / module and no SynthSeg available, the
# module logs a clear warning and skips gracefully (non-fatal).  Enable only
# once you have the segcsvd container (and FreeSurfer for SynthSeg) installed.
#
# Entry point: run_segcsvd_wmh <flair> [t1] [out_dir]
export WMH_SEGCSVD_ENABLED=false         # master switch; true = run segcsvdWMH in analysis stage

# --- Tool location (choose ONE back-end; all empty/absent = graceful skip) ---
# Apptainer/Singularity .sif image (preferred distribution form). Absolute path.
export SEGCSVD_CONTAINER_IMAGE=""        # e.g. /opt/segcsvd/segcsvd_rc03.sif
# Docker image tag (used only if the .sif above is unset/absent and the image is
# present locally, e.g. after 'docker pull'/'docker load').
export SEGCSVD_DOCKER_IMAGE="segcsvd_rc03"
# Native Python module name (last-resort back-end, invoked via 'uv run python -m').
# Leave empty unless you have segcsvd importable in the uv environment.
export SEGCSVD_PY_MODULE=""

# --- SynthSeg parcellation (required second input) --------------------------
# Optional precomputed SynthSeg v2 (with CSF) parcellation. When set + present,
# it is reused instead of running mri_synthseg.
export SEGCSVD_SYNTHSEG_FILE=""          # e.g. /data/sub01/synthseg.nii.gz
# Extra flags appended to 'mri_synthseg --i ... --o ...' (word-split; e.g. "--robust --parc").
export SEGCSVD_SYNTHSEG_EXTRA_OPTS=""

# --- segcsvdWMH parameters --------------------------------------------------
export SEGCSVD_THRESHOLD=0.35            # WMH probability threshold -> binary mask (0-1; tool default 0.35)
export SEGCSVD_PATCH_SIZE="96,128"       # CNN patch-size spec passed to segment_wmh (tool default)
export SEGCSVD_SKIP_MASK_AND_BIAS=false  # 'skip_mask_and_bias' positional flag (true skips brain mask + bias correction)
export SEGCSVD_CLEANUP=true              # 'cleanup' positional flag (remove container temp files) AND remove the module's input-staging copies after the run
# Extra args appended to the native-module invocation (word-split; module back-end only).
export SEGCSVD_MODULE_EXTRA_OPTS=""

# ===========================================================================
# EXPLORATORY brainstem arousal-network nuclei (FreeSurfer AANSegment)
#   module: src/modules/brainstem_aanseg.sh   entry fn: run_aanseg
# ===========================================================================
# Olchanyi et al., "Automated MRI Segmentation of Brainstem Nuclei Critical to
# Consciousness," Human Brain Mapping 2025;46(14):e70357 (DOI 10.1002/hbm.70357).
# FreeSurfer-shipped 'SegmentAAN.sh' Bayesian segmenter of ~10 brainstem AAN
# nuclei (DR, MnR, LC, LDTg, PTg, parabrachial, PnO, midbrain RF, VTA, PAG).
#
# *** EXPLORATORY / RESEARCH-ONLY. DEFAULT OFF. ***  Honor these caveats:
#   1. Reliable ONLY at <= 1 mm input resolution. Clinical FLAIR slice thickness
#      (3-5 mm) gives UNRELIABLE volumetrics - the module warns and skips.
#   2. License CC BY-NC-ND 4.0 (NON-COMMERCIAL, NO DERIVATIVES): we only INVOKE
#      the FreeSurfer tool; we never modify or redistribute it.
#   3. Degrades on large brainstem lesions - interpret with extreme caution.
# Requires FreeSurfer + a FreeSurfer license + a prior 'recon-all' for the
# subject (the module never runs the hours-long recon-all itself). Absence of any
# dependency is a graceful, non-fatal skip.
export BRAINSTEM_AANSEG_ENABLED=false    # master switch; true = run AANSegment (EXPLORATORY)
export AANSEG_MAX_VOXEL_MM=1.0           # max per-axis voxel size (mm); coarser => unreliable
export AANSEG_SKIP_IF_COARSE=true        # true => skip when input is coarser than the limit
export AANSEG_WRITE_REGION_MASKS=false   # true => also stage nuclei labels under segmentation/ (NOT wired into analysis)
# Path overrides (empty = auto-detect). SegmentAAN.sh / FS license / subjects dir.
export AANSEG_SUBJECTS_DIR=""            # optional explicit FreeSurfer SUBJECTS_DIR with the recon
export AANSEG_OUTPUT_DIR=""              # optional explicit output dir (default: RESULTS_DIR/brainstem_aanseg)

# ---------------------------------------------------------------------------
# Small-lesion WMH detection - SHIVA-WMH  (src/modules/wmh_shiva.sh)
# ---------------------------------------------------------------------------
# SHIVA-WMH is a 3D U-Net trained specifically for SMALL / PUNCTATE white-matter
# hyperintensities (Tran et al., Human Brain Mapping 2024;45(1):e26548, DOI
# 10.1002/hbm.26548). It is a HIGH-SENSITIVITY / LOWER-SPECIFICITY detector:
# unlike BIANCA / LST-AI / SAMSEG (tuned for confluent lesions), it is designed
# to catch early, punctate WMH. Because it over-detects to maximise sensitivity,
# its output is meant to be PAIRED WITH THE FP FILTER for specificity — the
# pipeline's CSF / partial-volume + cortical-ribbon exclusion (analysis.sh) and
# the brainstem-mask intersection performed by the module remove the spurious
# small clusters SHIVA flags.
#
# Inputs: co-registered T1 + FLAIR (FLAIR aligned to T1); output is in T1 space.
# Two back-ends, antspynet preferred for simplicity:
#   - antspynet : `antspynet.shiva_wmh_segmentation(flair, t1=...)` (Python; ships
#                 pretrained SHIVA weights, downloaded on first use). Install via
#                 'uv add antspynet'. Run probe: uv run python -c "import antspynet".
#   - container : the SHiVAi framework container (Docker/Apptainer);
#                 https://github.com/pboutinaud/SHiVAi
#
# DEFAULT OFF: antspynet is NOT in the core dependency set, and the SHIVA weights
# need download (and benefit from a GPU). With no back-end installed the module
# logs a clear warning and skips gracefully (non-fatal).
#
# Entry point: run_shiva_wmh <flair> <t1> [out_dir]
export WMH_SHIVA_ENABLED=false           # master switch; true = run SHIVA-WMH in analysis stage

# Back-end selection: "auto" (prefer antspynet, then container), "antspynet", or "container".
export SHIVA_WMH_BACKEND="auto"

# antspynet options
export SHIVA_WMH_MODEL="all"             # which_model: "all" (ensemble) or a fold index 0-4
export SHIVA_WMH_VERBOSE=true            # print antspynet/segmentation progress

# Thresholding / post-processing
export SHIVA_WMH_THRESHOLD=0.5           # probability-map threshold -> binary WMH mask (0-1; SHIVA default 0.5)
export SHIVA_WMH_MIN_CLUSTER_SIZE=0      # drop WMH clusters below this many voxels (0 = off; first-line FP guard)

# SHiVAi container options (only used when the container back-end is selected)
export SHIVA_WMH_CONTAINER_IMAGE=""      # Docker image name OR path to an Apptainer/Singularity .sif
export SHIVA_WMH_CONTAINER_RUNTIME="auto" # "auto" | "docker" | "apptainer" | "singularity"
# Full in-container processing command (the SHiVAi CLI varies by version). Use
# placeholders {FLAIR} {T1} {OUTDIR} {IMAGE}; executed verbatim via eval, e.g.:
#   docker run --rm -v {OUTDIR}:/out ... {IMAGE} shiva --in {FLAIR} ... --out /out
export SHIVA_WMH_CONTAINER_CMD=""

# ===========================================================================
# Deep-learning WMH detection - MARS-WMH        (src/modules/wmh_mars.sh)
# ===========================================================================
# MARS-WMH (Gesierich et al., Cereb Circ Cogn Behav 2025;9:100393,
# DOI 10.1016/j.cccb.2025.100393) is an nnU-Net / MD-GRU deep-learning WMH
# segmentation tool from MIAC. It is the best-validated WMH tool in the
# literature for scan-rescan, inter-scanner, and longitudinal robustness.
# Inputs co-registered FLAIR + T1; produces a whole-brain WMH mask. The module
# intersects that mask with the brainstem ROI (a MARS-brainstem ROI if available,
# else the pipeline's *brainstem*mask*.nii.gz) for a brainstem-restricted burden.
#
# !! NON-COMMERCIAL LICENSE !!  MARS-WMH and MARS-brainstem
# (https://github.com/miac-research/MARS-WMH, .../dl-brainstem) ship as prebuilt
# Docker/Apptainer containers under a NON-COMMERCIAL license. They are NOT part
# of the core dependency set and NOT installed by `uv sync`. Obtaining/running
# them is the operator's responsibility, subject to that license.
#
# DEFAULT OFF: with no container/CLI present the module logs a clear warning and
# skips gracefully (non-fatal). Enable only after pulling the container.
#
# Entry point: run_mars_wmh <flair.nii.gz> <t1.nii.gz> [<out_dir>]
export WMH_MARS_ENABLED=false             # master switch; true = run MARS-WMH

# --- Back-end selection / images --------------------------------------------
# "auto" tries Docker image, then an Apptainer .sif, then a native CLI.
# Force a single back-end with "docker" | "apptainer" | "cli".
export MARS_WMH_BACKEND="auto"
export MARS_WMH_DOCKER_IMAGE="miac/mars-wmh:latest"  # Docker image tag (adjust to your pull)
export MARS_WMH_SIF=""                    # path to an Apptainer/Singularity .sif image
export MARS_WMH_CLI="mars-wmh"            # native CLI name on PATH (if installed)
export MARS_WMH_DOCKER_OPTS=""            # extra `docker run` opts (e.g. "--gpus all")
export MARS_WMH_APPTAINER_OPTS=""         # extra apptainer/singularity run opts (e.g. "--nv")

# --- Thresholding ------------------------------------------------------------
export MARS_WMH_THRESHOLD=0.5             # prob-map threshold -> binary WMH mask (0-1)

# --- Optional MARS-brainstem ROI (preferred over the pipeline brainstem mask) -
# When enabled and available, MARS-brainstem defines the brainstem ROI used for
# the WMH intersection; otherwise the module falls back to the pipeline mask.
export MARS_BRAINSTEM_ENABLED=false       # true = try MARS-brainstem to build the ROI
export MARS_BRAINSTEM_ROI=""              # explicit pre-computed brainstem ROI (takes precedence)
export MARS_BRAINSTEM_DOCKER_IMAGE="miac/dl-brainstem:latest"  # MARS-brainstem Docker image
export MARS_BRAINSTEM_SIF=""              # path to a MARS-brainstem Apptainer .sif image
export MARS_BRAINSTEM_CLI="mars-brainstem"  # native MARS-brainstem CLI name on PATH
export MARS_BRAINSTEM_DOCKER_OPTS=""      # extra `docker run` opts for MARS-brainstem
export MARS_BRAINSTEM_APPTAINER_OPTS=""   # extra apptainer/singularity run opts for MARS-brainstem

# Reference templates from FSL or other sources
if [ -z "${FSLDIR:-}" ]; then
  log_formatted "WARNING" "FSLDIR not set. Template references may fail."
else
  export TEMPLATE_DIR="${FSLDIR}/data/standard"
fi
# Template resolutions - these can be automatically selected based on input resolution
export TEMPLATE_RESOLUTIONS=("1mm" "2mm")

# Templates for different resolutions
export EXTRACTION_TEMPLATE_1MM="MNI152_T1_1mm.nii.gz"
export PROBABILITY_MASK_1MM="MNI152_T1_1mm_brain_mask.nii.gz"
export REGISTRATION_MASK_1MM="MNI152_T1_1mm_brain_mask_dil.nii.gz"

export EXTRACTION_TEMPLATE_2MM="MNI152_T1_2mm.nii.gz"
export PROBABILITY_MASK_2MM="MNI152_T1_2mm_brain_mask.nii.gz"
export REGISTRATION_MASK_2MM="MNI152_T1_2mm_brain_mask_dil.nii.gz"
export DISABLE_DEDUPLICATION="false"

# Set initial defaults (will be updated based on detected image resolution)
export EXTRACTION_TEMPLATE="$EXTRACTION_TEMPLATE_1MM"
export PROBABILITY_MASK="$PROBABILITY_MASK_1MM"
export REGISTRATION_MASK="$REGISTRATION_MASK_1MM"

# ------------------------------------------------------------------------------
# Brain extraction method & parameters
# ------------------------------------------------------------------------------
# Preferred brain extraction method. The pipeline tries this method first and
# falls back gracefully to the next available method if the tool is missing or
# fails. Fallback order is always: synthstrip -> ants -> bet.
#   synthstrip - FreeSurfer mri_synthstrip (contrast-agnostic deep-learning
#                skull-strip; current best practice for T1/FLAIR/SWI/DWI and the
#                safest choice for brainstem/cerebellum preservation)
#   ants       - template-free N4 -> Otsu -> largest-component -> morphology path
#   bet        - FSL BET with robustfov neck removal + modality-specific -f
export BRAIN_EXTRACTION_METHOD="synthstrip"

# Radius (in voxels) for the morphological open (dilate then erode) in the ANTs
# Otsu fallback path. The legacy value of 4 is aggressive at 1mm and can sever
# the brainstem->cord taper or round off the pons; 1-2 is gentler and preserves
# the posterior fossa.
export BRAIN_MASK_MORPH_RADIUS=1

# Modality-specific BET fractional intensity thresholds (-f). Lower values keep
# more brain (important for FLAIR/T2 where BET tends to over-strip). T1 uses a
# slightly higher value than the bare 0.5 default which clipped the cerebellum.
export BET_F_T1=0.3
export BET_F_FLAIR=0.2

# Posterior-fossa QC gate: minimum fraction of brain-mask voxels expected to lie
# in the inferior portion of the volume (cerebellum/brainstem region). If the
# observed fraction falls below this, the mask is flagged as possibly clipped.
# Even SynthStrip drops the cerebellum in ~1/3 of T2 cases, so this is a warning
# (non-fatal) sanity check, not a hard failure.
export BRAIN_QC_INFERIOR_FRACTION=0.06

# Shared robustfov FOV-normalization (neck/large-FOV removal) applied as a
# pre-extraction step for ALL methods (synthstrip/ants/bet), not just the BET
# fallback. On large-FOV sagittal 3D inputs (T1_MPRAGE_SAG, T2_SPACE_FLAIR_Sag)
# the neck and shoulders drag skull-strip centres of mass too low; cropping the
# FOV first improves extraction and downstream registration. The brain mask is
# extracted on the cropped image, then mapped BACK to the original full grid via
# the inverse of robustfov's ROI->full affine, so the final brain/mask outputs
# stay in the ORIGINAL native space and geometry (nothing downstream shifts).
# Requires FSL robustfov; if unavailable, the pipeline logs a non-fatal skip and
# extracts on the original image (legacy behaviour).
export BRAIN_EXTRACTION_ROBUSTFOV=true

# Heuristic gate for the robustfov pre-step. When >0, FOV cropping only triggers
# if the superior-inferior (Z) extent in mm (dim3 * pixdim3) exceeds this value,
# which targets the large-FOV sagittal slabs while leaving already-tight axial
# acquisitions untouched. Set to 0 to apply the crop unconditionally whenever
# BRAIN_EXTRACTION_ROBUSTFOV is enabled and robustfov is available.
export BRAIN_EXTRACTION_ROBUSTFOV_MIN_Z_MM=180

# Supported modalities for registration to T1
export SUPPORTED_MODALITIES=("FLAIR" "SWI" "DWI" "TLE" "COR")

# Batch processing parameters
export  SUBJECT_LIST=""  # Path to subject list file for batch processing

# ------------------------------------------------------------------------------
# DICOM File Pattern Configuration (used by import.sh and qa.sh)
# ------------------------------------------------------------------------------

# Space-separated list of additional patterns to try for different vendors:
# - *.dcm: Standard DICOM extension (all vendors)
# - IM_*: Philips format
# - Image*: Siemens format
# - *.[0-9][0-9][0-9][0-9]: Numbered format (GE and others)
# - DICOM*: Generic DICOM prefix
export DICOM_ADDITIONAL_PATTERNS="*.dcm IM_* Image* *.[0-9][0-9][0-9][0-9] DICOM*"

# Prioritize sagittal 3D sequences - these patterns match Siemens file naming conventions
# after DICOM to NIfTI conversion with dcm2niix

export T1_PRIORITY_PATTERN="T1_MPRAGE_SAG_12.nii.gz" #hack
export FLAIR_PRIORITY_PATTERN="T2_SPACE_FLAIR_Sag_CS_17.nii.gz" #hack
export RESAMPLE_TO_ISOTROPIC=false
#export ISOTROPIC_SPACING=1.0
#unset ISOTROPIC_SPACING

# ------------------------------------------------------------------------------
# Modality-aware denoising routing
# ------------------------------------------------------------------------------
# The denoising dispatcher (dispatch_denoising in preprocess.sh) selects the
# denoising method by detected modality:
#   T1 / T2 / FLAIR  -> Rician Non-Local-Means (DenoiseImage)         [default]
#   DWI / diffusion  -> MP-PCA (dwidenoise, MRtrix); NLM is INVALID for DWI
#   SWI / TOF / angio -> SKIPPED by default (NLM smears microbleeds/vessels)
#
# When set to true, applies a gentle Rician NLM to SWI/TOF images instead of
# skipping.  Leave false to preserve microbleeds (SWI) and small vessels (TOF).
export SWI_TOF_DENOISE_ENABLED=false
# When the modality cannot be detected, skip denoising instead of defaulting to
# NLM.  Default false keeps the historical structural-assumption behaviour.
export DENOISE_DEFAULT_SKIP=false

# ------------------------------------------------------------------------------
# DWI (diffusion) preprocessing path  (dwi_preprocess.sh)
# ------------------------------------------------------------------------------
# Master switch.  When false (default) the DWI path is never invoked and the
# existing T1/FLAIR flow is completely unaffected.  When true, DWI inputs are
# auto-detected in the preprocessing stage and routed through the MP-PCA path.
export PROCESS_DWI=false
# Optional Gibbs ringing removal (mrdegibbs) after MP-PCA denoising.
export DWI_DEGIBBS=true
# Bias-field correction for DWI: "ants" uses `dwibiascorrect ants`; otherwise an
# N4 fallback is applied to the mean b0/DWI volume.  Set DWI_BIAS_CORRECT=false
# to skip bias correction entirely.
export DWI_BIAS_CORRECT=true
export DWI_BIAS_METHOD="ants"
# Eddy/motion/topup (dwifslpreproc) is OPTIONAL and OFF by default: it requires
# acquisition parameters (phase-encode direction + readout time) and gradient
# tables.  To enable, set DWI_RUN_EDDY=true and provide DWI_PE_DIR (e.g. "j-")
# and DWI_READOUT_TIME (seconds) plus accompanying .bvec/.bval files.
export DWI_RUN_EDDY=false
export DWI_PE_DIR=""
export DWI_READOUT_TIME=""

# Scan selection options
# Available modes:
#   original - ONLY consider ORIGINAL acquisitions, ignore DERIVED scans
#   highest_resolution - Prioritize scans with highest resolution (default)
#   registration_optimized - Prioritize scans with aspect ratios similar to reference
#   matched_dimensions - Prioritize scans with exact dimensions matching reference
#   interactive - Show available scans and prompt for manual selection
export SCAN_SELECTION_MODE="original"
export T1_SELECTION_MODE="original"       # Prefer ORIGINAL acquisitions over DERIVED
export FLAIR_SELECTION_MODE="original"    # Prefer ORIGINAL acquisitions over DERIVED

# Advanced registration options

# Auto-register all modalities to T1 (if false, only FLAIR is registered)
export AUTO_REGISTER_ALL_MODALITIES=false

# Auto-detect resolution and use appropriate template
# When true, the pipeline will select between 1mm and 2mm templates based on input image resolution
export AUTO_DETECT_RESOLUTION=true

# Additional vendor-specific optimizations are applied automatically
# based on the metadata extracted during import (field strength, manufacturer, model)

# ------------------------------------------------------------------------------
# Orientation and Datatype Parameters
# ------------------------------------------------------------------------------

# Orientation correction settings
export ORIENTATION_CORRECTION_ENABLED=false   # Disable automatic orientation correction
export ORIENTATION_VALIDATION_ENABLED=false   # Disable validation
export orientation_preservation=false
export HALT_ON_ORIENTATION_MISMATCH=true # Halt pipeline on orientation mismatch (if validation enabled)

# Expected orientation for validation
export EXPECTED_QFORM_X="Left-to-Right"
export EXPECTED_QFORM_Y="Posterior-to-Anterior"
export EXPECTED_QFORM_Z="Inferior-to-Superior"

# Datatype configuration
export PRESERVE_INTENSITY_IMAGES_DATATYPE=true  # Keep intensity images as FLOAT32
export CONVERT_MASKS_TO_UINT8=true  # Convert binary masks to UINT8

#export ORIGINAL_ACQUISITION_WEIGHT=1000

# NOTE: FLAIR-specific N4 fields (N4_ITERATIONS_FLAIR/.../N4_SHRINK_FLAIR) are
# parsed and exported once in the N4 preset section above. The duplicate
# non-exported parse that used to live here has been removed to keep a single
# source of truth for the N4 -b convention.

# White matter guided registration parameters
export WM_GUIDED_DEFAULT=true  # Default to use white matter guided registration
export WM_INIT_TRANSFORM_PREFIX="_wm_init"  # Prefix for WM-guided initialization transforms
export WM_MASK_SUFFIX="_wm_mask.nii.gz"  # Suffix for white matter mask files
export WM_THRESHOLD_VAL=3  # Threshold value for white matter segmentation (class 3 in Atropos)

# Orientation distortion correction parameters
# Main toggle
export ORIENTATION_PRESERVATION_ENABLED=true

# Topology preservation parameters
export TOPOLOGY_CONSTRAINT_WEIGHT=0.5
export TOPOLOGY_CONSTRAINT_FIELD="1x1x1"

# Jacobian regularization parameters
export JACOBIAN_REGULARIZATION_WEIGHT=1.0
export REGULARIZATION_GRADIENT_FIELD_WEIGHT=0.5

# Correction thresholds
export ORIENTATION_CORRECTION_THRESHOLD=0.3
export ORIENTATION_SCALING_FACTOR=0.05
export ORIENTATION_SMOOTH_SIGMA=1.5

# Quality assessment thresholds
export ORIENTATION_EXCELLENT_THRESHOLD=0.1
export ORIENTATION_GOOD_THRESHOLD=0.2
export ORIENTATION_ACCEPTABLE_THRESHOLD=0.3
export SHEARING_DETECTION_THRESHOLD=0.05

# NOTE: MIN_HYPERINTENSITY_SIZE is set in the hyperintensity detection block above (line ~190)
# Do not re-export here to avoid silent overrides.

# Tissue segmentation parameters
export ATROPOS_T1_CLASSES=3
export ATROPOS_FLAIR_CLASSES=4
export ATROPOS_CONVERGENCE="5,0.0"
export ATROPOS_MRF="[0.1,1x1x1]"
export ATROPOS_INIT_METHOD="kmeans"

# Cropping & padding
export PADDING_X=5
export PADDING_Y=5
export PADDING_Z=5
export C3D_CROP_THRESHOLD=0.1
export C3D_PADDING_MM=5
