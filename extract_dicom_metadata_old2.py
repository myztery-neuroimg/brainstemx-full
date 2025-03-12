#!/usr/bin/env python3
"""
Extract metadata from DICOM files, particularly optimized for Siemens MAGNETOM Sola scanner.
This script extracts key parameters needed for optimizing MRI processing pipelines.

Usage:
    python extract_dicom_metadata.py <input_dicom_file> <output_json_file>
"""

import sys
import json
import os

def extract_metadata(dicom_path, output_path):
    """Extract metadata from a DICOM file and save it as JSON."""
    try:
        import pydicom
        
        # Read the DICOM file
        dcm = pydicom.dcmread(dicom_path)
        
        # Create metadata dictionary
        metadata = {}
        
        # Basic scanner information
        if hasattr(dcm, 'Manufacturer'):
            metadata['manufacturer'] = dcm.Manufacturer
        if hasattr(dcm, 'ManufacturerModelName'):
            metadata['modelName'] = dcm.ManufacturerModelName
        if hasattr(dcm, 'MagneticFieldStrength'):
            metadata['fieldStrength'] = float(dcm.MagneticFieldStrength)
            
        # Sequence information
        if hasattr(dcm, 'ProtocolName'):
            metadata['protocolName'] = dcm.ProtocolName
        if hasattr(dcm, 'SeriesDescription'):
            metadata['seriesDescription'] = dcm.SeriesDescription
        if hasattr(dcm, 'SequenceName'):
            metadata['sequenceName'] = dcm.SequenceName
        if hasattr(dcm, 'ScanningSequence'):
            metadata['scanningSequence'] = dcm.ScanningSequence
        if hasattr(dcm, 'SequenceVariant'):
            metadata['sequenceVariant'] = dcm.SequenceVariant
            
        # Acquisition parameters
        if hasattr(dcm, 'SliceThickness'):
            metadata['sliceThickness'] = float(dcm.SliceThickness)
        if hasattr(dcm, 'RepetitionTime'):
            metadata['TR'] = float(dcm.RepetitionTime)
        if hasattr(dcm, 'EchoTime'):
            metadata['TE'] = float(dcm.EchoTime)
        if hasattr(dcm, 'FlipAngle'):
            metadata['flipAngle'] = float(dcm.FlipAngle)
        if hasattr(dcm, 'SpacingBetweenSlices'):
            metadata['spacingBetweenSlices'] = float(dcm.SpacingBetweenSlices)
        
        # Pixel dimensions
        if hasattr(dcm, 'PixelSpacing'):
            metadata['pixelSpacing'] = [float(x) for x in dcm.PixelSpacing]
        
        # Special case for Siemens MAGNETOM Sola
        if hasattr(dcm, 'ManufacturerModelName') and 'MAGNETOM Sola' in dcm.ManufacturerModelName:
            metadata['isMagnetomSola'] = True
            
            # Extract any Siemens-specific parameters if available
            try:
                # Some Siemens scanners store additional parameters in private tags
                if hasattr(dcm, 'Private_0029_1010'):
                    metadata['hasSiemensCSAHeader'] = True
            except:
                pass
        
        # Write to JSON file
        with open(output_path, 'w') as f:
            json.dump(metadata, f, indent=2)
            
        print("SUCCESS")
        return 0
        
    except ImportError:
        # pydicom not available
        with open(output_path, 'w') as f:
            json.dump({
                "manufacturer": "Unknown",
                "fieldStrength": 3,
                "modelName": "Unknown",
                "error": "pydicom module not installed"
            }, f, indent=2)
        print("PYDICOM_NOT_FOUND")
        return 1
        
    except Exception as e:
        # Handle other errors
        with open(output_path, 'w') as f:
            json.dump({
                "manufacturer": "Unknown", 
                "fieldStrength": 3,
                "modelName": "Unknown",
                "error": str(e)
            }, f, indent=2)
        print(f"ERROR: {str(e)}")
        return 2

if __name__ == "__main__":
    # Check command line arguments
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input_dicom_file> <output_json_file>")
        sys.exit(1)
        
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    # Verify input file exists
    if not os.path.isfile(input_file):
        print(f"ERROR: Input file '{input_file}' does not exist")
        sys.exit(1)
        
    # Extract metadata
    sys.exit(extract_metadata(input_file, output_file))
