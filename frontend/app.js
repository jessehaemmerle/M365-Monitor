const API = (path) => `${location.origin.replace(/:\d+$/, ':8000')}/api/${path}`; // dev: Backend auf :8000

async function json(path){
  const r = await fetch(API(path));
  if(!r.ok) throw new Error(`HTTP ${r.status}`);
  return await r.json();
}

function statusBadge(status){
  const s = (status || '').toLowerCase();
  let cls = 'ok', label = status;
  if (s.includes('degraded') || s.includes('warning')) { cls = 'warn'; }
  if (s.includes('restored') || s.includes('operational')) { cls = 'ok'; }
  if (s.includes('serviceinterruption') || s.includes('outage') || s.includes('unavailable')) { cls = 'bad'; }
  return `<span class="badge ${cls}">${label || '–'}</span>`;
}

async function loadTenant(){
  try {
    const t = await json('tenant');
    const d = t.tenant;
    document.getElementById('tenant').textContent = `${d.displayName || 'Tenant'} · ${d.verifiedDomains.join(', ')}`;
  } catch(e){ console.error(e); }
}

async function loadHealth(){
  const wrap = document.getElementById('serviceHealth');
  wrap.innerHTML = '';
  try {
    const h = await json('health');
    h.services.forEach(s => {
      const el = document.createElement('div');
      el.className = 'card';
      el.innerHTML = `<h3>${s.service}</h3>${statusBadge(s.status)}`;
      wrap.appendChild(el);
    });
    const ul = document.getElementById('issuesList');
    ul.innerHTML = '';
    h.openIssues.forEach(i => {
      const li = document.createElement('li');
      li.className = 'issue';
      li.innerHTML = `<h4>${i.title || i.service}</h4>
        <div>${i.impactDescription || ''}</div>
        <small>Status: ${i.status || '–'} · Zuletzt: ${i.lastModifiedDateTime || '–'}</small>`;
      ul.appendChild(li);
    })
  } catch(e){ console.error(e); }
}

async function loadLicenses(){
  const tb = document.querySelector('#licenseTable tbody');
  tb.innerHTML = '';
  try {
    const data = await json('licenses');
    data.skus.forEach(s => {
      const tr = document.createElement('tr');
      const status = s.warning ? `⚠️ ${s.warning}` : 'OK';
      tr.innerHTML = `<td>${s.skuPartNumber}</td><td>${s.consumedUnits}</td><td>${s.enabled}</td><td>${status}</td>`;
      tb.appendChild(tr);
    })
  } catch(e){ console.error(e); }
}

let chart;
async function loadSignins(hours=24){
  try {
    const s = await json(`signins?hours=${hours}`);
    document.getElementById('siTotal').textContent = s.total;
    document.getElementById('siFailed').textContent = s.failed;
    document.getElementById('siRate').textContent = `${s.failureRate}%`;

    const labels = s.buckets.map(b => new Date(b.timestamp).toLocaleString());
    const totals = s.buckets.map(b => b.total);
    const fails  = s.buckets.map(b => b.failed);

    const ctx = document.getElementById('signinsChart');
    if(chart){ chart.destroy(); }
    chart = new Chart(ctx, {
      type: 'line',
      data: {
        labels,
        datasets: [
          { label: 'Gesamt', data: totals },
          { label: 'Fehler', data: fails }
        ]
      },
      options: { responsive: true, maintainAspectRatio: false }
    });
  } catch(e){ console.error(e); }
}

async function init(){
  await loadTenant();
  await loadHealth();
  await loadLicenses();
  await loadSignins(24);
  // Auto-refresh alle 5 Minuten (Health & Sign‑Ins)
  setInterval(() => { loadHealth(); loadSignins(24); }, 5*60*1000);
}

init();
