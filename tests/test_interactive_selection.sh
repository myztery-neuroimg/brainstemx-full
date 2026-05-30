#!/bin/bash
source ~/.bash_profile
source ~/.bashrc
source src/modules/environment.sh
source src/modules/scan_selection.sh

echo "=== TESTING INTERACTIVE SCAN SELECTION ==="
echo "Available T1 files:"
find ../extracted_DICOM2 -name "*T1*.nii.gz" | head -5

echo ""
echo "=== Interactive T1 Selection ==="
# Test interactive selection for T1 files
echo "1" | select_best_scan "T1" "*T1*.nii.gz" "../extracted_DICOM2" "" "interactive"
