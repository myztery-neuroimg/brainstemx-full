#!/usr/bin/env bash
#
# run_example.sh - Example script to run the brain MRI processing pipeline
#
# This script demonstrates how to run the pipeline with different options.
#

# Make the script executable if it's not already
chmod +x pipeline.sh

# Example 1: Basic usage with default options
echo "Example 1: Basic usage with default options"
echo "./pipeline.sh"
echo ""

# Example 2: Specify input and output directories
echo "Example 2: Specify input and output directories"
echo "./pipeline.sh -i /path/to/dicom -o /path/to/output"
echo ""

# Example 3: Specify subject ID and quality preset
echo "Example 3: Specify subject ID and quality preset"
echo "./pipeline.sh -i /path/to/dicom -o /path/to/output -s subject_id -q HIGH"
echo ""

# Example 4: Use a custom configuration file
echo "Example 4: Use a custom configuration file"
echo "./pipeline.sh -c /path/to/custom_config.sh"
echo ""

# Example 5: Batch processing with a subject list
echo "Example 5: Batch processing with a subject list"
echo "# First, create a subject list file (subject_list.txt):"
echo "# subject_id1 /path/to/flair1.nii.gz /path/to/t1_1.nii.gz"
echo "# subject_id2 /path/to/flair2.nii.gz /path/to/t1_2.nii.gz"
echo ""
echo "# Then run the pipeline in batch mode:"
echo "export SUBJECT_LIST=/path/to/subject_list.txt"
echo "./pipeline.sh -p BATCH -i /path/to/base_dir -o /path/to/output_base"
echo ""

# Example 6: Run the pipeline on a test dataset
echo "Example 6: Run the pipeline on a test dataset"
echo "# If you have a test dataset in ./test_data/dicom:"
echo "./pipeline.sh -i ./test_data/dicom -o ./test_data/results -s test_subject"
echo ""

# Make this script executable
chmod +x run_example.sh

echo "This script provides examples of how to run the pipeline."
echo "To actually run one of these examples, copy and paste the command into your terminal."
echo ""
echo "For more information, run: ./pipeline.sh --help"