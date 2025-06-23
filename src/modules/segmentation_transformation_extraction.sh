#!/bin/bash
source src/modules/environment.sh
source src/config/default_config.sh

# Function to extract full 4x4 transformation matrix from NIfTI header
extract_transformation_matrix() {
    local nifti_file="$1"
    local matrix_type="${2:-sform}"  # "sform" or "qform"
    local output_format="${3:-array}" # "array", "ants", "fsl", or "itk"
    
    if [ ! -f "$nifti_file" ]; then
        log_formatted "ERROR" "NIfTI file not found: $nifti_file"
        return 1
    fi
    
    log_message "Extracting $matrix_type matrix from: $(basename "$nifti_file")"
    
    # Get FSL info output
    local fsl_info=$(fslinfo "$nifti_file" 2>/dev/null)
    if [ -z "$fsl_info" ]; then
        log_formatted "ERROR" "Cannot read NIfTI header from: $nifti_file"
        return 1
    fi
    
    # Extract matrix type code
    local matrix_code=$(echo "$fsl_info" | grep "^${matrix_type}_code" | awk '{print $2}')
    log_message "Matrix code: $matrix_code ($(get_coordinate_description "$matrix_code"))"
    
    if [ "$matrix_type" = "sform" ]; then
        # Extract sform matrix elements (stored as 3x4, we'll make it 4x4)
        local sxx=$(echo "$fsl_info" | grep "^srow_x" | awk '{print $2}')
        local sxy=$(echo "$fsl_info" | grep "^srow_x" | awk '{print $3}')
        local sxz=$(echo "$fsl_info" | grep "^srow_x" | awk '{print $4}')
        local sx_offset=$(echo "$fsl_info" | grep "^srow_x" | awk '{print $5}')
        
        local syx=$(echo "$fsl_info" | grep "^srow_y" | awk '{print $2}')
        local syy=$(echo "$fsl_info" | grep "^srow_y" | awk '{print $3}')
        local syz=$(echo "$fsl_info" | grep "^srow_y" | awk '{print $4}')
        local sy_offset=$(echo "$fsl_info" | grep "^srow_y" | awk '{print $5}')
        
        local szx=$(echo "$fsl_info" | grep "^srow_z" | awk '{print $2}')
        local szy=$(echo "$fsl_info" | grep "^srow_z" | awk '{print $3}')
        local szz=$(echo "$fsl_info" | grep "^srow_z" | awk '{print $4}')
        local sz_offset=$(echo "$fsl_info" | grep "^srow_z" | awk '{print $5}')
        
    elif [ "$matrix_type" = "qform" ]; then
        # Extract qform quaternion parameters and convert to matrix
        local qb=$(echo "$fsl_info" | grep "^quatern_b" | awk '{print $2}')
        local qc=$(echo "$fsl_info" | grep "^quatern_c" | awk '{print $2}')
        local qd=$(echo "$fsl_info" | grep "^quatern_d" | awk '{print $2}')
        local qx=$(echo "$fsl_info" | grep "^qoffset_x" | awk '{print $2}')
        local qy=$(echo "$fsl_info" | grep "^qoffset_y" | awk '{print $2}')
        local qz=$(echo "$fsl_info" | grep "^qoffset_z" | awk '{print $2}')
        local dx=$(echo "$fsl_info" | grep "^pixdim1" | awk '{print $2}')
        local dy=$(echo "$fsl_info" | grep "^pixdim2" | awk '{print $2}')
        local dz=$(echo "$fsl_info" | grep "^pixdim3" | awk '{print $2}')
        local qfac=$(echo "$fsl_info" | grep "^pixdim0" | awk '{print $2}')
        
        # Convert quaternion to rotation matrix using Python
        read sxx sxy sxz sx_offset syx syy syz sy_offset szx szy szz sz_offset < <(
            python3 << EOF
import math
# Quaternion to matrix conversion
qb, qc, qd = $qb, $qc, $qd
qa = math.sqrt(1.0 - qb*qb - qc*qc - qd*qd) if (qb*qb + qc*qc + qd*qd <= 1.0) else 0.0

# Rotation matrix from quaternion  
r11 = qa*qa + qb*qb - qc*qc - qd*qd
r12 = 2*(qb*qc - qa*qd)  
r13 = 2*(qb*qd + qa*qc)
r21 = 2*(qb*qc + qa*qd)
r22 = qa*qa + qc*qc - qb*qb - qd*qd
r23 = 2*(qc*qd - qa*qb)
r31 = 2*(qb*qd - qa*qc)
r32 = 2*(qc*qd + qa*qb) 
r33 = qa*qa + qd*qd - qb*qb - qc*qc

# Apply voxel scaling and qfac
dx, dy, dz, qfac = $dx, $dy, $dz, $qfac
if qfac < 0:
    r13, r23, r33 = -r13, -r23, -r33

sxx, sxy, sxz = dx*r11, dx*r12, dx*r13*qfac
syx, syy, syz = dy*r21, dy*r22, dy*r23*qfac  
szx, szy, szz = dz*r31, dz*r32, dz*r33*qfac
sx_offset, sy_offset, sz_offset = $qx, $qy, $qz

print(sxx, sxy, sxz, sx_offset, syx, syy, syz, sy_offset, szx, szy, szz, sz_offset)
EOF
        )
    else
        log_formatted "ERROR" "Unknown matrix type: $matrix_type"
        return 1
    fi
    
    # Validate we got numeric values
    local matrix_elements=($sxx $sxy $sxz $sx_offset $syx $syy $syz $sy_offset $szx $szy $szz $sz_offset)
    for element in "${matrix_elements[@]}"; do
        if ! [[ "$element" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            log_formatted "ERROR" "Invalid matrix element: $element"
            return 1
        fi
    done
    
    # Format output according to requested format
    case "$output_format" in
        "array")
            # 4x4 matrix as space-separated values (row-major)
            echo "$sxx $sxy $sxz $sx_offset $syx $syy $syz $sy_offset $szx $szy $szz $sz_offset 0 0 0 1"
            ;;
        "ants")
            # ANTs transformation file format
            cat << EOF
#Insight Transform File V1.0
Transform: AffineTransform_double_3_3
Parameters: $sxx $syx $szx $sxy $syy $szy $sxz $syz $szz $sx_offset $sy_offset $sz_offset
FixedParameters: 0 0 0
EOF
            ;;
        "fsl")
            # FSL transformation matrix format (4x4)
            cat << EOF
$sxx $sxy $sxz $sx_offset
$syx $syy $syz $sy_offset  
$szx $szy $szz $sz_offset
0 0 0 1
EOF
            ;;
        "itk")
            # ITK format
            echo "# ITK Transform File V1.0"
            echo "Transform: AffineTransform_double_3_3"
            echo "Parameters: $sxx $syx $szx $sxy $syy $szy $sxz $syz $szz $sx_offset $sy_offset $sz_offset"
            echo "FixedParameters: 0 0 0"
            ;;
        *)
            log_formatted "ERROR" "Unknown output format: $output_format"
            return 1
            ;;
    esac
    
    # Log matrix details for debugging
    log_message "Extracted transformation matrix ($matrix_type):"
    log_message "  Row 1: [$sxx, $sxy, $sxz, $sx_offset]"
    log_message "  Row 2: [$syx, $syy, $syz, $sy_offset]" 
    log_message "  Row 3: [$szx, $szy, $szz, $sz_offset]"
    log_message "  Row 4: [0, 0, 0, 1]"
    
    return 0
}

# Helper function for coordinate system descriptions
get_coordinate_description() {
    local code="$1"
    case "$code" in
        0) echo "Unknown/Arbitrary coordinates" ;;
        1) echo "Scanner Anatomical coordinates" ;;
        2) echo "Aligned Anatomical coordinates" ;;
        3) echo "Talairach coordinates" ;;
        4) echo "MNI 152 coordinates" ;;
        *) echo "Invalid code ($code)" ;;
    esac
}
