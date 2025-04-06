import ants
import numpy as np
from pathlib import Path
from sklearn.decomposition import PCA
from typing import Tuple, Dict

class BrainstemSegmentation:
    def __init__(self, suit_dir: Path):
        """
        Initialize segmentation pipeline with SUIT directory
        
        Args:
            suit_dir (Path): Path to SUIT installation
        """
        self.suit_dir = suit_dir
        self.templates = self._load_templates()
        
    def _load_templates(self) -> Dict[str, ants.core.ants_image.ANTsImage]:
        """Load required templates"""
        return {
            'suit': ants.image_read(str(self.suit_dir / "atlases" / "SUIT.nii")),
            'harvard': ants.image_read("/opt/fsl/data/atlases/HarvardOxford/HarvardOxford-sub-maxprob-thr25-1mm.nii.gz"),
            'mni': ants.get_ants_data("mni"),
            'suit_brainstem': ants.image_read(str(self.suit_dir / "atlases" / "SUIT_brainstem_prob.nii"))
        }
    
    def isolate_brainstem(self, input_image: ants.core.ants_image.ANTsImage) -> ants.core.ants_image.ANTsImage:
        """
        Isolate brainstem region using multi-step approach
        """
        # Initial alignment to MNI
        reg = ants.registration(
            fixed=self.templates['mni'],
            moving=input_image,
            type_of_transform="Rigid"
        )
        
        # Create ROI mask for brainstem region
        roi = np.zeros(self.templates['mni'].shape)
        roi[70:100, 70:110, 25:55] = 1
        roi_img = ants.from_numpy(roi, 
                                origin=self.templates['mni'].origin,
                                spacing=self.templates['mni'].spacing,
                                direction=self.templates['mni'].direction)
        
        # Tissue segmentation
        seg = ants.atropos(
            a=reg['warpedmovout'],
            m='[0.2,1x1x1]',
            c='[5,0]',
            i='kmeans[3]',
            x=roi_img
        )
        
        brainstem_mask = (seg['segmentation'] == 2)
        return input_image * brainstem_mask
    
    def register_to_suit(self, isolated_brainstem: ants.core.ants_image.ANTsImage) -> ants.core.ants_image.ANTsImage:
        """
        Register isolated brainstem to SUIT space
        """
        return ants.registration(
            fixed=self.templates['suit'],
            moving=isolated_brainstem,
            type_of_transform="SyN",
            aff_metric="mattes",
            syn_metric="mattes",
            reg_iterations=(100,70,50,20),
            aff_iterations=(2100,1200,1200,10)
        )['warpedmovout']
    
    def divide_pons(self, pons_mask: np.ndarray) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
        """
        Divide pons into dorsal and ventral regions using structural coordinates
        """
        # Extract coordinates
        coords = np.array(np.where(pons_mask > 0)).T
        
        # PCA for anatomical axes
        pca = PCA(n_components=3)
        pca.fit(coords)
        principal_axes = pca.components_
        
        # Calculate centroid
        centroid = np.mean(coords, axis=0)
        
        # Define anatomical axes
        ap_axis = principal_axes[0]
        si_axis = principal_axes[1]
        ml_axis = principal_axes[2]
        
        # Project coordinates
        si_projections = np.dot(coords - centroid, si_axis)
        
        # Create masks using 45% threshold
        threshold_value = np.percentile(si_projections, 45)
        dorsal_mask = np.zeros_like(pons_mask)
        ventral_mask = np.zeros_like(pons_mask)
        
        for i, point in enumerate(coords):
            if si_projections[i] < threshold_value:
                ventral_mask[tuple(point)] = 1
            else:
                dorsal_mask[tuple(point)] = 1
                
        return dorsal_mask, ventral_mask, principal_axes, centroid
    
    def process_image(self, input_image_path: Path) -> Dict[str, ants.core.ants_image.ANTsImage]:
        """
        Complete processing pipeline
        """
        # Load input image
        input_image = ants.image_read(str(input_image_path))
        
        results = {}
        
        # SUIT-based segmentation
        suit_results = self._segment_suit(input_image)
        results['suit'] = suit_results
        
        # Harvard-Oxford based segmentation
        harvard_results = self._segment_harvard(input_image)
        results['harvard'] = harvard_results
        
        # Create consensus mask if needed
        if suit_results['pons'] is not None and harvard_results['pons'] is not None:
            consensus = self._create_consensus(
                suit_results['pons'],
                harvard_results['pons']
            )
            results['consensus'] = consensus
        
        return results
    
    def _segment_suit(self, image: ants.core.ants_image.ANTsImage) -> Dict[str, ants.core.ants_image.ANTsImage]:
        """SUIT-based segmentation pipeline"""
        isolated = self.isolate_brainstem(image)
        registered = self.register_to_suit(isolated)
        pons_mask = registered.numpy()
        dorsal_mask, ventral_mask, axes, centroid = self.divide_pons(pons_mask)
        
        # Convert masks back to ANTs images
        dorsal = ants.from_numpy(dorsal_mask, origin=registered.origin,
                               spacing=registered.spacing,
                               direction=registered.direction)
        ventral = ants.from_numpy(ventral_mask, origin=registered.origin,
                                spacing=registered.spacing,
                                direction=registered.direction)
        
        return {
            'brainstem': registered,
            'pons': registered,
            'dorsal_pons': dorsal,
            'ventral_pons': ventral
        }

    def _segment_harvard(self, image: ants.core.ants_image.ANTsImage) -> Dict[str, ants.core.ants_image.ANTsImage]:
        """Harvard-Oxford atlas based brainstem segmentation with additional pons processing"""
        # Register to MNI space (Harvard-Oxford space)
        reg = ants.registration(
            fixed=self.templates['harvard'],
            moving=image,
            type_of_transform='SyN',
            reg_iterations=(100,70,50,20)
        )

        # Extract brainstem (label 16 in Harvard-Oxford)
        brainstem = (self.templates['harvard'] == 16)
        
        # Apply transform to get brainstem in subject space
        brainstem_native = ants.apply_transforms(
            fixed=image,
            moving=brainstem,
            transformlist=reg['invtransforms']
        )

        # Extract pons using geometric approach
        # Get brainstem bounds in superior-inferior direction
        mask = brainstem_native.numpy()
        z_indices = np.where(mask)[2]
        z_min, z_max = np.min(z_indices), np.max(z_indices)
        z_range = z_max - z_min
        
        # Define pons as middle third of brainstem
        pons_start = z_min + (z_range // 3)
        pons_end = z_min + (2 * z_range // 3)
        
        # Create pons mask
        pons_mask = np.zeros_like(mask)
        pons_mask[:, :, pons_start:pons_end] = mask[:, :, pons_start:pons_end]
        
        # Convert back to ANTs image
        pons = ants.from_numpy(
            pons_mask,
            origin=brainstem_native.origin,
            spacing=brainstem_native.spacing,
            direction=brainstem_native.direction
        )

        # Divide into dorsal/ventral
        dorsal, ventral = self._divide_pons_geometric(pons)
        
        return {
            'brainstem': brainstem_native,
            'pons': pons,
            'dorsal': dorsal,
            'ventral': ventral,
            'transform': reg['fwdtransforms']
        }

    def _divide_pons_geometric(self, pons_mask: ants.core.ants_image.ANTsImage) -> Tuple[ants.core.ants_image.ANTsImage, ants.core.ants_image.ANTsImage]:
        """Divide pons into dorsal/ventral regions using geometric approach"""
        mask = pons_mask.numpy()
        
        # Find anterior-posterior bounds
        y_indices = np.where(mask)[1]
        y_min, y_max = np.min(y_indices), np.max(y_indices)
        y_mid = (y_min + y_max) // 2
        
        # Create dorsal (posterior) and ventral (anterior) masks
        dorsal_mask = np.zeros_like(mask)
        ventral_mask = np.zeros_like(mask)
        
        dorsal_mask[:, y_mid:, :] = mask[:, y_mid:, :]
        ventral_mask[:, :y_mid, :] = mask[:, :y_mid, :]
        
        # Convert back to ANTs images
        dorsal = ants.from_numpy(
            dorsal_mask,
            origin=pons_mask.origin,
            spacing=pons_mask.spacing,
            direction=pons_mask.direction
        )
        
        ventral = ants.from_numpy(
            ventral_mask,
            origin=pons_mask.origin,
            spacing=pons_mask.spacing,
            direction=pons_mask.direction
        )
        
        return dorsal, ventral

    def _create_consensus(self, suit_pons: ants.core.ants_image.ANTsImage,
                         harvard_pons: ants.core.ants_image.ANTsImage) -> ants.core.ants_image.ANTsImage:
        """Create consensus mask from both methods"""
        # Register Harvard result to SUIT space
        reg = ants.registration(
            fixed=suit_pons,
            moving=harvard_pons,
            type_of_transform='Rigid'
        )
        
        # Create consensus mask (intersection)
        consensus = (suit_pons.numpy() > 0) & (reg['warpedmovout'].numpy() > 0)
        
        return ants.from_numpy(
            consensus.astype(np.float32),
            origin=suit_pons.origin,
            spacing=suit_pons.spacing,
            direction=suit_pons.direction
        )
    
if __name__ == "__main__":
    # Example usage
    input_path = Path("../mri_results/")

    suit_dir = Path("/Users/davidbrewster")
    segmenter = BrainstemSegmentation(suit_dir)
    results = segmenter.process_image(input_path)

    # Access results
    suit_results = results['suit']
    harvard_results = results['harvard']
    consensus_mask = results.get('consensus')  # May be None if one method fails
    print("Suit results:", suit_results)
    print("Harvard results:", harvard_results)
    # Save results
    suit_results['brainstem'].to_filename("suit_brainstem.nii.gz")

    harvard_results['brainstem'].to_filename("harvard_brainstem.nii.gz")
    if consensus_mask is not None:
        consensus_mask.to_filename("consensus_mask.nii.gz")
    
    print("Segmentation complete: results saved to suit_brainstem.nii.gz, harvard_brainstem.nii.gz, and consensus_mask.nii.gz")
