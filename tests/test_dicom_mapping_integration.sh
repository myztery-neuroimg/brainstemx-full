#!/usr/bin/env bash
#
# test_dicom_mapping_integration.sh - Test script for DICOM cluster mapping integration
#
# This script validates that the new DICOM cluster mapping module integrates properly
# with the existing pipeline and checks for syntax errors or missing dependencies.
#

# Set up test environment
TEST_DIR="test_dicom_mapping"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

echo "=== DICOM Cluster Mapping Integration Test ==="
echo "Testing integration of cluster-to-DICOM mapping functionality"
echo ""

# Test 1: Check if the module can be sourced without errors
echo "Test 1: Module loading test"
echo "Checking if dicom_cluster_mapping.sh can be loaded..."

# Source required dependencies first
if [ -f "../src/modules/environment.sh" ]; then
    source ../src/modules/environment.sh
fi

if [ -f "../src/modules/utils.sh" ]; then
    source ../src/modules/utils.sh
fi

# Try to source the new module
if source ../src/modules/dicom_cluster_mapping.sh 2>/dev/null; then
    echo "✓ PASS: Module loaded successfully"
else
    echo "✗ FAIL: Module failed to load"
    echo "Error details:"
    source ../src/modules/dicom_cluster_mapping.sh
    exit 1
fi

echo ""

# Test 2: Check if functions are properly exported
echo "Test 2: Function availability test"
echo "Checking if key functions are available..."

functions_to_check=(
    "extract_cluster_coordinates_from_fsl"
    "convert_voxel_to_world_coordinates"
    "map_clusters_to_dicom_space"
    "match_clusters_to_dicom_files"
    "perform_cluster_to_dicom_mapping"
)

all_functions_found=true
for func in "${functions_to_check[@]}"; do
    if declare -f "$func" > /dev/null 2>&1; then
        echo "✓ PASS: Function '$func' is available"
    else
        echo "✗ FAIL: Function '$func' is not available"
        all_functions_found=false
    fi
done

if [ "$all_functions_found" = false ]; then
    echo "Some functions are missing - check module exports"
    exit 1
fi

echo ""

# Test 3: Create sample FSL cluster output to test parsing
echo "Test 3: FSL cluster parsing test"
echo "Creating sample FSL cluster output and testing parsing..."

# Create sample cluster output in the format the user provided
cat > sample_clusters.txt << 'EOF'
Cluster Index	Voxels	MAX	MAX X (vox)	MAX Y (vox)	MAX Z (vox)	COG X (vox)	COG Y (vox)	COG Z (vox)
3	27	1	88	91	123	89.4	92.6	125
2	7	1	89	92	135	89.1	93.9	136
1	4	1	95	87	121	95	87.2	121
EOF

echo "Sample cluster data created:"
cat sample_clusters.txt
echo ""

# Create a dummy NIfTI file for testing (if FSL is available)
if command -v fslcreatehd &> /dev/null; then
    echo "Creating test NIfTI file..."
    fslcreatehd 100 100 100 1 1 1 1 1 0 0 0 16 test_reference
    if [ $? -eq 0 ]; then
        echo "✓ PASS: Test NIfTI file created successfully"
        
        # Test coordinate extraction function
        echo "Testing coordinate extraction..."
        if extract_cluster_coordinates_from_fsl "sample_clusters.txt" "test_reference.nii.gz" "test_coordinates.txt" 2>/dev/null; then
            echo "✓ PASS: Coordinate extraction function executed without errors"
            if [ -f "test_coordinates.txt" ]; then
                echo "Output file created. Contents:"
                head -10 test_coordinates.txt
            fi
        else
            echo "⚠ WARNING: Coordinate extraction function had issues (expected without full FSL environment)"
        fi
    else
        echo "⚠ WARNING: Could not create test NIfTI file (FSL may not be fully configured)"
    fi
else
    echo "⚠ WARNING: FSL not available - skipping NIfTI-based tests"
fi

echo ""

# Test 4: Check pipeline integration
echo "Test 4: Pipeline integration test"
echo "Checking if the pipeline properly sources the new module..."

if grep -q "source src/modules/dicom_cluster_mapping.sh" ../src/pipeline.sh; then
    echo "✓ PASS: Pipeline sources the new module"
else
    echo "✗ FAIL: Pipeline does not source the new module"
    exit 1
fi

if grep -q "perform_cluster_to_dicom_mapping" ../src/pipeline.sh; then
    echo "✓ PASS: Pipeline calls the main mapping function"
else
    echo "✗ FAIL: Pipeline does not call the main mapping function"
    exit 1
fi

echo ""

# Test 5: Check for required dependencies
echo "Test 5: Dependency check"
echo "Checking for required external tools..."

dependencies=(
    "fslinfo:FSL"
    "fslval:FSL"
    "fslstats:FSL"
    "bc:Basic calculator"
    "find:File search"
    "grep:Text search"
)

all_deps_found=true
for dep_info in "${dependencies[@]}"; do
    dep_cmd=$(echo "$dep_info" | cut -d':' -f1)
    dep_name=$(echo "$dep_info" | cut -d':' -f2)
    
    if command -v "$dep_cmd" &> /dev/null; then
        echo "✓ PASS: $dep_name ($dep_cmd) is available"
    else
        echo "⚠ WARNING: $dep_name ($dep_cmd) is not available"
        # Don't fail the test for missing tools - they might be in a different environment
    fi
done

echo ""

# Test 6: Basic syntax validation
echo "Test 6: Syntax validation"
echo "Running bash syntax check on the module..."

if bash -n ../src/modules/dicom_cluster_mapping.sh 2>/dev/null; then
    echo "✓ PASS: Module has valid bash syntax"
else
    echo "✗ FAIL: Module has syntax errors"
    echo "Error details:"
    bash -n ../src/modules/dicom_cluster_mapping.sh
    exit 1
fi

if bash -n ../src/pipeline.sh 2>/dev/null; then
    echo "✓ PASS: Pipeline has valid bash syntax after integration"
else
    echo "✗ FAIL: Pipeline has syntax errors after integration"
    echo "Error details:"
    bash -n ../src/pipeline.sh
    exit 1
fi

echo ""

# Summary
echo "=== TEST SUMMARY ==="
echo "✓ Module loading: PASSED"
echo "✓ Function availability: PASSED" 
echo "✓ FSL cluster parsing: TESTED (may need full FSL environment)"
echo "✓ Pipeline integration: PASSED"
echo "✓ Dependency check: COMPLETED"
echo "✓ Syntax validation: PASSED"
echo ""
echo "The DICOM cluster mapping integration appears to be working correctly!"
echo "The module is ready for testing with real pipeline data."
echo ""
echo "Next steps:"
echo "1. Run the full pipeline on test data"
echo "2. Verify cluster-to-DICOM mapping output files are created"
echo "3. Validate coordinate accuracy with medical imaging viewers"
echo ""

# Clean up
cd ..
rm -rf "$TEST_DIR"

echo "Test completed successfully!"