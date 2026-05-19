import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { DRACOLoader } from 'three/addons/loaders/DRACOLoader.js';
import { TilesRenderer, GLTFCesiumRTCExtension } from '3d-tiles-renderer';

const STATION_LAT = 35.697686;
const STATION_LON = 139.413650;
const STATION_H   = 120;

const TILESET_URL = './data/extracted_2025/13202_tachikawa-shi_pref_2025_citygml_1_op_bldg_3dtiles_lod2/tileset.json';

// AGENT: GSI 地理院タイル basemap — 'seamlessphoto' (aerial/satellite, .jpg) or 'std' (illustrated map, .png)
const GROUND_LAYER = 'seamlessphoto';
const GROUND_EXT   = GROUND_LAYER === 'seamlessphoto' ? 'jpg' : 'png';
const GROUND_ZOOM  = 17;
const GROUND_HALF  = 2;

const MOVE_SPEED              = 120; // AGENT: meters per second at normal speed
const SHIFT_SPEED_MULTIPLIER  = 2;
const CTRL_SPEED_MULTIPLIER   = 0.5;
const MAX_FRAME_DELTA         = 0.1; // AGENT: clamp dt so a slow frame can't teleport the camera

const MOUSE_SENSITIVITY = 0.0025; // AGENT: radians of look rotation per pixel of drag
const PITCH_LIMIT       = Math.PI / 2 - 0.01; // AGENT: keep just below straight up/down to avoid flip

const CAMERA_FOV  = 55;
const CAMERA_NEAR = 1;
const CAMERA_FAR  = 20000;
const CAMERA_START_POSITION = new THREE.Vector3(450, 380, 450);
const CAMERA_START_TARGET   = new THREE.Vector3(0, 0, 0);

const SKY_COLOR = 0x9ec9e8;
const FOG_NEAR  = 1500;
const FOG_FAR   = 3500;

const TILES_ERROR_TARGET = 16;

const statusEl = document.getElementById('status');
const setStatus = (msg, isErr = false) => {
  statusEl.textContent = msg;
  statusEl.classList.toggle('err', isErr);
};

const scene = new THREE.Scene();
scene.background = new THREE.Color(SKY_COLOR);
scene.fog = new THREE.Fog(SKY_COLOR, FOG_NEAR, FOG_FAR);

const camera = new THREE.PerspectiveCamera(CAMERA_FOV, innerWidth / innerHeight, CAMERA_NEAR, CAMERA_FAR);
camera.position.copy(CAMERA_START_POSITION);

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.setSize(innerWidth, innerHeight);
renderer.outputColorSpace = THREE.SRGBColorSpace;
document.getElementById('app').appendChild(renderer.domElement);

// AGENT: first-person look — yaw around world Y, pitch around local X, no roll
camera.rotation.order = 'YXZ';
let yaw = 0;
let pitch = 0;

function applyLook() {
  camera.rotation.set(pitch, yaw, 0);
}

function setLookToward(position, target) {
  const dir = target.clone().sub(position).normalize();
  yaw = Math.atan2(-dir.x, -dir.z);
  pitch = Math.asin(THREE.MathUtils.clamp(dir.y, -1, 1));
  applyLook();
}

setLookToward(CAMERA_START_POSITION, CAMERA_START_TARGET);

function resetView() {
  camera.position.copy(CAMERA_START_POSITION);
  setLookToward(CAMERA_START_POSITION, CAMERA_START_TARGET);
}

const canvas = renderer.domElement;
canvas.style.cursor = 'grab';
let dragging = false;

canvas.addEventListener('pointerdown', (e) => {
  dragging = true;
  canvas.setPointerCapture(e.pointerId);
  canvas.style.cursor = 'grabbing';
});
function endDrag(e) {
  dragging = false;
  if (e?.pointerId != null) canvas.releasePointerCapture(e.pointerId);
  canvas.style.cursor = 'grab';
}
canvas.addEventListener('pointerup', endDrag);
canvas.addEventListener('pointercancel', endDrag);

canvas.addEventListener('pointermove', (e) => {
  if (!dragging) return;
  yaw   -= e.movementX * MOUSE_SENSITIVITY;
  pitch -= e.movementY * MOUSE_SENSITIVITY;
  pitch = THREE.MathUtils.clamp(pitch, -PITCH_LIMIT, PITCH_LIMIT);
  applyLook();
});

const pressedKeys = new Set();
addEventListener('keydown', (e) => {
  if (e.code === 'KeyR') resetView();
  pressedKeys.add(e.code);
});
addEventListener('keyup', (e) => pressedKeys.delete(e.code));
// AGENT: window blur drops keyup/pointerup events, so clear input to avoid stuck movement/drag
addEventListener('blur', () => {
  pressedKeys.clear();
  dragging = false;
  canvas.style.cursor = 'grab';
});

const WORLD_UP = new THREE.Vector3(0, 1, 0);
const flyForward = new THREE.Vector3();
const flyRight = new THREE.Vector3();
const flyDelta = new THREE.Vector3();

function currentMoveSpeed() {
  let speed = MOVE_SPEED;
  if (pressedKeys.has('ShiftLeft') || pressedKeys.has('ShiftRight')) speed *= SHIFT_SPEED_MULTIPLIER;
  if (pressedKeys.has('ControlLeft') || pressedKeys.has('ControlRight')) speed *= CTRL_SPEED_MULTIPLIER;
  return speed;
}

// AGENT: horizontal movement follows yaw only; pitch never tilts WASD, Q/E handles altitude
function updateFlyMovement(dt) {
  flyForward.set(-Math.sin(yaw), 0, -Math.cos(yaw));
  flyRight.set(Math.cos(yaw), 0, -Math.sin(yaw));

  flyDelta.set(0, 0, 0);
  if (pressedKeys.has('KeyW')) flyDelta.add(flyForward);
  if (pressedKeys.has('KeyS')) flyDelta.sub(flyForward);
  if (pressedKeys.has('KeyD')) flyDelta.add(flyRight);
  if (pressedKeys.has('KeyA')) flyDelta.sub(flyRight);
  if (pressedKeys.has('KeyQ')) flyDelta.add(WORLD_UP);
  if (pressedKeys.has('KeyE')) flyDelta.sub(WORLD_UP);
  if (flyDelta.lengthSq() === 0) return;

  flyDelta.normalize().multiplyScalar(currentMoveSpeed() * dt);
  camera.position.add(flyDelta);
}

scene.add(new THREE.HemisphereLight(0xffffff, 0x566070, 1.2));
const sun = new THREE.DirectionalLight(0xfff2dd, 1.0);
sun.position.set(600, 900, 400);
scene.add(sun);

function geodeticToEcef(latDeg, lonDeg, h) {
  const a = 6378137.0, f = 1 / 298.257223563, e2 = f * (2 - f);
  const lat = latDeg * Math.PI / 180, lon = lonDeg * Math.PI / 180;
  const s = Math.sin(lat), c = Math.cos(lat);
  const N = a / Math.sqrt(1 - e2 * s * s);
  return new THREE.Vector3(
    (N + h) * c * Math.cos(lon),
    (N + h) * c * Math.sin(lon),
    (N * (1 - e2) + h) * s
  );
}

function ecefToLocalMatrix(latDeg, lonDeg, h) {
  const origin = geodeticToEcef(latDeg, lonDeg, h);
  const lat = latDeg * Math.PI / 180, lon = lonDeg * Math.PI / 180;
  const sL = Math.sin(lat), cL = Math.cos(lat);
  const sN = Math.sin(lon), cN = Math.cos(lon);
  const east  = new THREE.Vector3(-sN,        cN,        0);
  const up    = new THREE.Vector3( cL * cN,   cL * sN,   sL);
  const north = new THREE.Vector3(-sL * cN,  -sL * sN,   cL);
  const south = north.clone().negate();
  const rot = new THREE.Matrix4().makeBasis(east, up, south).transpose();
  const trans = new THREE.Matrix4().makeTranslation(-origin.x, -origin.y, -origin.z);
  return new THREE.Matrix4().multiplyMatrices(rot, trans);
}

const localMatrix = ecefToLocalMatrix(STATION_LAT, STATION_LON, STATION_H);

setStatus('loading tileset…');

const dracoLoader = new DRACOLoader();
dracoLoader.setDecoderPath('https://www.gstatic.com/draco/v1/decoders/');

const gltfLoader = new GLTFLoader();
gltfLoader.setDRACOLoader(dracoLoader);
gltfLoader.register((parser) => new GLTFCesiumRTCExtension(parser));

const tiles = new TilesRenderer(TILESET_URL);
tiles.manager.addHandler(/\.gltf$/, gltfLoader);
tiles.manager.addHandler(/\.glb$/, gltfLoader);
tiles.setCamera(camera);
tiles.setResolutionFromRenderer(camera, renderer);
tiles.errorTarget = TILES_ERROR_TARGET;

const tilesContainer = new THREE.Group();
tilesContainer.matrixAutoUpdate = false;
tilesContainer.matrix.copy(localMatrix);
tilesContainer.matrixWorldNeedsUpdate = true;
tilesContainer.add(tiles.group);
scene.add(tilesContainer);

tiles.addEventListener('load-tile-set', () => setStatus('tileset loaded · streaming…'));
tiles.addEventListener('load-model', () => {
  setStatus(`streaming… loaded ${tiles.group.children.length} tiles`);
});
tiles.addEventListener('tiles-load-end', () => {
  setStatus(`ready · ${tiles.group.children.length} tiles`);
});
tiles.addEventListener('load-error', (e) => {
  console.error('[tiles] load-error', e);
  setStatus(`tile load error: ${e.error?.message || 'unknown'}`, true);
});

async function loadGroundTiles(latDeg, lonDeg, z = 17, half = 2) {
  const n = 2 ** z;
  const latRad = latDeg * Math.PI / 180;
  const cx = Math.floor((lonDeg + 180) / 360 * n);
  const cy = Math.floor((1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2 * n);

  const mPerDegLat = 111320;
  const mPerDegLon = 111320 * Math.cos(latRad);
  const loader = new THREE.TextureLoader();
  loader.setCrossOrigin('anonymous');

  const group = new THREE.Group();
  const jobs = [];

  for (let dy = -half; dy <= half; dy++) {
    for (let dx = -half; dx <= half; dx++) {
      const tx = cx + dx, ty = cy + dy;
      const url = `https://cyberjapandata.gsi.go.jp/xyz/${GROUND_LAYER}/${z}/${tx}/${ty}.${GROUND_EXT}`;

      const lon0 = tx / n * 360 - 180;
      const lon1 = (tx + 1) / n * 360 - 180;
      const lat0 = Math.atan(Math.sinh(Math.PI * (1 - 2 * ty / n))) * 180 / Math.PI;
      const lat1 = Math.atan(Math.sinh(Math.PI * (1 - 2 * (ty + 1) / n))) * 180 / Math.PI;

      const x0 = (lon0 - lonDeg) * mPerDegLon;
      const x1 = (lon1 - lonDeg) * mPerDegLon;
      const y0 = (lat0 - latDeg) * mPerDegLat;
      const y1 = (lat1 - latDeg) * mPerDegLat;

      const w = x1 - x0;
      const h = y0 - y1;

      jobs.push(loader.loadAsync(url).then((tex) => {
        tex.colorSpace = THREE.SRGBColorSpace;
        tex.anisotropy = 4;
        const mat = new THREE.MeshBasicMaterial({ map: tex, depthWrite: false });
        const geom = new THREE.PlaneGeometry(w, h);
        const mesh = new THREE.Mesh(geom, mat);
        mesh.rotation.x = -Math.PI / 2;
        mesh.position.set((x0 + x1) / 2, -0.5, -(y0 + y1) / 2);
        mesh.renderOrder = -1;
        group.add(mesh);
      }).catch((err) => console.warn('[ground] tile failed', url, err)));
    }
  }
  await Promise.all(jobs);
  scene.add(group);
  return group;
}

loadGroundTiles(STATION_LAT, STATION_LON, GROUND_ZOOM, GROUND_HALF);

addEventListener('resize', () => {
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
  tiles.setResolutionFromRenderer(camera, renderer);
});

const clock = new THREE.Clock();

function animate() {
  requestAnimationFrame(animate);
  updateFlyMovement(Math.min(clock.getDelta(), MAX_FRAME_DELTA));
  camera.updateMatrixWorld();
  scene.updateMatrixWorld(true);
  tiles.update();
  renderer.render(scene, camera);
}
animate();
