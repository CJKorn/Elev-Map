// Leaflet-based area picker: drag anywhere on the map to draw a box, then nudge its corners.

const AU_STYLE = {
  color: '#4da3ff', weight: 1, opacity: 0.5,
  fillColor: '#4da3ff', fillOpacity: 0.04, dashArray: '5 6', interactive: false,
};
const SEL_STYLE = {
  color: '#4da3ff', weight: 2, opacity: 1,
  fillColor: '#4da3ff', fillOpacity: 0.15, interactive: false,
};

export const PRESETS = [
  { name: 'Jungfrau, Switzerland',      lat:  46.535, lon:   7.965, span: 0.060 },
  { name: 'Grand Canyon, Arizona',      lat:  36.100, lon: -112.110, span: 0.090 },
  { name: 'Mount Fuji, Japan',          lat:  35.363, lon: 138.731, span: 0.080 },
  { name: 'Sydney Harbour, NSW',        lat: -33.855, lon: 151.215, span: 0.055 },
  { name: 'Blue Mountains, NSW',        lat: -33.730, lon: 150.310, span: 0.130 },
  { name: 'Melbourne CBD, VIC',         lat: -37.815, lon: 144.960, span: 0.055 },
  { name: 'Brisbane CBD, QLD',          lat: -27.470, lon: 153.022, span: 0.055 },
  { name: 'Perth CBD, WA',              lat: -31.953, lon: 115.860, span: 0.055 },
  { name: 'Adelaide & the hills, SA',   lat: -34.940, lon: 138.680, span: 0.140 },
  { name: 'Canberra, ACT',              lat: -35.290, lon: 149.130, span: 0.090 },
  { name: 'Hobart & Mt Wellington, TAS',lat: -42.895, lon: 147.255, span: 0.110 },
  { name: 'Uluru, NT',                  lat: -25.345, lon: 131.035, span: 0.075 },
  { name: 'Kata Tjuta, NT',             lat: -25.300, lon: 130.735, span: 0.090 },
  { name: 'Mount Kosciuszko, NSW',      lat: -36.456, lon: 148.263, span: 0.130 },
  { name: 'The Grampians, VIC',         lat: -37.150, lon: 142.520, span: 0.160 },
  { name: 'Cradle Mountain, TAS',       lat: -41.685, lon: 145.945, span: 0.110 },
  { name: 'Daintree rainforest, QLD',   lat: -16.170, lon: 145.420, span: 0.110 },
  { name: 'Katoomba & Jamison Valley',  lat: -33.730, lon: 150.310, span: 0.060 },
  { name: 'Wilpena Pound, SA',          lat: -31.545, lon: 138.590, span: 0.150 },
  { name: 'Karijini gorges, WA',        lat: -22.470, lon: 118.280, span: 0.140 },
  { name: 'Gold Coast high-rises, QLD', lat: -28.005, lon: 153.425, span: 0.050 },
];

export function createPicker({ bounds, maxSpan, onChange }) {
  const coverage = L.latLngBounds([bounds.south, bounds.west], [bounds.north, bounds.east]);
  // Worldwide bounds need no coverage outline; a regional dataset would.
  const isGlobal = bounds.east - bounds.west > 300;

  const map = L.map('map', {
    center: [30, 10],
    zoom: 3,
    minZoom: 3,
    maxZoom: 17,
    zoomControl: true,
    // The box is drawn with the left button, so box-zoom would fight it.
    boxZoom: false,
    worldCopyJump: false,
  });

  L.tileLayer('/api/tiles/osm/{z}/{x}/{y}.png', { maxZoom: 17, crossOrigin: true }).addTo(map);
  if (!isGlobal) L.rectangle(coverage, AU_STYLE).addTo(map);

  const mapEl = document.getElementById('map');
  let rect = null;
  let handles = [];
  let selection = null;
  let drawing = null;

  function emit() {
    onChange(selection);
  }

  /** Clamps a box to the coverage area and to the maximum span, holding `anchor` fixed. */
  function clampBox(anchor, corner) {
    let west = Math.min(anchor.lng, corner.lng);
    let east = Math.max(anchor.lng, corner.lng);
    let south = Math.min(anchor.lat, corner.lat);
    let north = Math.max(anchor.lat, corner.lat);

    if (east - west > maxSpan) {
      if (corner.lng > anchor.lng) east = west + maxSpan; else west = east - maxSpan;
    }
    if (north - south > maxSpan) {
      if (corner.lat > anchor.lat) north = south + maxSpan; else south = north - maxSpan;
    }
    west = Math.max(west, bounds.west);
    east = Math.min(east, bounds.east);
    south = Math.max(south, bounds.south);
    north = Math.min(north, bounds.north);
    return { west, south, east, north };
  }

  function clearHandles() {
    handles.forEach((h) => map.removeLayer(h));
    handles = [];
  }

  function drawHandles() {
    clearHandles();
    if (!selection) return;
    const { west, south, east, north } = selection;
    const corners = [
      [north, west], [north, east], [south, east], [south, west],
    ];
    corners.forEach((corner, i) => {
      const handle = L.marker(corner, {
        draggable: true,
        keyboard: false,
        icon: L.divIcon({ className: 'sel-handle', iconSize: [12, 12] }),
      }).addTo(map);

      handle.on('drag', () => {
        // The diagonally opposite corner stays put while this one moves.
        const opposite = corners[(i + 2) % 4];
        selection = clampBox(L.latLng(opposite[0], opposite[1]), handle.getLatLng());
        rect.setBounds(toLatLngBounds(selection));
        emit();
      });
      handle.on('dragend', () => { setSelection(selection); });
      handles.push(handle);
    });
  }

  function toLatLngBounds(box) {
    return L.latLngBounds([box.south, box.west], [box.north, box.east]);
  }

  function setSelection(box, { fit = false } = {}) {
    selection = box;
    if (!rect) {
      rect = L.rectangle(toLatLngBounds(box), SEL_STYLE).addTo(map);
    } else {
      rect.setBounds(toLatLngBounds(box));
    }
    drawHandles();
    if (fit) map.fitBounds(toLatLngBounds(box), { padding: [60, 60], maxZoom: 15 });
    emit();
  }

  // ── drag to draw ──────────────────────────────────────────────────────────
  map.on('mousedown', (event) => {
    if (event.originalEvent.button !== 0) return;
    // Corner handles have their own drag behaviour.
    if (event.originalEvent.target.closest('.sel-handle')) return;

    drawing = { anchor: event.latlng };
    map.dragging.disable();
    mapEl.classList.add('is-drawing');
    clearHandles();
  });

  map.on('mousemove', (event) => {
    if (!drawing) return;
    const box = clampBox(drawing.anchor, event.latlng);
    if (!rect) {
      rect = L.rectangle(toLatLngBounds(box), SEL_STYLE).addTo(map);
    } else {
      rect.setBounds(toLatLngBounds(box));
    }
    drawing.box = box;
  });

  function endDraw() {
    if (!drawing) return;
    const box = drawing.box;
    drawing = null;
    map.dragging.enable();
    mapEl.classList.remove('is-drawing');
    // A click without a drag is not a selection; restore whatever was there.
    if (!box || box.east - box.west < 1e-4 || box.north - box.south < 1e-4) {
      if (selection) setSelection(selection);
      else if (rect) { map.removeLayer(rect); rect = null; }
      return;
    }
    setSelection(box);
  }

  map.on('mouseup', endDraw);
  map.on('mouseout', (event) => { if (!event.originalEvent.relatedTarget) endDraw(); });

  function centredBox(lat, lon, span) {
    // Longitude spans shrink with latitude on screen; keep the box roughly square on
    // the ground by widening it as we move away from the equator.
    const lonSpan = Math.min(maxSpan, span / Math.cos((lat * Math.PI) / 180));
    const latSpan = Math.min(maxSpan, span);
    return {
      west: lon - lonSpan / 2, east: lon + lonSpan / 2,
      south: lat - latSpan / 2, north: lat + latSpan / 2,
    };
  }

  return {
    map,
    setSelection,
    goTo(preset) { setSelection(centredBox(preset.lat, preset.lon, preset.span), { fit: true }); },
    invalidate() { map.invalidateSize(); },
  };
}
