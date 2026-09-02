// three.js viewer for one glTF terrain model.
//
// Thin on purpose: the geometry arrives finished from the server, exactly as
// the visionOS app receives it as a MeshResource. Everything here is
// presentation — camera, lights, and the surface toggle.

import * as THREE from 'three';
import { OrbitControls } from '/vendor/three/OrbitControls.js';
import { GLTFLoader } from '/vendor/three/GLTFLoader.js';

export function createViewer(container) {
  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  container.appendChild(renderer.domElement);

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x0e1116);

  const camera = new THREE.PerspectiveCamera(42, 1, 0.5, 20000);
  const controls = new OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true;
  controls.dampingFactor = 0.08;

  scene.add(new THREE.HemisphereLight(0xbfd4ff, 0x2b2b25, 1.5));
  const sun = new THREE.DirectionalLight(0xffffff, 2.4);
  sun.position.set(-70, 110, 55);
  scene.add(sun);

  const loader = new GLTFLoader();
  let model = null;
  let materials = [];

  function resize() {
    const { clientWidth: w, clientHeight: h } = container;
    if (!w || !h) return;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  }
  addEventListener('resize', resize);
  resize();

  (function animate() {
    requestAnimationFrame(animate);
    controls.update();
    renderer.render(scene, camera);
  })();

  /** Frames the model so it fills the view regardless of how big it came in. */
  function frame(object) {
    const box = new THREE.Box3().setFromObject(object);
    const size = box.getSize(new THREE.Vector3());
    const centre = box.getCenter(new THREE.Vector3());
    const radius = Math.max(size.x, size.z) * 0.5;
    const distance = radius / Math.tan((camera.fov * Math.PI) / 360) * 1.5;

    controls.target.copy(centre);
    camera.position.set(centre.x + distance * 0.7, centre.y + distance * 0.6, centre.z + distance * 0.7);
    camera.near = Math.max(0.1, distance / 500);
    camera.far = distance * 20;
    camera.updateProjectionMatrix();
    controls.update();
  }

  return {
    resize,

    async load(buffer) {
      const gltf = await loader.parseAsync(buffer, '');
      if (model) {
        scene.remove(model);
        model.traverse((node) => {
          node.geometry?.dispose();
          node.material?.map?.dispose();
          node.material?.dispose();
        });
      }
      model = gltf.scene;
      materials = [];
      model.traverse((node) => {
        if (node.isMesh) {
          node.material.side = THREE.DoubleSide;
          materials.push(node.material);
        }
      });
      scene.add(model);
      frame(model);
    },

    /**
     * Exaggeration is a Y scale, which is exactly the lerp we want: the
     * exporter drops the mesh so its lowest point sits at Y = 0, so scaling Y
     * by k interpolates every vertex between the flat plane at k = 0 and the
     * true relief at k = 1, on up to k = 2.
     *
     * It is a matrix change, so it costs nothing and needs no rebuild. Exactly
     * zero would make the model matrix singular and three.js would hand the
     * shader garbage normals, so the floor is a hair above it — at which point
     * the normal matrix has flattened every normal to straight up anyway,
     * which is what a flat plane should look like.
     */
    setExaggeration(value) {
      if (model) model.scale.y = Math.max(value, 1e-4);
    },

    setSurfaceMode(mode) {
      materials.forEach((material) => {
        material.wireframe = mode === 'wireframe';
        // Keep the texture around when it is switched off, so flipping back is
        // instant rather than a re-download.
        if (mode === 'shaded' || mode === 'wireframe') {
          if (material.map) {
            material.userData.map = material.map;
            material.map = null;
          }
          material.color.setHex(mode === 'wireframe' ? 0x4da3ff : 0x9aa7b4);
        } else {
          if (material.userData.map) material.map = material.userData.map;
          material.color.setHex(0xffffff);
        }
        material.needsUpdate = true;
      });
    },
  };
}
