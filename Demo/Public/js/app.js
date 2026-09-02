// Wires the three screens together: pick an area, watch it build, explore it.

import { createPicker, PRESETS } from '/js/picker.js';
import { createViewer } from '/js/viewer.js';

const $ = (id) => document.getElementById(id);
const screens = { picker: $('screen-picker'), loading: $('screen-loading'), viewer: $('screen-viewer') };

function show(name) {
  Object.entries(screens).forEach(([key, el]) => el.classList.toggle('is-active', key === name));
}

const fmt = {
  m: (v) => (Number.isFinite(v) ? `${Math.round(v)} m` : '—'),
  km: (v) => `${v.toFixed(v < 10 ? 2 : 1)} km`,
  lat: (v) => `${Math.abs(v).toFixed(4)}°${v < 0 ? 'S' : 'N'}`,
  lon: (v) => `${Math.abs(v).toFixed(4)}°${v < 0 ? 'W' : 'E'}`,
  mb: (v) => `${(v / 1e6).toFixed(1)} MB`,
};

const state = {
  config: null, selection: null, picker: null, viewer: null, job: null,
  cancelled: false, rank: 0,
};

const metresPerDegreeLon = (lat) => 111320 * Math.cos((lat * Math.PI) / 180);
const METRES_PER_DEGREE_LAT = 110540;

// ── step 1 · picking ─────────────────────────────────────────────────────────

async function init() {
  state.config = await (await fetch('/api/config')).json();

  state.picker = createPicker({
    bounds: state.config.bounds,
    maxSpan: state.config.maxSpanDegrees,
    onChange: onSelectionChange,
  });

  const preset = $('preset');
  PRESETS.forEach((p, i) => {
    const option = document.createElement('option');
    option.value = String(i);
    option.textContent = p.name;
    preset.appendChild(option);
  });
  preset.addEventListener('change', () => {
    const chosen = PRESETS[Number(preset.value)];
    if (chosen) state.picker.goTo(chosen);
  });

  const dataset = $('dataset');
  state.config.datasets.forEach((d) => {
    const option = document.createElement('option');
    option.value = d.id;
    option.textContent = `${d.name} — ${d.resolutionMeters} m`;
    option.dataset.coverage = d.coverage;
    option.dataset.resolution = String(d.resolutionMeters);
    dataset.appendChild(option);
  });
  dataset.addEventListener('change', updateHints);

  $('build').addEventListener('click', build);
  $('back').addEventListener('click', () => { show('picker'); state.picker.invalidate(); });
  $('loading-cancel').addEventListener('click', cancel);

  wireViewerControls();
  updateHints();
}

function selectedDataset() {
  const option = $('dataset').selectedOptions[0];
  return {
    id: option?.value ?? 'glo30',
    coverage: option?.dataset.coverage ?? 'global',
    resolution: Number(option?.dataset.resolution ?? 30),
  };
}

function onSelectionChange(selection) {
  state.selection = selection;
  const readout = $('selection-readout');

  if (!selection) {
    readout.className = 'readout readout--empty';
    readout.textContent = 'Drag a box on the map to choose an area.';
    $('build').disabled = true;
    return;
  }

  const midLat = (selection.north + selection.south) / 2;
  const widthKm = ((selection.east - selection.west) * metresPerDegreeLon(midLat)) / 1000;
  const heightKm = ((selection.north - selection.south) * METRES_PER_DEGREE_LAT) / 1000;

  readout.className = 'readout';
  readout.innerHTML = `
    <div class="row"><span>north-west</span><b>${fmt.lat(selection.north)} ${fmt.lon(selection.west)}</b></div>
    <div class="row"><span>south-east</span><b>${fmt.lat(selection.south)} ${fmt.lon(selection.east)}</b></div>
    <div class="row"><span>size</span><b>${fmt.km(widthKm)} × ${fmt.km(heightKm)}</b></div>`;
  $('build').disabled = false;
  updateHints();
}

/** Predicts the native grid so the size of the request is obvious beforehand. */
function updateHints() {
  const dataset = selectedDataset();
  $('dataset-note').textContent =
    dataset.coverage === 'global'
      ? 'Global coverage, read directly from the source bucket.'
      : `Covers ${dataset.coverage} only.`;

  const hint = $('resolution-hint');
  const selection = state.selection;
  if (!selection) { hint.textContent = ''; $('picker-note').textContent = ''; return; }

  const midLat = (selection.north + selection.south) / 2;
  const widthM = (selection.east - selection.west) * metresPerDegreeLon(midLat);
  const heightM = (selection.north - selection.south) * METRES_PER_DEGREE_LAT;
  const cols = Math.round(widthM / dataset.resolution) + 1;
  const rows = Math.round(heightM / dataset.resolution) + 1;

  hint.textContent =
    `${cols}×${rows} · ~${dataset.resolution} m per sample · ${((cols * rows) / 1000).toFixed(0)}k vertices`;

  const areaKm2 = (widthM / 1000) * (heightM / 1000);
  const over = areaKm2 > state.config.maxAreaSquareKilometers;
  $('picker-note').textContent = over
    ? `That box is ${Math.round(areaKm2).toLocaleString()} km², over the ` +
      `${state.config.maxAreaSquareKilometers.toLocaleString()} km² limit — drag a smaller one.`
    : '';
  $('build').disabled = over;
}

// ── step 2 · building ────────────────────────────────────────────────────────

function setStep(id, cls) {
  const el = $(id);
  el.classList.remove('is-active', 'is-done');
  if (cls) el.classList.add(cls);
}

function setProgress(fraction, message) {
  $('loading-bar').style.width = `${(fraction * 100).toFixed(1)}%`;
  if (message) $('loading-status').textContent = message;
}

// Elevation and imagery are fetched concurrently, so they share a rank: neither
// finishing marks the other done. Only reaching the mesh does.
const STEPS = [
  { id: 'step-dem', channel: 'elevation', rank: 0 },
  { id: 'step-tex', channel: 'imagery', rank: 0 },
  { id: 'step-mesh', channel: 'mesh', rank: 1 },
  { id: 'step-load', channel: 'export', rank: 2 },
];

function markSteps(channel) {
  const step = STEPS.find((s) => s.channel === channel);
  if (!step) return;
  state.rank = Math.max(state.rank, step.rank);
  STEPS.forEach((s) => {
    if (s.skipped) return;
    if (s.rank < state.rank) setStep(s.id, 'is-done');
    else if (s.rank === state.rank) setStep(s.id, 'is-active');
  });
}

async function cancel() {
  state.cancelled = true;
  if (state.job) fetch(`/api/terrain/${state.job}`, { method: 'DELETE' }).catch(() => {});
  show('picker');
  state.picker.invalidate();
}

async function build() {
  const selection = state.selection;
  if (!selection) return;

  state.cancelled = false;
  show('loading');
  $('loading-error').textContent = '';
  STEPS.forEach((s) => { s.skipped = false; setStep(s.id, null); });
  state.rank = 0;
  setProgress(0, 'Starting');

  const midLat = (selection.north + selection.south) / 2;
  const widthKm = ((selection.east - selection.west) * metresPerDegreeLon(midLat)) / 1000;
  const heightKm = ((selection.north - selection.south) * METRES_PER_DEGREE_LAT) / 1000;
  $('loading-area').textContent =
    `${fmt.lat(selection.north)} ${fmt.lon(selection.west)} → ${fmt.lat(selection.south)} ${fmt.lon(selection.east)}  ·  ${fmt.km(widthKm)} × ${fmt.km(heightKm)}`;

  const textureResolution = Number($('texture').value);
  if (textureResolution === 0) {
    const step = STEPS.find((s) => s.channel === 'imagery');
    step.skipped = true;
    setStep(step.id, 'is-done');
  }

  const body = {
    bounds: selection,
    dataset: selectedDataset().id,
    textureResolution,
  };

  try {
    const started = await (await fetch('/api/terrain', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    })).json();
    if (!started.id) throw new Error(started.error?.message ?? 'could not start the build');
    state.job = started.id;

    const summary = await poll(started.id);
    if (state.cancelled) return;

    setStep('step-mesh', 'is-done');
    setStep('step-load', 'is-active');
    setProgress(0.98, 'Loading it into the viewer');

    const buffer = await (await fetch(`/api/terrain/${started.id}/model`)).arrayBuffer();
    if (!state.viewer) state.viewer = createViewer($('viewport'));
    await state.viewer.load(buffer);

    setStep('step-load', 'is-done');
    setProgress(1, 'Ready');
    present(summary);
    show('viewer');
    state.viewer.resize();
  } catch (error) {
    if (state.cancelled) return;
    $('loading-error').textContent = String(error.message || error);
    setProgress(0, 'Failed');
  }
}

/**
 * Polls the job endpoint. The bar shows what the server reports and nothing
 * else — the fraction is real work finished, weighted across the fetches, so
 * there is no easing here to invent movement the build is not making. The CSS
 * transition on .bar__fill smooths the steps.
 */
async function poll(id) {
  for (;;) {
    if (state.cancelled) throw new Error('cancelled');
    const status = await (await fetch(`/api/terrain/${id}`)).json();
    if (status.state === 'failed') throw new Error(status.error ?? 'the build failed');

    // Leave the last sliver for loading the model into three.js, which the
    // server knows nothing about.
    setProgress((status.progress ?? 0) * 0.95, status.message);
    markSteps(status.channel);

    if (status.state === 'done') return status.summary;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}

// ── step 3 · viewing ─────────────────────────────────────────────────────────

function present(s) {
  if (!s) return;
  $('viewer-title').textContent = s.dataset;
  $('viewer-extent').textContent =
    `${(s.widthMeters / 1000).toFixed(2)} × ${(s.heightMeters / 1000).toFixed(2)} km · ` +
    `${s.gridWidth}×${s.gridHeight} · ~${s.sampleSpacingMeters.toFixed(1)} m per sample`;

  const texture = s.textureWidth ? `${s.textureWidth}×${s.textureHeight}` : 'none';
  $('stats').innerHTML = `
    <div class="row"><span>elevation</span><span>${fmt.m(s.minElevation)} – ${fmt.m(s.maxElevation)}</span></div>
    <div class="row"><span>vertices</span><span>${s.vertexCount.toLocaleString()}</span></div>
    <div class="row"><span>triangles</span><span>${s.triangleCount.toLocaleString()}</span></div>
    <div class="row"><span>texture</span><span>${texture}</span></div>
    <div class="row"><span>glTF size</span><span>${fmt.mb(s.byteCount)}</span></div>
    <div class="row"><span>built in</span><span>${s.seconds.toFixed(1)} s</span></div>`;

  $('exaggeration').value = '100';
  $('exag-hint').textContent = '1.00×';
  state.viewer?.setExaggeration(1);
}

function wireViewerControls() {
  document.querySelectorAll('#surface-mode button').forEach((button) => {
    button.addEventListener('click', () => {
      document.querySelectorAll('#surface-mode button')
        .forEach((b) => b.classList.toggle('is-active', b === button));
      state.viewer?.setSurfaceMode(button.dataset.mode);
    });
  });

  // 0 is a flat plane, 1 is true scale, 2 is twice the relief.
  $('exaggeration').addEventListener('input', (e) => {
    const value = Number(e.target.value) / 100;
    $('exag-hint').textContent = `${value.toFixed(2)}×`;
    state.viewer?.setExaggeration(value);
  });
}

init().catch((error) => {
  $('picker-note').textContent = `Could not reach the server: ${error.message || error}`;
});
