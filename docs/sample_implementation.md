# Sample Implementation of Core Components

This document provides a sample implementation of the core components of the brain MRI processing pipeline Streamlit UI. It demonstrates how the modular pipeline system would work in practice.

## Core Components Implementation

### Step Registry Implementation

```python
# core/pipeline.py

from typing import Dict, List, Type, Optional
from core.step import PipelineStep

class PipelineRegistry:
    """
    Registry for pipeline steps
    """
    
    def __init__(self):
        """Initialize the registry"""
        self._steps: Dict[str, Type[PipelineStep]] = {}
    
    def register_step(self, step_class: Type[PipelineStep]) -> None:
        """
        Register a step class
        
        Args:
            step_class: Step class to register
        """
        # Instantiate the step to get its ID
        step_instance = step_class()
        step_id = step_instance.id
        
        if step_id in self._steps:
            raise ValueError(f"Step with ID '{step_id}' is already registered")
        
        self._steps[step_id] = step_class
    
    def get_step(self, step_id: str) -> Optional[Type[PipelineStep]]:
        """
        Get a step class by ID
        
        Args:
            step_id: Step ID
            
        Returns:
            Step class or None if not found
        """
        return self._steps.get(step_id)
    
    def get_steps(self) -> List[Type[PipelineStep]]:
        """
        Get all registered step classes
        
        Returns:
            List of step classes
        """
        return list(self._steps.values())
    
    def get_steps_by_category(self, category: str) -> List[Type[PipelineStep]]:
        """
        Get step classes by category
        
        Args:
            category: Step category
            
        Returns:
            List of step classes
        """
        return [step_class for step_class in self._steps.values() 
                if step_class().category == category]
    
    def validate_pipeline(self, step_ids: List[str]) -> bool:
        """
        Validate a pipeline configuration
        
        Args:
            step_ids: List of step IDs
            
        Returns:
            True if valid, False otherwise
        """
        # Check if all steps exist
        for step_id in step_ids:
            if step_id not in self._steps:
                return False
        
        # Check dependencies
        for i, step_id in enumerate(step_ids):
            step = self._steps[step_id]()
            dependencies = step.dependencies
            
            # Check if all dependencies are satisfied
            for dep in dependencies:
                if dep not in step_ids[:i]:
                    return False
        
        return True

# Global registry instance
_registry = PipelineRegistry()

def get_pipeline_registry() -> PipelineRegistry:
    """
    Get the global pipeline registry
    
    Returns:
        Pipeline registry
    """
    return _registry

def register_step(step_class: Type[PipelineStep]) -> Type[PipelineStep]:
    """
    Decorator to register a step class
    
    Args:
        step_class: Step class to register
        
    Returns:
        The step class
    """
    _registry.register_step(step_class)
    return step_class
```

### Step Base Class Implementation

```python
# core/step.py

from abc import ABC, abstractmethod
from typing import Dict, List, Any, Optional, Union
from enum import Enum

class ArtifactType(Enum):
    """Artifact types"""
    NIFTI = "nifti"
    DICOM = "dicom"
    JSON = "json"
    TEXT = "text"
    IMAGE = "image"
    OTHER = "other"

class StepParameter:
    """
    Parameter definition for pipeline steps
    """
    
    def __init__(
        self,
        name: str,
        display_name: str,
        description: str,
        type: str,
        default: Any = None,
        min_value: Optional[Union[int, float]] = None,
        max_value: Optional[Union[int, float]] = None,
        options: Optional[List[Any]] = None,
        advanced: bool = False,
        required: bool = True
    ):
        """
        Initialize a step parameter
        
        Args:
            name: Parameter name
            display_name: Display name for the parameter
            description: Parameter description
            type: Parameter type (string, int, float, boolean, select)
            default: Default value
            min_value: Minimum value (for numeric parameters)
            max_value: Maximum value (for numeric parameters)
            options: List of options (for select parameters)
            advanced: Whether the parameter is advanced
            required: Whether the parameter is required
        """
        self.name = name
        self.display_name = display_name
        self.description = description
        self.type = type
        self.default = default
        self.min_value = min_value
        self.max_value = max_value
        self.options = options
        self.advanced = advanced
        self.required = required

class PipelineStep(ABC):
    """
    Abstract base class for pipeline steps
    """
    
    @property
    @abstractmethod
    def id(self) -> str:
        """Unique identifier for the step"""
        pass
    
    @property
    @abstractmethod
    def name(self) -> str:
        """Display name for the step"""
        pass
    
    @property
    @abstractmethod
    def description(self) -> str:
        """Description of the step"""
        pass
    
    @property
    @abstractmethod
    def category(self) -> str:
        """Category of the step"""
        pass
    
    @property
    @abstractmethod
    def version(self) -> str:
        """Version of the step"""
        pass
    
    @property
    @abstractmethod
    def parameters(self) -> List[StepParameter]:
        """List of parameters for the step"""
        pass
    
    @property
    @abstractmethod
    def input_artifacts(self) -> List[Dict]:
        """List of input artifacts for the step"""
        pass
    
    @property
    @abstractmethod
    def output_artifacts(self) -> List[Dict]:
        """List of output artifacts for the step"""
        pass
    
    @property
    @abstractmethod
    def dependencies(self) -> List[str]:
        """List of step dependencies"""
        pass
    
    @property
    @abstractmethod
    def required_tools(self) -> List[str]:
        """List of required external tools"""
        pass
    
    @abstractmethod
    def execute(self, context) -> Dict:
        """
        Execute the step
        
        Args:
            context: Execution context
            
        Returns:
            Dictionary of output artifacts
        """
        pass
    
    @abstractmethod
    def quality_check(self, context, outputs) -> Dict:
        """
        Perform quality checks on the output artifacts
        
        Args:
            context: Execution context
            outputs: Dictionary of output artifacts
            
        Returns:
            Dictionary of quality check results
        """
        pass
    
    @abstractmethod
    def visualize(self, context, outputs) -> Dict:
        """
        Generate visualizations for the output artifacts
        
        Args:
            context: Execution context
            outputs: Dictionary of output artifacts
            
        Returns:
            Dictionary of visualization data
        """
        pass
```

### Execution Context Implementation

```python
# core/context.py

from typing import Dict, Any, Optional, Callable, List
import os
import datetime

class ExecutionContext:
    """
    Execution context for pipeline steps
    """
    
    def __init__(
        self,
        project,
        step_id: str,
        parameters: Dict[str, Any],
        log_callback: Optional[Callable] = None
    ):
        """
        Initialize an execution context
        
        Args:
            project: Project instance
            step_id: Step ID
            parameters: Step parameters
            log_callback: Callback function for logging
        """
        self.project = project
        self.step_id = step_id
        self.parameters = parameters
        self.log_callback = log_callback
        self.start_time = datetime.datetime.now()
        self.logs = []
    
    def get_input_artifact(self, name: str) -> str:
        """
        Get the path to an input artifact
        
        Args:
            name: Artifact name
            
        Returns:
            Path to the artifact
        """
        path = self.project.get_artifact_path(name)
        if not path:
            raise ValueError(f"Artifact '{name}' not found")
        if not os.path.exists(path):
            raise FileNotFoundError(f"Artifact file not found: {path}")
        return path
    
    def get_output_directory(self) -> str:
        """
        Get the output directory for the step
        
        Returns:
            Path to the output directory
        """
        output_dir = self.project.get_step_output_directory(self.step_id)
        os.makedirs(output_dir, exist_ok=True)
        return output_dir
    
    def get_parameter(self, name: str, default: Any = None) -> Any:
        """
        Get a parameter value
        
        Args:
            name: Parameter name
            default: Default value if parameter is not found
            
        Returns:
            Parameter value
        """
        return self.parameters.get(name, default)
    
    def _log(self, level: str, message: str):
        """
        Log a message
        
        Args:
            level: Log level
            message: Message to log
        """
        timestamp = datetime.datetime.now().isoformat()
        log_entry = {
            "timestamp": timestamp,
            "level": level,
            "message": message,
            "step_id": self.step_id
        }
        self.logs.append(log_entry)
        
        if self.log_callback:
            self.log_callback(level, message)
    
    def log_info(self, message: str):
        """
        Log an info message
        
        Args:
            message: Message to log
        """
        self._log("INFO", message)
    
    def log_warning(self, message: str):
        """
        Log a warning message
        
        Args:
            message: Message to log
        """
        self._log("WARNING", message)
    
    def log_error(self, message: str):
        """
        Log an error message
        
        Args:
            message: Message to log
        """
        self._log("ERROR", message)
    
    def log_debug(self, message: str):
        """
        Log a debug message
        
        Args:
            message: Message to log
        """
        self._log("DEBUG", message)
    
    def get_logs(self) -> List[Dict]:
        """
        Get all logs
        
        Returns:
            List of log entries
        """
        return self.logs
```

## Sample Step Implementation

### Bias Field Correction Step

```python
# steps/preprocess/bias_correction.py

from core.step import PipelineStep, StepParameter, ArtifactType
from core.pipeline import register_step
import nibabel as nib
import numpy as np
import os
import subprocess

@register_step
class BiasFieldCorrectionStep(PipelineStep):
    """
    Bias field correction step using N4 algorithm from ANTs
    """
    
    @property
    def id(self) -> str:
        return "bias_correction"
    
    @property
    def name(self) -> str:
        return "Bias Field Correction"
    
    @property
    def description(self) -> str:
        return "Correct intensity non-uniformity using N4 algorithm"
    
    @property
    def category(self) -> str:
        return "preprocessing"
    
    @property
    def version(self) -> str:
        return "1.0.0"
    
    @property
    def parameters(self) -> List[StepParameter]:
        return [
            StepParameter(
                name="iterations",
                display_name="Iterations",
                description="Number of iterations for each resolution level",
                type="string",
                default="50x50x50x50",
                advanced=False
            ),
            StepParameter(
                name="convergence",
                display_name="Convergence Threshold",
                description="Convergence threshold for the optimization",
                type="float",
                default=0.0001,
                min_value=0.000001,
                max_value=0.01,
                advanced=True
            ),
            StepParameter(
                name="bspline_fitting",
                display_name="B-spline Fitting",
                description="B-spline fitting parameter",
                type="int",
                default=200,
                min_value=50,
                max_value=500,
                advanced=True
            ),
            StepParameter(
                name="shrink_factor",
                display_name="Shrink Factor",
                description="Image shrink factor",
                type="int",
                default=4,
                min_value=1,
                max_value=8,
                advanced=True
            )
        ]
    
    @property
    def input_artifacts(self) -> List[Dict]:
        return [
            {
                "name": "input_image",
                "display_name": "Input Image",
                "description": "Input NIfTI image to correct",
                "type": ArtifactType.NIFTI,
                "required": True
            }
        ]
    
    @property
    def output_artifacts(self) -> List[Dict]:
        return [
            {
                "name": "corrected_image",
                "display_name": "Corrected Image",
                "description": "Bias-corrected output image",
                "type": ArtifactType.NIFTI
            },
            {
                "name": "bias_field",
                "display_name": "Bias Field",
                "description": "Estimated bias field",
                "type": ArtifactType.NIFTI
            }
        ]
    
    @property
    def dependencies(self) -> List[str]:
        return []
    
    @property
    def required_tools(self) -> List[str]:
        return ["N4BiasFieldCorrection"]
    
    def execute(self, context) -> Dict:
        """
        Execute the bias field correction step
        
        Args:
            context: Execution context
            
        Returns:
            Dictionary of output artifacts
        """
        # Get input artifacts
        input_image = context.get_input_artifact("input_image")
        
        # Get parameters
        iterations = context.get_parameter("iterations")
        convergence = context.get_parameter("convergence")
        bspline = context.get_parameter("bspline_fitting")
        shrink = context.get_parameter("shrink_factor")
        
        # Prepare output paths
        output_dir = context.get_output_directory()
        corrected_image_path = os.path.join(output_dir, "corrected.nii.gz")
        bias_field_path = os.path.join(output_dir, "bias_field.nii.gz")
        
        # Log the command
        context.log_info(f"Running N4 bias field correction on {input_image}")
        context.log_info(f"Parameters: iterations={iterations}, convergence={convergence}, bspline={bspline}, shrink={shrink}")
        
        # Build the command
        cmd = [
            "N4BiasFieldCorrection",
            "-d", "3",
            "-i", input_image,
            "-o", f"[{corrected_image_path},{bias_field_path}]",
            "-s", str(shrink),
            "-b", f"[{bspline}]",
            "-c", f"[{iterations},{convergence}]"
        ]
        
        # Execute the command
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            context.log_info("N4 bias field correction completed successfully")
            context.log_debug(result.stdout)
        except subprocess.CalledProcessError as e:
            context.log_error(f"N4 bias field correction failed: {e}")
            context.log_error(e.stderr)
            raise RuntimeError(f"N4 bias field correction failed: {e}")
        
        # Return output artifacts
        return {
            "corrected_image": corrected_image_path,
            "bias_field": bias_field_path
        }
    
    def quality_check(self, context, outputs) -> Dict:
        """
        Perform quality checks on the output artifacts
        
        Args:
            context: Execution context
            outputs: Dictionary of output artifacts
            
        Returns:
            Dictionary of quality check results
        """
        # Get output artifacts
        corrected_image_path = outputs["corrected_image"]
        bias_field_path = outputs["bias_field"]
        
        # Load images
        corrected_img = nib.load(corrected_image_path)
        bias_field_img = nib.load(bias_field_path)
        
        # Get data
        corrected_data = corrected_img.get_fdata()
        bias_field_data = bias_field_img.get_fdata()
        
        # Calculate quality metrics
        
        # 1. Coefficient of variation (lower is better after correction)
        mask = corrected_data > np.percentile(corrected_data, 10)
        cv = np.std(corrected_data[mask]) / np.mean(corrected_data[mask])
        
        # 2. Bias field statistics
        bias_mean = np.mean(bias_field_data)
        bias_std = np.std(bias_field_data)
        bias_max = np.max(bias_field_data)
        bias_min = np.min(bias_field_data)
        
        # 3. Bias field range (should be close to 1.0 for well-corrected images)
        bias_range = bias_max / bias_min if bias_min > 0 else float('inf')
        
        # Return quality metrics
        return {
            "coefficient_of_variation": {
                "value": cv,
                "threshold": 0.2,  # Example threshold
                "status": "success" if cv < 0.2 else "warning"
            },
            "bias_field_mean": {
                "value": bias_mean,
                "threshold": None,
                "status": "info"
            },
            "bias_field_std": {
                "value": bias_std,
                "threshold": None,
                "status": "info"
            },
            "bias_field_range": {
                "value": bias_range,
                "threshold": 2.0,  # Example threshold
                "status": "success" if bias_range < 2.0 else "warning"
            }
        }
    
    def visualize(self, context, outputs) -> Dict:
        """
        Generate visualizations for the output artifacts
        
        Args:
            context: Execution context
            outputs: Dictionary of output artifacts
            
        Returns:
            Dictionary of visualization data
        """
        # Get output artifacts
        corrected_image_path = outputs["corrected_image"]
        bias_field_path = outputs["bias_field"]
        
        # Generate Freeview command for external visualization
        freeview_cmd = f"freeview {corrected_image_path} {bias_field_path}:colormap=heat:opacity=0.5"
        
        # Return visualization data
        return {
            "freeview_command": freeview_cmd,
            "comparison_views": [
                {
                    "title": "Before/After Comparison",
                    "type": "side_by_side",
                    "images": [
                        context.get_input_artifact("input_image"),
                        corrected_image_path
                    ]
                },
                {
                    "title": "Bias Field Overlay",
                    "type": "overlay",
                    "base_image": corrected_image_path,
                    "overlay_image": bias_field_path,
                    "colormap": "heat",
                    "opacity": 0.5
                }
            ]
        }
```

## Sample UI Implementation

### Step UI Component

```python
# ui/components/step_ui.py

import streamlit as st
from typing import Optional, Callable, Dict, Any, List
import os

def render_step_header(
    title: str,
    description: str,
    step_number: int,
    status: str
):
    """
    Render the header for a step
    
    Args:
        title: Step title
        description: Step description
        step_number: Step number
        status: Step status
    """
    # Status indicator
    if status == "completed":
        st.success(f"Step {step_number}: {title}")
    elif status == "in_progress":
        st.info(f"Step {step_number}: {title}")
    elif status == "failed":
        st.error(f"Step {step_number}: {title}")
    else:
        st.subheader(f"Step {step_number}: {title}")
    
    # Description
    st.markdown(description)
    
    # Status text
    if status == "completed":
        st.success("✅ This step has been completed successfully.")
    elif status == "in_progress":
        st.info("⏳ This step is currently in progress.")
    elif status == "failed":
        st.error("❌ This step failed. Please check the logs for details.")
    else:
        st.info("⏸️ This step has not been started yet.")

def render_step_footer(
    prev_step: Optional[str] = None,
    next_step: Optional[str] = None,
    status: str = "not_started"
):
    """
    Render the footer for a step
    
    Args:
        prev_step: Previous step ID
        next_step: Next step ID
        status: Step status
    """
    st.markdown("---")
    
    # Navigation buttons
    col1, col2 = st.columns(2)
    
    with col1:
        if prev_step:
            if st.button("⬅️ Previous Step"):
                st.switch_page(f"pages/{prev_step}.py")
    
    with col2:
        if next_step and status == "completed":
            if st.button("➡️ Next Step"):
                st.switch_page(f"pages/{next_step}.py")

def render_parameter_ui(
    parameters: List[Dict],
    current_values: Dict[str, Any],
    on_change: Optional[Callable] = None
) -> Dict[str, Any]:
    """
    Render the parameter UI for a step
    
    Args:
        parameters: List of parameter definitions
        current_values: Dictionary of current parameter values
        on_change: Callback function for parameter changes
        
    Returns:
        Dictionary of parameter values
    """
    param_values = {}
    
    # Group parameters by advanced flag
    basic_params = [p for p in parameters if not p.get("advanced", False)]
    advanced_params = [p for p in parameters if p.get("advanced", False)]
    
    # Render basic parameters
    for param in basic_params:
        param_values.update(render_single_parameter(param, current_values))
    
    # Render advanced parameters in expander
    if advanced_params:
        with st.expander("Advanced Parameters"):
            for param in advanced_params:
                param_values.update(render_single_parameter(param, current_values))
    
    # Call on_change callback if provided
    if on_change and param_values:
        on_change(param_values)
    
    return param_values

def render_single_parameter(
    param: Dict,
    current_values: Dict[str, Any]
) -> Dict[str, Any]:
    """
    Render a single parameter input widget
    
    Args:
        param: Parameter definition
        current_values: Dictionary of current parameter values
        
    Returns:
        Dictionary with parameter name and value
    """
    name = param["name"]
    display_name = param.get("display_name", name)
    description = param.get("description", "")
    param_type = param.get("type", "string")
    default = param.get("default")
    current_value = current_values.get(name, default)
    
    # Render appropriate input widget based on parameter type
    if param_type == "string":
        value = st.text_input(
            display_name,
            value=current_value,
            help=description
        )
    elif param_type == "int":
        min_value = param.get("min_value")
        max_value = param.get("max_value")
        value = st.number_input(
            display_name,
            value=int(current_value) if current_value is not None else 0,
            min_value=min_value,
            max_value=max_value,
            help=description
        )
    elif param_type == "float":
        min_value = param.get("min_value")
        max_value = param.get("max_value")
        value = st.number_input(
            display_name,
            value=float(current_value) if current_value is not None else 0.0,
            min_value=min_value,
            max_value=max_value,
            help=description
        )
    elif param_type == "boolean":
        value = st.checkbox(
            display_name,
            value=bool(current_value) if current_value is not None else False,
            help=description
        )
    elif param_type == "select":
        options = param.get("options", [])
        value = st.selectbox(
            display_name,
            options=options,
            index=options.index(current_value) if current_value in options else 0,
            help=description
        )
    else:
        value = current_value
    
    return {name: value}

def render_artifact_ui(
    artifacts: List[Dict],
    project,
    allow_preview: bool = True
):
    """
    Render the artifact UI for a step
    
    Args:
        artifacts: List of artifact definitions
        project: Project instance
        allow_preview: Whether to allow artifact preview
    """
    for artifact in artifacts:
        name = artifact["name"]
        display_name = artifact.get("display_name", name)
        description = artifact.get("description", "")
        required = artifact.get("required", True)
        
        # Get artifact path
        path = project.get_artifact_path(name)
        
        # Render artifact information
        st.markdown(f"**{display_name}**: {description}")
        
        if path and os.path.exists(path):
            st.success(f"✅ Available: {os.path.basename(path)}")
            
            # Preview button
            if allow_preview and st.button(f"Preview {display_name}"):
                preview_artifact(path, artifact.get("type"))
        else:
            if required:
                st.error(f"❌ Required artifact not available: {display_name}")
            else:
                st.warning(f"⚠️ Optional artifact not available: {display_name}")

def preview_artifact(path: str, artifact_type: str):
    """
    Preview an artifact
    
    Args:
        path: Path to the artifact
        artifact_type: Type of the artifact
    """
    if artifact_type == "nifti":
        # For NIfTI files, show a slice viewer
        try:
            import nibabel as nib
            import matplotlib.pyplot as plt
            import numpy as np
            
            # Load the image
            img = nib.load(path)
            data = img.get_fdata()
            
            # Get the middle slice for each dimension
            x_mid = data.shape[0] // 2
            y_mid = data.shape[1] // 2
            z_mid = data.shape[2] // 2
            
            # Create a figure with three subplots
            fig, axes = plt.subplots(1, 3, figsize=(15, 5))
            
            # Plot the middle slices
            axes[0].imshow(data[x_mid, :, :].T, cmap="gray", origin="lower")
            axes[0].set_title(f"Sagittal (x={x_mid})")
            
            axes[1].imshow(data[:, y_mid, :].T, cmap="gray", origin="lower")
            axes[1].set_title(f"Coronal (y={y_mid})")
            
            axes[2].imshow(data[:, :, z_mid].T, cmap="gray", origin="lower")
            axes[2].set_title(f"Axial (z={z_mid})")
            
            # Display the figure
            st.pyplot(fig)
            
            # Show metadata
            st.subheader("Metadata")
            st.write(f"Dimensions: {data.shape}")
            st.write(f"Data type: {data.dtype}")
            st.write(f"Value range: [{data.min():.2f}, {data.max():.2f}]")
            
            # Show histogram
            st.subheader("Histogram")
            fig, ax = plt.subplots(figsize=(10, 5))
            ax.hist(data.flatten(), bins=100)
            ax.set_title("Intensity Histogram")
            ax.set_xlabel("Intensity")
            ax.set_ylabel("Frequency")
            st.pyplot(fig)
            
        except Exception as e:
            st.error(f"Error previewing NIfTI file: {e}")
    
    elif artifact_type == "dicom":
        # For DICOM files, show basic information
        try:
            import pydicom
            
            # Load the DICOM file
            dcm = pydicom.dcmread(path)
            
            # Show metadata
            st.subheader("DICOM Metadata")
            st.write(f"Patient Name: {dcm.PatientName}")
            st.write(f"Study Date: {dcm.StudyDate}")
            st.write(f"Modality: {dcm.Modality}")
            st.write(f"Image Size: {dcm.Rows} x {dcm.Columns}")
            
            # Show the image
            st.subheader("DICOM Image")
            st.image(dcm.pixel_array, caption="DICOM Image", use_column_width=True)
            
        except Exception as e:
            st.error(f"Error previewing DICOM file: {e}")
    
    elif artifact_type == "json":
        # For JSON files, show the content
        try:
            import json
            
            with open(path, "r") as f:
                data = json.load(f)
            
            st.subheader("JSON Content")
            st.json(data)
            
        except Exception as e:
            st.error(f"Error previewing JSON file: {e}")
    
    elif artifact_type == "text":
        # For text files, show the content
        try:
            with open(path, "r") as f:
                content = f.read()
            
            st.subheader("Text Content")
            st.text(content)
            
        except Exception as e:
            st.error(f"Error previewing text file: {e}")
    
    elif artifact_type == "image":
        # For image files, show the image
        try:
            from PIL import Image
            
            img = Image.open(path)
            
            st.subheader("Image")
            st.image(img, caption="Image", use_column_width=True)
            
        except Exception as e:
            st.error(f"Error previewing image file: {e}")
    
    else:
        # For other files, show basic information
