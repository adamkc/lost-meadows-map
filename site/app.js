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
  hillshade: {
    // USGS 3DEP multidirectional hillshade, served at best-available resolution
    // (1 m where lidar exists). WMS-style ImageServer export; {bbox-epsg-3857}
    // is filled per tile by MapLibre.
    tiles: ['https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/exportImage?bbox={bbox-epsg-3857}&bboxSR=3857&imageSR=3857&size=256,256&format=png&f=image&renderingRule=%7B%22rasterFunction%22%3A%22Hillshade%20Multidirectional%22%7D'],
    maxzoom: 17,
    attribution: 'Hillshade &mdash; USGS 3DEP (multidirectional, 1&nbsp;m where available)'
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

// Watersheds added within this many days get a distinct "recently added" border.
// Driven by each feature's `added` ISO date (stamped by process_inbox.R); the
// highlight auto-expires, so the map never accumulates stale "new" flags.
const NEW_DAYS = 30;
const NEW_COLOR = '#00bcd4';
function isRecentlyAdded(added) {
  if (!added) return false;
  const t = Date.parse(added);
  return !isNaN(t) && (Date.now() - t) / 86400000 <= NEW_DAYS;
}

// ---------------------------------------------------------------------------
// Download tracking (optional — logs WHICH files get downloaded, by watershed).
// Two independent sinks; either can be left off:
//   1. TRACK_ENDPOINT — a Google Apps Script web-app URL that appends one row
//      per download to a Google Sheet in your Drive. See tracking/README.md.
//      Leave '' to disable. Paste your deployed /exec URL here to enable.
//   2. GoatCounter   — set data-goatcounter in index.html; events fire below.
// Every download <a> carries data-* attrs; one delegated listener reports them.
// Tracking never blocks or breaks a download (all wrapped in try/catch).
// ---------------------------------------------------------------------------
const TRACK_ENDPOINT = 'https://script.google.com/macros/s/AKfycbyg5kluonqs0eG8fO01OmbQDPqgSDZsDmcRQHHOCl6c3nwxbE_0JDUDZI5dwMmt7E5r/exec';

// --- Visitor registration (name/org/goal/email), stored locally ---
// Downloads are gated: the first download by an un-registered visitor opens the
// registration modal; once registered (name + org), every download row carries
// who they are. Stored in localStorage so a visitor is asked only once.
function getUser() {
  try { const s = localStorage.getItem('lm_user'); return s ? JSON.parse(s) : null; }
  catch (e) { return null; }
}
function isRegistered() {
  const u = getUser();
  return !!(u && u.name && u.org);
}
function readForm(form) {
  const v = (n) => (form.elements[n] ? form.elements[n].value : '').trim();
  return { name: v('name'), org: v('org'), goal: v('goal'), email: v('email') };
}
// Save + log a registration row. Returns the stored user.
function register(data) {
  const u = { name: data.name || '', org: data.org || '', goal: data.goal || '', email: data.email || '' };
  try { localStorage.setItem('lm_user', JSON.stringify(u)); } catch (e) {}
  try {
    if (TRACK_ENDPOINT && navigator.sendBeacon) {
      navigator.sendBeacon(TRACK_ENDPOINT, JSON.stringify({
        event: 'register', user_name: u.name, org: u.org, goal: u.goal, email: u.email,
        ref: location.href
      }));
    }
    if (window.goatcounter && window.goatcounter.count) {
      window.goatcounter.count({ path: 'register', title: 'Register: ' + (u.org || u.name), event: true });
    }
  } catch (e) { /* best-effort */ }
  return u;
}

function trackDownload(d) {
  // d = { huc, name, prod, scope } from the clicked link's data-* attributes.
  const u = getUser() || {};
  try {
    if (TRACK_ENDPOINT && navigator.sendBeacon) {
      navigator.sendBeacon(TRACK_ENDPOINT, JSON.stringify({
        event: 'download',
        user_name: u.name || '', org: u.org || '', goal: u.goal || '', email: u.email || '',
        huc: d.huc || '', feature: d.name || '', prod: d.prod || '', scope: d.scope || '',
        ref: location.href
      }));
    }
    if (window.goatcounter && window.goatcounter.count) {
      window.goatcounter.count({
        path: 'dl/' + (d.scope || 'x') + '/' + (d.prod || 'x') + (d.huc ? '/' + d.huc : ''),
        title: 'Download: ' + (d.name || d.prod || 'file'),
        event: true
      });
    }
  } catch (e) { /* tracking is best-effort; never interrupt the download */ }
}

// Delegated download handler. If the visitor is registered, the link opens
// normally and we log it. Otherwise we stop the link, stash it, and open the
// registration modal; completing the form resumes the download.
let pendingDownload = null;
document.addEventListener('click', (e) => {
  if (!e.target.closest) return;
  const dl = e.target.closest('a[data-dl]');
  if (dl) {
    if (isRegistered()) { trackDownload(dl.dataset); return; }
    e.preventDefault();
    pendingDownload = { href: dl.href, dataset: Object.assign({}, dl.dataset) };
    openRegModal();
    return;
  }
  // Request links (un-analyzed watersheds) open the mailto normally; just log.
  const rq = e.target.closest('a[data-req]');
  if (rq) trackRequest(rq.dataset.huc, rq.dataset.name);
});

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

function escAttr(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
}

function linkRow(label, url, size, meta) {
  const sz = size ? ` <span class="sz">(${prettySize(size)})</span>` : '';
  if (!url) return `<li class="pending">${label} <span class="sz">(link pending)</span></li>`;
  const data = meta
    ? ` data-dl="1" data-huc="${escAttr(meta.huc)}" data-name="${escAttr(meta.name)}"` +
      ` data-prod="${escAttr(meta.prod)}" data-scope="${escAttr(meta.scope)}"`
    : '';
  return `<li><a href="${url}" target="_blank" rel="noopener"${data}>${label}</a>${sz}</li>`;
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
  center: [-119.5, 38.5], zoom: 5, minZoom: 3, maxZoom: 17
});
map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
map.addControl(new maplibregl.ScaleControl({ unit: 'imperial' }), 'bottom-right');

let MANIFEST = { watersheds: {}, grouped: {} };
let BOUNDARY = null;
let hoveredId = null;

// Prediction overlay layers — PMTiles vector tiles, filterable by HUC10.
maplibregl.addProtocol('pmtiles', new pmtiles.Protocol().tile);
const PRED = {
  high:   { url: 'pmtiles://data/predictions_high.pmtiles',   color: '#d73027', label: 'high-confidence' },
  medium: { url: 'pmtiles://data/predictions_medium.pmtiles', color: '#f46d43', label: 'medium-confidence' }
};
const PRED_SOURCE_LAYER = 'predictions';
const predState = { high: { loaded: false }, medium: { loaded: false } };

// "Not yet analyzed" watersheds (western US) — PMTiles vector tiles, drawn under
// the analyzed layer. Clicking one opens a mailto to request its outputs.
const UNANALYZED = {
  url: 'pmtiles://data/huc10_unanalyzed.pmtiles',
  sourceLayer: 'unanalyzed',
  email: 'acummings@thewatershedcenter.com'
};

async function ensurePred(conf) {
  if (predState[conf].loaded) return;
  const cfg = PRED[conf], id = 'pred-' + conf;
  map.addSource(id, { type: 'vector', url: cfg.url });
  map.addLayer({ id: id + '-fill', type: 'fill', source: id, 'source-layer': PRED_SOURCE_LAYER,
    layout: { visibility: 'none' },
    paint: { 'fill-color': cfg.color,
      // Fade the fill out when zoomed in close so the basemap/imagery shows
      // through the polygon; the outline stays.
      'fill-opacity': ['interpolate', ['linear'], ['zoom'], 11, 0.55, 13, 0.32, 14.5, 0.1, 15, 0] } });
  map.addLayer({ id: id + '-line', type: 'line', source: id, 'source-layer': PRED_SOURCE_LAYER,
    layout: { visibility: 'none' },
    paint: { 'line-color': cfg.color,
      'line-width': ['interpolate', ['linear'], ['zoom'], 11, 0.5, 14, 1.1, 17, 1.8] } });
  predState[conf].loaded = true;
}
function setPredVisible(conf, visible) {
  const v = visible ? 'visible' : 'none';
  for (const sfx of ['-fill', '-line'])
    if (map.getLayer('pred-' + conf + sfx)) map.setLayoutProperty('pred-' + conf + sfx, 'visibility', v);
  const box = document.querySelector('input[data-pred="' + conf + '"]');
  if (box) box.checked = visible;
}
// One watershed at a time. `selectedHuc` is the watershed currently shown; the
// overlay layers are always filtered to it.
let selectedHuc = null;
function filterPred(conf, huc) {
  const f = ['==', ['get', 'huc10'], huc || '__none__'];
  for (const sfx of ['-fill', '-line'])
    if (map.getLayer('pred-' + conf + sfx)) map.setFilter('pred-' + conf + sfx, f);
}
function predVisible(conf) {
  return map.getLayer('pred-' + conf + '-fill') &&
         map.getLayoutProperty('pred-' + conf + '-fill', 'visibility') === 'visible';
}
// From a popup: show this confidence for THIS watershed, switch the selection
// (re-filtering any other visible confidence to the same watershed), and zoom.
async function viewPolys(conf, huc) {
  if (!predState[conf].loaded) toast('Loading ' + PRED[conf].label + ' polygons…');
  selectedHuc = huc;
  await ensurePred(conf);
  filterPred(conf, huc);
  for (const other of ['high', 'medium']) if (other !== conf && predVisible(other)) filterPred(other, huc);
  setPredVisible(conf, true);
  hideToast();
  const b = boundsForHuc(huc);
  if (b) map.fitBounds(b, { padding: 40, maxZoom: 13, duration: 600 });
}
window.viewPolys = viewPolys;

function boundsForHuc(huc) {
  if (!BOUNDARY) return null;
  const f = BOUNDARY.features.find((x) => x.properties.huc10 === huc);
  return f ? computeBounds({ features: [f] }) : null;
}
function toast(msg) { const t = document.getElementById('toast'); if (t) { t.textContent = msg; t.classList.add('show'); } }
function hideToast() { const t = document.getElementById('toast'); if (t) t.classList.remove('show'); }

// ---------------------------------------------------------------------------
// Popup HTML for a clicked watershed
// ---------------------------------------------------------------------------
function watershedPopup(props) {
  const huc = props.huc10;
  const entry = MANIFEST.watersheds[huc];
  const tag = props.isnew ? ' <span class="newtag">recently added</span>' : '';
  const title = `${(entry && entry.name) || props.name || 'Watershed'} <span class="huc">${huc}</span>${tag}`;

  if (!entry || !entry.products || !entry.products.length) {
    return `<h3>${title}</h3><p class="muted">No published products for this watershed.</p>`;
  }
  const items = entry.products.map((p) =>
    linkRow(p.label, p.drive_url, p.size,
      { huc, name: entry.name, prod: p.type, scope: 'watershed' })).join('');

  // "View on map" — only for confidence layers we have an overlay for.
  const canHigh = entry.products.some((p) => p.type === 'high');
  const canMed  = entry.products.some((p) => p.type === 'medium');
  let vizHtml = '';
  if (canHigh || canMed) {
    vizHtml = '<div class="viz">View on map: ' +
      (canHigh ? `<button class="viewbtn" onclick="viewPolys('high','${huc}')">high</button>` : '') +
      (canMed  ? `<button class="viewbtn" onclick="viewPolys('medium','${huc}')">medium</button>` : '') +
      '</div>';
  }

  // Forest-level GeoPackage, if this watershed maps to one.
  let forestHtml = '';
  if (entry.forest && MANIFEST.grouped && MANIFEST.grouped.forests) {
    const f = MANIFEST.grouped.forests.find((x) => x.name === entry.forest);
    if (f) forestHtml = `<div class="forest"><strong>${entry.forest}</strong>` +
      `<ul class="links">${linkRow(f.label, f.drive_url, f.size,
        { huc, name: entry.forest, prod: 'forest', scope: 'forest' })}</ul></div>`;
  }
  return `<h3>${title}</h3><ul class="links">${items}</ul>${vizHtml}${forestHtml}`;
}

// Popup for an un-analyzed watershed: a prefilled mailto to request its outputs.
function requestPopup(props) {
  const huc = props.huc10 || '';
  const name = props.name || 'This watershed';
  const subject = 'Request Lost Meadows outputs for HUC ' + huc;
  const body = 'Hi Adam,\n\nPlease send the Lost Meadows model outputs for HUC10 ' + huc +
    (props.name ? ' (' + props.name + ')' : '') +
    '.\n\nName:\nOrganization:\nIntended use:\n\nThank you.';
  const mailto = 'mailto:' + UNANALYZED.email +
    '?subject=' + encodeURIComponent(subject) + '&body=' + encodeURIComponent(body);
  return `<h3>${name} <span class="huc">${huc}</span></h3>` +
    `<p class="muted">Not analyzed yet — no published outputs for this watershed.</p>` +
    `<p><a href="${mailto}" class="req-link" data-req="1" data-huc="${escAttr(huc)}" ` +
      `data-name="${escAttr(name)}">Email to request outputs</a></p>` +
    `<p class="req-note">Or email <strong>${UNANALYZED.email}</strong> with the code ` +
      `<strong>${huc}</strong>.</p>`;
}

// Log a request (event=request) when someone clicks the "Email to request" link.
function trackRequest(huc, name) {
  const u = getUser() || {};
  try {
    if (TRACK_ENDPOINT && navigator.sendBeacon) {
      navigator.sendBeacon(TRACK_ENDPOINT, JSON.stringify({
        event: 'request', user_name: u.name || '', org: u.org || '', goal: u.goal || '',
        email: u.email || '', huc: huc || '', feature: name || '', prod: 'request',
        scope: 'unanalyzed', ref: location.href
      }));
    }
    if (window.goatcounter && window.goatcounter.count) {
      window.goatcounter.count({ path: 'request/' + (huc || 'x'), title: 'Request: ' + (name || huc), event: true });
    }
  } catch (e) { /* best-effort */ }
}

// ---------------------------------------------------------------------------
// Bulk-downloads panel
// ---------------------------------------------------------------------------
function renderBulk() {
  const g = MANIFEST.grouped || {};
  const parts = [];
  if (g.statewide && g.statewide.length) {
    parts.push('<div class="bulk-group"><strong>Statewide (all watersheds)</strong><ul class="links">' +
      g.statewide.map((s) => linkRow(s.label, s.drive_url, s.size,
        { prod: s.type, scope: 'statewide' })).join('') + '</ul></div>');
  }
  if (g.full) {
    parts.push('<div class="bulk-group"><strong>Complete database</strong><ul class="links">' +
      linkRow(g.full.label, g.full.drive_url, g.full.size,
        { prod: 'full', scope: 'full' }) + '</ul></div>');
  }
  if (g.forests && g.forests.length) {
    parts.push('<details class="bulk-group"><summary>Forest GeoPackages (' + g.forests.length + ')</summary>' +
      '<ul class="links">' + g.forests
        .slice().sort((a, b) => (a.name || '').localeCompare(b.name || ''))
        .map((f) => linkRow(f.label, f.drive_url, f.size,
          { name: f.name, prod: 'forest', scope: 'forest' })).join('') + '</ul></details>');
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
    BOUNDARY = geo;
    if (manifest.generated)
      document.getElementById('generated').textContent = 'Updated ' + manifest.generated;

    // Inject availability + recency onto each feature so styling can be data-driven.
    for (const f of geo.features) {
      const e = manifest.watersheds[f.properties.huc10];
      f.properties.avail = availability(e && e.products);
      f.properties.isnew = isRecentlyAdded(f.properties.added);
    }

    // "Not yet analyzed" watersheds first, so the analyzed layer sits on top.
    map.addSource('unanalyzed', { type: 'vector', url: UNANALYZED.url });
    map.addLayer({
      id: 'unanalyzed-fill', type: 'fill', source: 'unanalyzed', 'source-layer': UNANALYZED.sourceLayer,
      layout: { visibility: 'none' },   // off by default; toggled via the legend checkbox
      paint: {
        'fill-color': '#9aa0a6',
        'fill-opacity': ['interpolate', ['linear'], ['zoom'], 4, 0.12, 8, 0.07, 11, 0.04]
      }
    });
    map.addLayer({
      id: 'unanalyzed-line', type: 'line', source: 'unanalyzed', 'source-layer': UNANALYZED.sourceLayer,
      layout: { visibility: 'none' },
      paint: {
        'line-color': '#7b818a', 'line-opacity': 0.55,
        'line-width': ['interpolate', ['linear'], ['zoom'], 4, 0.3, 8, 0.6, 11, 0.9],
        'line-dasharray': [2, 2]
      }
    });
    map.on('mouseenter', 'unanalyzed-fill', () => { map.getCanvas().style.cursor = 'pointer'; });
    map.on('mouseleave', 'unanalyzed-fill', () => { map.getCanvas().style.cursor = ''; });
    map.on('click', 'unanalyzed-fill', (e) => {
      const f = e.features && e.features[0];
      if (!f) return;
      new maplibregl.Popup({ closeButton: true, maxWidth: '300px' })
        .setLngLat(e.lngLat).setHTML(requestPopup(f.properties)).addTo(map);
    });

    map.addSource('huc', { type: 'geojson', data: geo, generateId: true });
    map.addLayer({
      id: 'huc-fill', type: 'fill', source: 'huc',
      paint: {
        'fill-color': ['match', ['get', 'avail'],
          'full', AVAIL_COLOR.full, 'partial', AVAIL_COLOR.partial, AVAIL_COLOR.none],
        // Light overall; fades to fully transparent once zoomed into ~a single
        // watershed so the prediction overlay and basemap read cleanly.
        'fill-opacity': [
          'interpolate', ['linear'], ['zoom'],
          6,    ['case', ['boolean', ['feature-state', 'hover'], false], 0.40, 0.28],
          9,    ['case', ['boolean', ['feature-state', 'hover'], false], 0.22, 0.12],
          10.5, 0
        ]
      }
    });
    map.addLayer({
      id: 'huc-line', type: 'line', source: 'huc',
      paint: {
        // Recently added -> bright cyan; training (core) -> purple; else slate.
        'line-color': ['case',
          ['boolean', ['get', 'isnew'], false], NEW_COLOR,
          ['get', 'core'], '#6a3d9a', '#33576e'],
        'line-width': ['case',
          ['boolean', ['feature-state', 'hover'], false], 2.4,
          ['boolean', ['get', 'isnew'], false], 2.0,
          ['get', 'core'], 1.5, 0.5],
        'line-opacity': ['case',
          ['boolean', ['get', 'isnew'], false], 1.0,
          ['get', 'core'], 0.95, 0.65]
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

// Toggle the "not yet analyzed" request layer.
const unToggle = document.getElementById('toggle-unanalyzed');
if (unToggle) unToggle.addEventListener('change', (ev) => {
  const v = ev.target.checked ? 'visible' : 'none';
  for (const id of ['unanalyzed-fill', 'unanalyzed-line'])
    if (map.getLayer(id)) map.setLayoutProperty(id, 'visibility', v);
});

// Prediction overlay checkboxes — toggle high/medium for the selected watershed.
document.querySelectorAll('input[data-pred]').forEach((input) => {
  input.addEventListener('change', async (ev) => {
    const conf = ev.target.dataset.pred;
    if (ev.target.checked) {
      if (!selectedHuc) {
        ev.target.checked = false;
        toast('Click a watershed, then choose “View on map”.');
        setTimeout(hideToast, 2400);
        return;
      }
      await ensurePred(conf);
      filterPred(conf, selectedHuc);
      setPredVisible(conf, true);
    } else {
      setPredVisible(conf, false);
    }
  });
});

// Intro splash — shown on every load until dismissed; reopen via "About this map".
// Carries the registration form (optional here; enforced at first download).
const splash = document.getElementById('splash');
if (splash) {
  const hideSplash = () => splash.classList.add('hidden');
  const splashForm = document.getElementById('splash-form');
  prefillForm(splashForm);
  document.getElementById('splash-close').addEventListener('click', hideSplash);
  // "Enter the map": register if name + org are filled, otherwise just browse
  // (the download gate will ask later). Either way, dismiss the splash.
  if (splashForm) splashForm.addEventListener('submit', (e) => {
    e.preventDefault();
    const data = readForm(splashForm);
    if (data.name && data.org) register(data);
    hideSplash();
  });
  const about = document.getElementById('about-link');
  if (about) about.addEventListener('click', (e) => {
    e.preventDefault(); prefillForm(splashForm); splash.classList.remove('hidden');
  });
}

// Download-gate registration modal.
const regModal = document.getElementById('reg-modal');
function openRegModal() {
  if (!regModal) return;
  const form = document.getElementById('reg-form');
  prefillForm(form);
  const err = document.getElementById('reg-error');
  if (err) err.hidden = true;
  regModal.classList.remove('hidden');
  const first = form && form.elements['name'];
  if (first) setTimeout(() => first.focus(), 50);
}
function closeRegModal() { if (regModal) regModal.classList.add('hidden'); }
function prefillForm(form) {
  if (!form) return;
  const u = getUser(); if (!u) return;
  ['name', 'org', 'goal', 'email'].forEach((k) => {
    if (form.elements[k] && !form.elements[k].value) form.elements[k].value = u[k] || '';
  });
}
if (regModal) {
  const regForm = document.getElementById('reg-form');
  const err = document.getElementById('reg-error');
  document.getElementById('reg-close').addEventListener('click', () => { pendingDownload = null; closeRegModal(); });
  document.getElementById('reg-cancel').addEventListener('click', () => { pendingDownload = null; closeRegModal(); });
  regForm.addEventListener('submit', (e) => {
    e.preventDefault();
    const data = readForm(regForm);
    if (!data.name || !data.org) { if (err) err.hidden = false; return; }
    register(data);
    closeRegModal();
    // Resume the download that triggered the gate (still within this click, so
    // window.open is not treated as a popup).
    if (pendingDownload) {
      trackDownload(pendingDownload.dataset);
      window.open(pendingDownload.href, '_blank', 'noopener');
      pendingDownload = null;
    }
  });
}
