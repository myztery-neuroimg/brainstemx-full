#!/usr/bin/env python3
"""
DICOM metadata extraction script specifically designed for:
- Siemens files in ~/DICOM (Image-XXXXX format)
- Philips files in ~/DICOM2 (SE00000X/IM00000X format)

Extracts metadata and outputs as JSON.
"""

import sys
import json
import os
import logging
from pathlib import Path
import time

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

try:
    import pydicom
    HAS_PYDICOM = True
    logger.info("pydicom library found and imported successfully")
except ImportError:
    HAS_PYDICOM = False
    logger.warning("pydicom library not found, using basic metadata extraction")

def extract_metadata_basic(dicom_file):
    """
    Extract basic metadata without pydicom by examining filename patterns
    """
    logger.info(f"Using basic extraction for: {dicom_file}")
    
    # Default values - ALL as strings for consistency
    metadata = {
        "manufacturer": "Unknown",
        "fieldStrength": "1.5T",  # Default to 1.5T as string with unit
        "modelName": "Unknown",
        "studyDate": "",
        "seriesDescription": "",
        "source": "basic-extraction-fallback"
    }
    
    # We don't try to determine manufacturer from paths anymore - that's dangerous
    # Only used as a last resort fallback when DICOM reading fails completely
    logger.warning("Basic extraction doesn't attempt to determine manufacturer - using defaults")
    
    logger.info(f"Basic metadata extracted: {metadata['manufacturer']}")
    return metadata

def extract_siemens_metadata(dataset):
    """
    Extract Siemens-specific metadata
    """
    metadata = {}
    
    # Extract standard Siemens fields
    try:
        # Nothing needed here - field strength is now handled in the main extraction function
        
        # Protocol information
        if hasattr(dataset, 'ProtocolName'):
            metadata["protocolName"] = str(dataset.ProtocolName)
        
        # Sequence information
        if hasattr(dataset, 'SequenceName'):
            metadata["sequenceName"] = str(dataset.SequenceName)
            
        # Software version
        if hasattr(dataset, 'SoftwareVersions'):
            metadata["softwareVersion"] = str(dataset.SoftwareVersions)
            
    except Exception as e:
        logger.warning(f"Error extracting Siemens metadata: {e}")
    
    return metadata

def extract_philips_metadata(dataset):
    """
    Extract Philips-specific metadata
    """
    metadata = {}
    
    try:
        # Philips often has specific private tags
        # Extract what we can from standard tags
        if hasattr(dataset, 'StationName'):
            metadata["stationName"] = str(dataset.StationName)
            
        # Nothing needed here - field strength is now handled in the main extraction function
            
    except Exception as e:
        logger.warning(f"Error extracting Philips metadata: {e}")
    
    return metadata

def extract_metadata_pydicom(dicom_file):
    """
    Extract metadata using pydicom library
    """
    logger.info(f"Using pydicom to extract metadata from: {dicom_file}")
    
    try:
        # Read DICOM file
        dataset = pydicom.dcmread(dicom_file)
        
        # Extract common metadata - ALL as strings for consistency
        metadata = {
            "manufacturer": str(getattr(dataset, 'Manufacturer', "Unknown")),
            "fieldStrength": "1.5T",  # Default that will be overridden if available
            "modelName": str(getattr(dataset, 'ManufacturerModelName', "Unknown")),
            "studyDate": str(getattr(dataset, 'StudyDate', "")),
            "studyDescription": str(getattr(dataset, 'StudyDescription', "")),
            "seriesDescription": str(getattr(dataset, 'SeriesDescription', "")),
            "source": "pydicom"
        }
        
        # Try to get field strength from DICOM tags - save as STRING with units
        try:
            # Standard DICOM tag for Magnetic Field Strength (0018,0087)
            if hasattr(dataset, 'MagneticFieldStrength'):
                field_strength_value = float(dataset.MagneticFieldStrength)
                metadata["fieldStrength"] = f"{field_strength_value:.1f}T"
            # Try to access by tag number directly as a tuple (correct PyDICOM way)
            elif (0x0018, 0x0087) in dataset:
                field_strength_value = float(dataset[0x0018, 0x0087].value)
                metadata["fieldStrength"] = f"{field_strength_value:.1f}T"
            # Otherwise keep the default 1.5T string
        except Exception as e:
            logger.warning(f"Error reading field strength, using default: {e}")
        
        # Normalize manufacturer name
        if metadata["manufacturer"]:
            if "siemens" in metadata["manufacturer"].lower():
                metadata["manufacturer"] = "SIEMENS"
                # Add Siemens-specific metadata
                metadata.update(extract_siemens_metadata(dataset))
            elif "philips" in metadata["manufacturer"].lower():
                metadata["manufacturer"] = "PHILIPS"
                # Add Philips-specific metadata
                metadata.update(extract_philips_metadata(dataset))
            elif "ge" in metadata["manufacturer"].lower():
                metadata["manufacturer"] = "GE"
            else:
                metadata["manufacturer"] = metadata["manufacturer"].upper()
        
        logger.info(f"Successfully extracted metadata: {metadata['manufacturer']}")
        return metadata
        
    except Exception as e:
        logger.error(f"Error reading DICOM file: {e}")
        return extract_metadata_basic(dicom_file)

# Define standard output directories
RESULTS_DIR = "../mri_results"
METADATA_DIR = os.path.join(RESULTS_DIR, "metadata")

def main():
    """Main function to extract metadata from DICOM file"""
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <dicom_file> <output_json>", file=sys.stderr)
        sys.exit(1)
    
    dicom_file = sys.argv[1]
    output_file = sys.argv[2]
    
    if not os.path.exists(dicom_file):
        logger.error(f"DICOM file does not exist: {dicom_file}")
        sys.exit(1)
        
    logger.info(f"Processing DICOM file: {dicom_file}")
    # Ensure output file is in proper directory
    if not output_file.startswith(RESULTS_DIR) and not os.path.isabs(output_file):
        # Create metadata directory if it doesn't exist
        os.makedirs(METADATA_DIR, exist_ok=True)
        
        # Get basename from the original output path and put it in metadata dir
        output_name = os.path.basename(output_file)
        output_file = os.path.join(METADATA_DIR, output_name)
        
    logger.info(f"Output will be written to: {output_file}")
    
    # Make sure the parent directory exists
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    
    # Extract metadata
    if HAS_PYDICOM:
        metadata = extract_metadata_pydicom(dicom_file)
    else:
        metadata = extract_metadata_basic(dicom_file)
        
    # Add execution information as strings
    metadata["extractionTime"] = time.strftime("%Y-%m-%d %H:%M:%S")
    metadata["inputFile"] = os.path.basename(dicom_file)
    
    # Log important metadata for verification
    logger.info(f"Extracted metadata: manufacturer={metadata['manufacturer']}, "
                f"fieldStrength={metadata['fieldStrength']}, model={metadata.get('modelName', 'Unknown')}")
    
    # Write metadata to output file
    try:
        with open(output_file, 'w') as f:
            json.dump(metadata, f, indent=2)
        logger.info(f"Metadata written to {output_file}")
        print(f"Metadata extracted successfully: {metadata['manufacturer']} {metadata.get('modelName', '')}")
    except Exception as e:
        logger.error(f"Error writing metadata to file: {e}")
        sys.exit(1)
        
    return 0

if __name__ == "__main__":
    sys.exit(main())
