// Lost Meadows Predictions — watershed download map
// Vanilla MapLibre GL JS. Loads HUC10 boundary polygons + a manifest of Google
// Drive download links; clicking a watershed opens a popup of its files.

// ---------------------------------------------------------------------------
// Basemaps (key-free Esri tiles, matching the KMP map).
// ---------------------------------------------------------------------------
const basemaps = {
  topo: {
    tiles: ['https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}'],
    maxzoom: 19,
    attribution: 'Tiles &copy; Esri &mdash; Esri, USGS, NPS, NRCAN, and the GIS user community'
  },
  satellite: {
    tiles: ['https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'],
    maxzoom: 19,
    attribution: 'Tiles &copy; Esri &mdash; Source: Esri, Maxar, Earthstar Geographics, and the GIS community'
  }
};
const basemapIds = Object.keys(basemaps).map((k) => `basemap-${k}`);

// Availability -> fill color.
const AVAIL_COLOR = { full: '#1a9850', partial: '#fee08b', none: '#cccccc' };

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function prettySize(bytes) {
  if (bytes == null || isNaN(bytes)) return '';
  const b = Number(bytes);
  if (b >= 1024 ** 3) return (b / 1024 ** 3).toFixed(1) + ' GB';
  if (b >= 1024 ** 2) return (b / 1024 ** 2).toFixed(1) + ' MB';
  if (b >= 1024)      return Math.round(b / 1024) + ' KB';
  return b + ' B';
}

function linkRow(label, url, size) {
  const sz = size ? ` <span class="sz">(${prettySize(size)})</span>` : '';
  if (!url) return `<li class="pending">${label} <span class="sz">(link pending)</span></li>`;
  return `<li><a href="${url}" target="_blank" rel="noopener">${label}</a>${sz}</li>`;
}

// Classify a watershed's product list into full / partial.
function availability(products) {
  if (!products || !products.length) return 'none';
  const types = new Set(products.map((p) => p.type));
  const core = ['high', 'medium', 'raster'].every((t) => types.has(t));
  return core ? 'full' : 'partial';
}

// ---------------------------------------------------------------------------
// Build style + map
// ---------------------------------------------------------------------------
const style = {
  version: 8,
  sources: Object.fromEntries(
    Object.entries(basemaps).map(([key, def]) => [`basemap-${key}`, { type: 'raster', tileSize: 256, ...def }])
  ),
  layers: [
    { id: 'background', type: 'background', paint: { 'background-color': '#ffffff' } },
    ...Object.keys(basemaps).map((key) => ({
      id: `basemap-${key}`, type: 'raster', source: `basemap-${key}`,
      layout: { visibility: 'none' }, paint: { 'raster-opacity': key === 'topo' ? 0.85 : 1.0 }
    }))
  ],
  glyphs: 'https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf'
};

const map = new maplibregl.Map({
  container: 'map', style,
  center: [-119.5, 38.5], zoom: 5, minZoom: 3, maxZoom: 14
});
map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
map.addControl(new maplibregl.ScaleControl({ unit: 'imperial' }), 'bottom-right');

let MANIFEST = { watersheds: {}, grouped: {} };
let hoveredId = null;

// ---------------------------------------------------------------------------
// Popup HTML for a clicked watershed
// ---------------------------------------------------------------------------
function watershedPopup(props) {
  const huc = props.huc10;
  const entry = MANIFEST.watersheds[huc];
  const title = `${(entry && entry.name) || props.name || 'Watershed'} <span class="huc">${huc}</span>`;

  if (!entry || !entry.products || !entry.products.length) {
    return `<h3>${title}</h3><p class="muted">No published products for this watershed.</p>`;
  }
  const items = entry.products.map((p) => linkRow(p.label, p.drive_url, p.size)).join('');

  // Forest-level GeoPackage, if this watershed maps to one.
  let forestHtml = '';
  if (entry.forest && MANIFEST.grouped && MANIFEST.grouped.forests) {
    const f = MANIFEST.grouped.forests.find((x) => x.name === entry.forest);
    if (f) forestHtml = `<div class="forest"><strong>${entry.forest}</strong>` +
      `<ul class="links">${linkRow(f.label, f.drive_url, f.size)}</ul></div>`;
  }
  return `<h3>${title}</h3><ul class="links">${items}</ul>${forestHtml}`;
}

// ---------------------------------------------------------------------------
// Bulk-downloads panel
// ---------------------------------------------------------------------------
function renderBulk() {
  const g = MANIFEST.grouped || {};
  const parts = [];
  if (g.statewide && g.statewide.length) {
    parts.push('<div class="bulk-group"><strong>Statewide (smoothed)</strong><ul class="links">' +
      g.statewide.map((s) => linkRow(s.label, s.drive_url, s.size)).join('') + '</ul></div>');
  }
  if (g.full) {
    parts.push('<div class="bulk-group"><strong>Complete database</strong><ul class="links">' +
      linkRow(g.full.label, g.full.drive_url, g.full.size) + '</ul></div>');
  }
  if (g.forests && g.forests.length) {
    parts.push('<details class="bulk-group"><summary>Forest GeoPackages (' + g.forests.length + ')</summary>' +
      '<ul class="links">' + g.forests
        .slice().sort((a, b) => (a.name || '').localeCompare(b.name || ''))
        .map((f) => linkRow(f.label, f.drive_url, f.size)).join('') + '</ul></details>');
  }
  document.getElementById('bulk-links').innerHTML =
    parts.length ? parts.join('') : '<span class="muted">none</span>';
}

// ---------------------------------------------------------------------------
// Load data + wire the map
// ---------------------------------------------------------------------------
map.on('load', () => {
  Promise.all([
    fetch('data/huc10.geojson').then((r) => r.json()),
    fetch('data/manifest.json').then((r) => r.json()).catch(() => ({ watersheds: {}, grouped: {} }))
  ]).then(([geo, manifest]) => {
    MANIFEST = manifest;
    if (manifest.generated)
      document.getElementById('generated').textContent = 'Updated ' + manifest.generated;

    // Inject availability onto each feature so the fill can be data-driven.
    for (const f of geo.features) {
      const e = manifest.watersheds[f.properties.huc10];
      f.properties.avail = availability(e && e.products);
    }

    map.addSource('huc', { type: 'geojson', data: geo, generateId: true });
    map.addLayer({
      id: 'huc-fill', type: 'fill', source: 'huc',
      paint: {
        'fill-color': ['match', ['get', 'avail'],
          'full', AVAIL_COLOR.full, 'partial', AVAIL_COLOR.partial, AVAIL_COLOR.none],
        'fill-opacity': ['case', ['boolean', ['feature-state', 'hover'], false], 0.75, 0.5]
      }
    });
    map.addLayer({
      id: 'huc-line', type: 'line', source: 'huc',
      paint: {
        'line-color': '#33576e',
        'line-width': ['case', ['boolean', ['feature-state', 'hover'], false], 2.2, 0.6]
      }
    });

    renderBulk();

    // Hover emphasis via feature-state.
    map.on('mousemove', 'huc-fill', (e) => {
      map.getCanvas().style.cursor = 'pointer';
      if (!e.features.length) return;
      if (hoveredId !== null) map.setFeatureState({ source: 'huc', id: hoveredId }, { hover: false });
      hoveredId = e.features[0].id;
      map.setFeatureState({ source: 'huc', id: hoveredId }, { hover: true });
    });
    map.on('mouseleave', 'huc-fill', () => {
      map.getCanvas().style.cursor = '';
      if (hoveredId !== null) map.setFeatureState({ source: 'huc', id: hoveredId }, { hover: false });
      hoveredId = null;
    });

    // Click -> download popup.
    map.on('click', 'huc-fill', (e) => {
      const f = e.features && e.features[0];
      if (!f) return;
      new maplibregl.Popup({ closeButton: true, maxWidth: '320px' })
        .setLngLat(e.lngLat)
        .setHTML(watershedPopup(f.properties))
        .addTo(map);
    });

    const bbox = computeBounds(geo);
    if (bbox) map.fitBounds(bbox, { padding: 30, duration: 0, animate: false });
  }).catch((err) => {
    document.getElementById('loading').textContent = 'Failed to load map data.';
    console.error(err);
  });

  // Show the initially-checked basemap.
  const initial = document.querySelector('input[name="basemap"]:checked');
  if (initial) {
    const activeId = `basemap-${initial.value}`;
    for (const id of basemapIds)
      map.setLayoutProperty(id, 'visibility', id === activeId ? 'visible' : 'none');
  }
});

// ---------------------------------------------------------------------------
// Bounds helper — walks a FeatureCollection -> [[w,s],[e,n]]
// ---------------------------------------------------------------------------
function computeBounds(fc) {
  let w = Infinity, s = Infinity, e = -Infinity, n = -Infinity;
  const visit = (c) => {
    if (typeof c[0] === 'number') {
      if (c[0] < w) w = c[0]; if (c[0] > e) e = c[0];
      if (c[1] < s) s = c[1]; if (c[1] > n) n = c[1];
    } else for (const x of c) visit(x);
  };
  for (const f of (fc.features || [])) if (f.geometry) visit(f.geometry.coordinates);
  return isFinite(w) ? [[w, s], [e, n]] : null;
}

// ---------------------------------------------------------------------------
// UI wiring
// ---------------------------------------------------------------------------
const panel = document.getElementById('panel');
const panelToggle = document.getElementById('panel-toggle');
if (panelToggle) {
  panelToggle.addEventListener('click', () => {
    const collapsed = panel.classList.toggle('collapsed');
    panelToggle.textContent = collapsed ? '+' : '−';
    panelToggle.setAttribute('aria-expanded', (!collapsed).toString());
  });
}

const loadingEl = document.getElementById('loading');
if (loadingEl) {
  map.once('idle', () => {
    loadingEl.classList.add('hidden');
    setTimeout(() => loadingEl.remove(), 400);
  });
}

document.querySelectorAll('input[name="basemap"]').forEach((input) => {
  input.addEventListener('change', (ev) => {
    const activeId = `basemap-${ev.target.value}`;
    for (const id of basemapIds)
      map.setLayoutProperty(id, 'visibility', id === activeId ? 'visible' : 'none');
  });
});
