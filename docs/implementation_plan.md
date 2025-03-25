# Brain MRI Processing Pipeline: Implementation Plan

This document outlines the detailed implementation plan for the Streamlit UI integration of the brain MRI processing pipeline. It focuses on the practical steps needed to transform the shell scripts into a modular, user-friendly application.

## Phase 1: Core Framework Implementation

### 1.1 Project Setup (Week 1)

#### Directory Structure
```
streamlit_app/
├── Home.py                      # Main entry point
├── config/                      # Configuration files
├── core/                        # Core framework
├── steps/                       # Pipeline steps
├── ui/                          # UI components
│   ├── components/              # Reusable UI components
│   └── pages/                   # Streamlit pages
├── utils/                       # Utility functions
├── plugins/                     # Plugin directory
└── models/                      # Machine learning models
```

#### Initial Dependencies
Create a `requirements.txt` file with:
```
streamlit>=1.22.0
nibabel>=4.0.0
numpy>=1.22.0
pandas>=1.5.0
matplotlib>=3.5.0
scikit-image>=0.19.0
pydicom>=2.3.0
```

#### Configuration Files
Create initial configuration files:
- `config/default_pipelines.json`: Default pipeline configurations
- `config/default_parameters.json`: Default parameter values
- `config/quality_thresholds.json`: Quality check thresholds

### 1.2 Core Framework (Week 2-3)

#### Pipeline Registry
Implement the pipeline registry in `core/pipeline.py`:
- Step registration mechanism
- Step discovery
- Pipeline configuration management
- Pipeline validation

#### Step Base Classes
Implement step base classes in `core/step.py`:
- `PipelineStep` abstract base class
- Parameter definition classes
- Artifact type definitions
- Step dependency management

#### Project Management
Implement project management in `core/project.py`:
- Project creation and loading
- Directory structure management
- State persistence
- Artifact tracking

#### State Management
Implement state management in `core/state.py`:
- Session state management
- Persistent state storage
- State synchronization

### 1.3 Shell Script Integration (Week 4)

#### Shell Function Wrapper
Implement shell function wrapper in `utils/shell.py`:
- Function to source shell scripts
- Function to execute shell commands
- Output parsing and error handling
- Environment variable management

#### Shell Function Discovery
Implement shell function discovery:
- Parse shell scripts to extract function definitions
- Extract parameter information
- Generate Python wrappers for shell functions

#### Shell Function Execution
Implement shell function execution:
- Execute shell functions with parameters
- Capture and parse output
- Handle errors and timeouts
- Log execution details

### 1.4 Basic UI Components (Week 5)

#### Navigation System
Implement navigation system in `ui/components/navigation.py`:
- Sidebar navigation
- Step progression tracking
- Navigation state management

#### Step UI Template
Implement step UI template in `ui/components/step_ui.py`:
- Consistent UI structure for all steps
- Header and footer components
- Progress indicators
- Navigation controls

#### Parameter UI Components
Implement parameter UI components in `ui/components/parameter_ui.py`:
- Input widgets for different parameter types
- Parameter validation
- Advanced options handling
- Parameter dependencies

#### Artifact UI Components
Implement artifact UI components in `ui/components/artifact_ui.py`:
- Artifact listing and selection
- Artifact preview
- Artifact metadata display
- Artifact comparison

## Phase 2: Basic Pipeline Steps Implementation

### 2.1 DiCOM Import & Conversion (Week 6)

#### DiCOM Import Step
Implement DiCOM import step in `steps/dicom/import.py`:
- Directory selection and validation
- DiCOM file discovery
- Metadata extraction
- Quality checks

#### DiCOM to NIfTI Conversion Step
Implement DiCOM to NIfTI conversion step in `steps/dicom/convert.py`:
- Integration with dcm2niix
- Output organization
- Metadata preservation
- Quality checks

#### DiCOM Utilities
Implement DiCOM utilities in `utils/dicom.py`:
- DiCOM metadata extraction
- DiCOM series organization
- DiCOM validation

### 2.2 Preprocessing Steps (Week 7)

#### Bias Field Correction Step
Implement bias field correction step in `steps/preprocess/bias_correction.py`:
- Integration with N4BiasFieldCorrection
- Parameter configuration
- Quality checks
- Visualization

#### Brain Extraction Step
Implement brain extraction step in `steps/preprocess/brain_extraction.py`:
- Integration with antsBrainExtraction.sh
- Parameter configuration
- Quality checks
- Visualization

#### Intensity Normalization Step
Implement intensity normalization step in `steps/preprocess/normalization.py`:
- Integration with FSL tools
- Parameter configuration
- Quality checks
- Visualization

### 2.3 Registration & Segmentation (Week 8)

#### Registration Steps
Implement registration steps in `steps/register/`:
- Linear registration step
- Non-linear registration step
- Template registration step
- Quality checks
- Visualization

#### Segmentation Steps
Implement segmentation steps in `steps/segment/`:
- Tissue segmentation step
- Structure segmentation step
- Quality checks
- Visualization

### 2.4 Analysis & Visualization (Week 9)

#### Analysis Steps
Implement analysis steps in `steps/analyze/`:
- Volumetric analysis step
- Intensity analysis step
- Quality checks
- Visualization

#### Visualization Integration
Implement visualization integration in `utils/visualization.py`:
- Freeview integration
- FSLeyes integration
- Command generation
- Result organization

## Phase 3: Quality Control & Refinement

### 3.1 Quality Control System (Week 10)

#### Quality Metrics
Implement quality metrics in `core/quality.py`:
- Image quality metrics
- Registration quality metrics
- Segmentation quality metrics
- Custom metrics

#### Quality Check UI
Implement quality check UI in `ui/components/quality_ui.py`:
- Quality check results display
- Visual inspection tools
- Threshold configuration
- Quality report generation

#### Metadata Validation
Implement metadata validation in `core/metadata.py`:
- Metadata extraction
- Metadata validation
- Metadata comparison
- Anomaly detection

### 3.2 Logging & Monitoring (Week 11)

#### Logging System
Implement logging system in `core/logging.py`:
- Log collection
- Log storage
- Log filtering
- Log analysis

#### Log Viewer
Implement log viewer in `ui/components/log_ui.py`:
- Real-time log display
- Log filtering and searching
- Error highlighting
- Log correlation with artifacts

#### Monitoring System
Implement monitoring system in `core/monitoring.py`:
- Process monitoring
- Resource usage tracking
- Error detection
- Notification system

### 3.3 Documentation & Testing (Week 12)

#### User Documentation
Create user documentation:
- Installation guide
- User manual
- Tutorial
- FAQ

#### Developer Documentation
Create developer documentation:
- Architecture overview
- API reference
- Plugin development guide
- Contribution guide

#### Testing
Implement testing:
- Unit tests
- Integration tests
- End-to-end tests
- Performance tests

## Implementation Details

### Core Classes

#### PipelineStep
```python
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

#### StepParameter
```python
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
```

#### ExecutionContext
```python
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
    
    def get_input_artifact(self, name: str) -> str:
        """
        Get the path to an input artifact
        
        Args:
            name: Artifact name
            
        Returns:
            Path to the artifact
        """
        return self.project.get_artifact_path(name)
    
    def get_output_directory(self) -> str:
        """
        Get the output directory for the step
        
        Returns:
            Path to the output directory
        """
        return self.project.get_step_output_directory(self.step_id)
    
    def get_parameter(self, name: str) -> Any:
        """
        Get a parameter value
        
        Args:
            name: Parameter name
            
        Returns:
            Parameter value
        """
        return self.parameters.get(name)
    
    def log_info(self, message: str):
        """
        Log an info message
        
        Args:
            message: Message to log
        """
        if self.log_callback:
            self.log_callback("INFO", message)
    
    def log_warning(self, message: str):
        """
        Log a warning message
        
        Args:
            message: Message to log
        """
        if self.log_callback:
            self.log_callback("WARNING", message)
    
    def log_error(self, message: str):
        """
        Log an error message
        
        Args:
            message: Message to log
        """
        if self.log_callback:
            self.log_callback("ERROR", message)
    
    def log_debug(self, message: str):
        """
        Log a debug message
        
        Args:
            message: Message to log
        """
        if self.log_callback:
            self.log_callback("DEBUG", message)
```

### Shell Integration

#### ShellFunction
```python
class ShellFunction:
    """
    Wrapper for shell functions
    """
    
    def __init__(
        self,
        name: str,
        script_path: str,
        description: str = "",
        parameters: Optional[List[Dict]] = None
    ):
        """
        Initialize a shell function wrapper
        
        Args:
            name: Function name
            script_path: Path to the shell script
            description: Function description
            parameters: List of parameter definitions
        """
        self.name = name
        self.script_path = script_path
        self.description = description
        self.parameters = parameters or []
    
    def execute(
        self,
        *args,
        capture_output: bool = True,
        **kwargs
    ) -> Dict:
        """
        Execute the shell function
        
        Args:
            *args: Positional arguments
            capture_output: Whether to capture output
            **kwargs: Keyword arguments
            
        Returns:
            Dictionary with execution results
        """
        # Convert kwargs to positional args based on parameter definitions
        cmd_args = list(args)
        for param in self.parameters:
            if param["name"] in kwargs:
                cmd_args.append(str(kwargs[param["name"]]))
        
        # Build the command
        cmd = f"source {self.script_path} && {self.name} {' '.join(map(str, cmd_args))}"
        
        # Execute the command
        result = subprocess.run(
            ["bash", "-c", cmd],
            capture_output=capture_output,
            text=True
        )
        
        # Parse the output
        return self._parse_result(result)
    
    def _parse_result(self, result: subprocess.CompletedProcess) -> Dict:
        """
        Parse the command output
        
        Args:
            result: Command execution result
            
        Returns:
            Dictionary with parsed results
        """
        return {
            "stdout": result.stdout,
            "stderr": result.stderr,
            "returncode": result.returncode,
            "success": result.returncode == 0,
            # Additional parsed fields based on output patterns
        }
```

### Project Management

#### MRIProject
```python
class MRIProject:
    """
    MRI project management
    """
    
    def __init__(self, name: str, base_dir: Optional[str] = None):
        """
        Initialize an MRI project
        
        Args:
            name: Project name
            base_dir: Base directory for the project
        """
        self.name = name
        self.base_dir = base_dir or os.path.join("../projects", name)
        self.config_file = os.path.join(self.base_dir, "project_config.json")
        self.metadata = {}
        self.status = {}
        self.artifacts = {}
    
    def create(self, metadata: Optional[Dict] = None) -> 'MRIProject':
        """
        Create a new project
        
        Args:
            metadata: Project metadata
            
        Returns:
            Self
        """
        # Create directories
        dirs = [
            "dicom",
            "nifti",
            "preprocessed",
            "registered",
            "segmented",
            "analysis",
            "logs"
        ]
        
        for d in dirs:
            os.makedirs(os.path.join(self.base_dir, d), exist_ok=True)
        
        # Initialize metadata
        self.metadata = metadata or {}
        self.metadata.update({
            "created": datetime.datetime.now().isoformat(),
            "name": self.name
        })
        
        # Initialize status
        self.status = {
            "dicom_import": "not_started",
            "conversion": "not_started",
            "preprocessing": "not_started",
            "registration": "not_started",
            "segmentation": "not_started",
            "analysis": "not_started"
        }
        
        # Save configuration
        self.save()
        
        return self
    
    def load(self) -> 'MRIProject':
        """
        Load project configuration
        
        Returns:
            Self
        """
        if not os.path.exists(self.config_file):
            raise FileNotFoundError(f"Project configuration not found: {self.config_file}")
        
        with open(self.config_file, "r") as f:
            config = json.load(f)
        
        self.metadata = config.get("metadata", {})
        self.status = config.get("status", {})
        self.artifacts = config.get("artifacts", {})
        
        return self
    
    def save(self):
        """
        Save project configuration
        """
        config = {
            "metadata": self.metadata,
            "status": self.status,
            "artifacts": self.artifacts
        }
        
        with open(self.config_file, "w") as f:
            json.dump(config, f, indent=2)
    
    def get_step_status(self, step_id: str) -> str:
        """
        Get the status of a step
        
        Args:
            step_id: Step ID
            
        Returns:
            Step status
        """
        return self.status.get(step_id, "not_started")
    
    def set_step_status(self, step_id: str, status: str, details: Optional[Dict] = None):
        """
        Set the status of a step
        
        Args:
            step_id: Step ID
            status: Step status
            details: Additional details
        """
        self.status[step_id] = status
        
        if details:
            if "details" not in self.status:
                self.status["details"] = {}
            self.status["details"][step_id] = details
        
        self.save()
    
    def get_artifact_path(self, name: str) -> Optional[str]:
        """
        Get the path to an artifact
        
        Args:
            name: Artifact name
            
        Returns:
            Path to the artifact
        """
        return self.artifacts.get(name)
    
    def set_artifact_path(self, name: str, path: str):
        """
        Set the path to an artifact
        
        Args:
            name: Artifact name
            path: Path to the artifact
        """
        self.artifacts[name] = path
        self.save()
    
    def get_step_output_directory(self, step_id: str) -> str:
        """
        Get the output directory for a step
        
        Args:
            step_id: Step ID
            
        Returns:
            Path to the output directory
        """
        return os.path.join(self.base_dir, "steps", step_id)
    
    def get_step_parameter(self, step_id: str, param_name: str) -> Any:
        """
        Get a step parameter
        
        Args:
            step_id: Step ID
            param_name: Parameter name
            
        Returns:
            Parameter value
        """
        if "parameters" not in self.status:
            return None
        
        if step_id not in self.status["parameters"]:
            return None
        
        return self.status["parameters"][step_id].get(param_name)
    
    def set_step_parameter(self, step_id: str, param_name: str, value: Any):
        """
        Set a step parameter
        
        Args:
            step_id: Step ID
            param_name: Parameter name
            value: Parameter value
        """
        if "parameters" not in self.status:
            self.status["parameters"] = {}
        
        if step_id not in self.status["parameters"]:
            self.status["parameters"][step_id] = {}
        
        self.status["parameters"][step_id][param_name] = value
        self.save()
    
    def get_step_quality_results(self, step_id: str) -> Dict:
        """
        Get quality check results for a step
        
        Args:
            step_id: Step ID
            
        Returns:
            Quality check results
        """
        if "details" not in self.status:
            return {}
        
        if step_id not in self.status["details"]:
            return {}
        
        return self.status["details"][step_id].get("quality_check", {})
    
    def set_step_quality_results(self, step_id: str, results: Dict):
        """
        Set quality check results for a step
        
        Args:
            step_id: Step ID
            results: Quality check results
        """
        if "details" not in self.status:
            self.status["details"] = {}
        
        if step_id not in self.status["details"]:
            self.status["details"][step_id] = {}
        
        self.status["details"][step_id]["quality_check"] = results
        self.save()
```

## Timeline and Milestones

### Week 1: Project Setup
- Set up project directory structure
- Create initial configuration files
- Set up development environment
- Create basic Streamlit app structure

### Week 2-3: Core Framework
- Implement pipeline registry
- Implement step base classes
- Implement project management
- Implement state management

### Week 4: Shell Script Integration
- Implement shell function wrapper
- Implement shell function discovery
- Implement shell function execution

### Week 5: Basic UI Components
- Implement navigation system
- Implement step UI template
- Implement parameter UI components
- Implement artifact UI components

### Week 6: DiCOM Import & Conversion
- Implement DiCOM import step
- Implement DiCOM to NIfTI conversion step
- Implement DiCOM utilities

### Week 7: Preprocessing Steps
- Implement bias field correction step
- Implement brain extraction step
- Implement intensity normalization step

### Week 8: Registration & Segmentation
- Implement registration steps
- Implement segmentation steps

### Week 9: Analysis & Visualization
- Implement analysis steps
- Implement visualization integration

### Week 10: Quality Control System
- Implement quality metrics
- Implement quality check UI
- Implement metadata validation

### Week 11: Logging & Monitoring
- Implement logging system
- Implement log viewer
- Implement monitoring system

### Week 12: Documentation & Testing
- Create user documentation
- Create developer documentation
- Implement testing

## Conclusion

This implementation plan provides a detailed roadmap for developing the Streamlit UI integration for the brain MRI processing pipeline. It breaks down the work into manageable phases and tasks, with clear milestones and deliverables.

The modular architecture ensures that the system can be extended with new steps, quality checks, and visualizations as needed. The focus on quality control, logging, and monitoring ensures that the system is robust and user-friendly.

By following this plan, we can create a comprehensive, user-friendly interface for the brain MRI processing pipeline that supports the entire workflow from DiCOM import to visualization, with robust quality control and the ability to customize the pipeline.