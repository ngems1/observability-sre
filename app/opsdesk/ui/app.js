/* OpsDesk UI - plain JS, no build step, served by ticket-api at /ui.
 * Every API call carries a W3C traceparent generated here, so a click in the
 * browser and the server spans (API -> DB -> SQS -> worker) share one trace id. */
(() => {
  "use strict";

  const TEAMS = { platform: "Platform", network_ops: "Network Ops", security: "Security", database: "Database", core_network: "Core Network" };
  const TYPES = { access_request: "Access request", change_request: "Change request", incident_followup: "Incident follow-up" };
  const PRIORITIES = { critical: "Critical", high: "High", medium: "Medium", low: "Low" };
  const LAYERS = { kubernetes: "Kubernetes", app: "Application", queue: "Queue", database: "Database", network: "Network", slo: "Unknown (symptom)" };
  const STATUSES = { open: "Open", triaged: "Triaged", in_progress: "In progress", resolved: "Resolved", closed: "Closed" };
  const ICONS = {
    access_request: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="15" r="4"/><path d="M10.8 12.2 20 3m-4 4 3 3m-6 0 2 2"/></svg>',
    change_request: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h13l-3-3M20 17H7l3 3"/></svg>',
    incident_followup: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 2 21h20L12 3z"/><path d="M12 10v5m0 3h.01"/></svg>',
  };

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

  const state = {
    config: { environment: "", grafana_url: null, demo_users: [] },
    key: null,
    me: null,
    approvers: [],
    view: "all",
    filters: { q: "", team: "", priority: "", type: "" },
    current: null,
    sub: "comments",
    timer: null,
  };

  // ------------------------------------------------------------------ storage
  const store = {
    get(k) { try { return sessionStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { sessionStorage.setItem(k, v); } catch { /* private mode */ } },
    del(k) { try { sessionStorage.removeItem(k); } catch { /* ignore */ } },
  };

  // --------------------------------------------------------------- telemetry
  const hex = (bytes) => Array.from(crypto.getRandomValues(new Uint8Array(bytes)), (b) => b.toString(16).padStart(2, "0")).join("");
  function grafanaTraceUrl(traceId) {
    if (!state.config.grafana_url || !traceId) return null;
    const panes = { a: { datasource: "tempo", queries: [{ refId: "A", datasource: { type: "tempo", uid: "tempo" }, queryType: "traceql", query: traceId }], range: { from: "now-1h", to: "now" } } };
    return `${state.config.grafana_url.replace(/\/$/, "")}/explore?schemaVersion=1&orgId=1&panes=${encodeURIComponent(JSON.stringify(panes))}`;
  }

  // --------------------------------------------------------------------- API
  class ApiError extends Error {
    constructor(status, detail, traceId) { super(detail); this.status = status; this.traceId = traceId; }
  }

  async function api(method, path, body) {
    const traceId = hex(16);
    const headers = { traceparent: `00-${traceId}-${hex(8)}-01` };
    if (state.key) headers["X-API-Key"] = state.key;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const res = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    let data = null;
    try { data = await res.json(); } catch { /* empty body */ }
    if (!res.ok) {
      let detail = data && data.detail;
      if (Array.isArray(detail)) detail = detail.map((d) => d.msg).join("; ");
      throw new ApiError(res.status, detail || `HTTP ${res.status}`, traceId);
    }
    return { data, traceId };
  }

  // ------------------------------------------------------------------ toasts
  function toast(message, { error = false, traceId = null } = {}) {
    const el = document.createElement("div");
    el.className = "toast" + (error ? " err" : "");
    const link = grafanaTraceUrl(traceId);
    el.innerHTML = `<div>${esc(message)}</div>` +
      (traceId ? `<div class="small mono">trace ${esc(traceId.slice(0, 16))}… ${link ? `<a href="${esc(link)}" target="_blank" rel="noopener">open in Grafana</a>` : ""}</div>` : "");
    $("#toasts").appendChild(el);
    setTimeout(() => el.remove(), error ? 9000 : 5000);
  }
  const fail = (e) => toast(`${e.status ? e.status + " · " : ""}${e.message}`, { error: true, traceId: e.traceId });

  // ------------------------------------------------------------------ format
  function ago(iso) {
    const s = (Date.now() - new Date(iso).getTime()) / 1000;
    if (s < 60) return "just now";
    if (s < 3600) return `${Math.floor(s / 60)} min ago`;
    if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
    if (s < 172800) return "Yesterday";
    return new Date(iso).toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });
  }
  const when = (iso) => (iso ? new Date(iso).toLocaleString() : "—");
  function duration(mins) {
    const m = Math.abs(mins);
    if (m < 60) return `${m} min`;
    const h = Math.floor(m / 60);
    if (h >= 48) return `${Math.floor(h / 24)} d`;
    return m % 60 ? `${h} h ${m % 60} min` : `${h} h`;
  }
  function slaLabel(sla) {
    switch (sla.state) {
      case "on_track": return `Due in ${duration(sla.minutes_left)}`;
      case "due_soon": return `Due in ${duration(sla.minutes_left)}`;
      case "breached": return sla.minutes_left == null ? "Triaged late" : `Overdue ${duration(sla.minutes_left)}`;
      default: return "Met";
    }
  }
  function secs(total) {
    if (total == null) return "—";
    const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
    return h ? `${h} h ${m} min` : m ? `${m} min ${s} s` : `${s} s`;
  }
  // Only http(s) links from alert annotations are rendered as links
  const safeUrl = (u) => (typeof u === "string" && /^https?:\/\//i.test(u) ? u : null);
  const avatar = (name) => `<span class="avatar" aria-hidden="true">${esc((name || "?").slice(0, 1))}</span>`;
  const person = (name) => (name ? `<span class="person">${avatar(name)}${esc(name)}</span>` : '<span class="unassigned">Unassigned</span>');
  const pill = (cls, text) => `<span class="pill ${cls}">${esc(text)}</span>`;
  const isApprover = () => state.me && (state.me.role === "approver" || state.me.role === "admin");

  // ------------------------------------------------------------------- login
  async function boot() {
    try { state.config = (await api("GET", "/config")).data; } catch { /* keep defaults */ }
    for (const [sel, map] of [["#f-team", TEAMS], ["#f-priority", PRIORITIES], ["#f-type", TYPES], ["#n-team", TEAMS]]) {
      $(sel).insertAdjacentHTML("beforeend", Object.entries(map).map(([v, t]) => `<option value="${v}">${esc(t)}</option>`).join(""));
    }
    const saved = store.get("opsdesk.key");
    if (saved && (await signIn(saved, true))) return;
    showLogin();
  }

  function showLogin() {
    $("#app").classList.add("hidden");
    $("#login").classList.remove("hidden");
    const demo = state.config.demo_users || [];
    $("#demo-users").classList.toggle("hidden", demo.length === 0);
    $("#demo-user-list").innerHTML = demo.map((u, i) =>
      `<button class="btn btn-ghost demo-user" type="button" data-i="${i}"><span class="person">${avatar(u.name)}${esc(u.name)}</span><span class="muted small">${esc(u.role)}</span></button>`).join("");
    $("#api-key").focus();
  }

  async function signIn(key, silent = false) {
    state.key = key;
    try {
      state.me = (await api("GET", "/me")).data;
    } catch (e) {
      state.key = null;
      store.del("opsdesk.key");
      if (!silent) { $("#login-error").textContent = e.status === 401 ? "That API key is not valid." : e.message; $("#login-error").classList.remove("hidden"); }
      return false;
    }
    store.set("opsdesk.key", key);
    $("#login-error").classList.add("hidden");
    $("#login").classList.add("hidden");
    $("#app").classList.remove("hidden");
    $("#user-name").textContent = state.me.name;
    $("#user-role").textContent = " · " + state.me.role;
    $("#user-avatar").textContent = state.me.name.slice(0, 1);
    const env = state.config.environment || "";
    $("#env-badge").textContent = env;
    $("#env-badge").classList.toggle("hidden", !env || env === "prod");
    if (state.config.grafana_url) { $("#grafana-link").href = state.config.grafana_url; $("#grafana-link").classList.remove("hidden"); }
    $("#new-ticket").classList.remove("hidden");
    try { state.approvers = (await api("GET", "/users")).data.filter((u) => u.role !== "requester"); } catch { state.approvers = []; }
    selectView(state.me.role === "requester" ? "mine" : isApprover() ? "open" : "all");
    clearInterval(state.timer);
    state.timer = setInterval(() => refresh(true), 15000);
    return true;
  }

  function signOut() {
    clearInterval(state.timer);
    state.key = null; state.me = null;
    store.del("opsdesk.key");
    closeDrawer();
    showLogin();
  }

  // ------------------------------------------------------------------ list
  function selectView(view) {
    state.view = view;
    $$("#tabs button").forEach((b) => b.setAttribute("aria-selected", String(b.dataset.view === view)));
    refresh();
  }

  async function refresh(quiet = false) {
    if (!state.key) return;
    const params = new URLSearchParams({ view: state.view, limit: "100" });
    for (const [k, v] of Object.entries(state.filters)) if (v) params.set(k, v);
    try {
      const [{ data: rows }, { data: counts }] = await Promise.all([api("GET", `/tickets?${params}`), api("GET", "/tickets/summary")]);
      renderRows(rows);
      for (const [k, v] of Object.entries(counts)) {
        const el = $(`[data-count="${k}"]`);
        if (el) { el.textContent = v; el.classList.toggle("zero", v === 0); }
      }
      $("#refresh-note").textContent = `Updated ${new Date().toLocaleTimeString()}`;
    } catch (e) {
      if (e.status === 401) return signOut();
      if (!quiet) fail(e);
    }
  }

  function renderRows(rows) {
    $("#empty").classList.toggle("hidden", rows.length > 0);
    $("#rows").innerHTML = rows.map((t) => `
      <tr>
        <td><span class="tkey"><span class="ticon ticon-${esc(t.type)}" title="${esc(TYPES[t.type])}">${ICONS[t.type] || ""}</span>${esc(t.key)}</span></td>
        <td class="title-cell" title="${esc(t.title)}">${t.source === "alert" ? '<span class="badge-alert" title="Opened automatically by Alertmanager">Alert</span>' : ""}${esc(t.title)}<span class="sub">${esc(TYPES[t.type])}${t.access_request ? " · " + esc(t.access_request.decision) : ""}</span></td>
        <td>${pill("p-" + t.priority, PRIORITIES[t.priority])}</td>
        <td>${pill("s-" + t.status, STATUSES[t.status])}</td>
        <td>${esc(TEAMS[t.team] || t.team)}</td>
        <td>${person(t.assignee_name)}</td>
        <td><span class="sla sla-${esc(t.sla.state)}" title="Triage due ${esc(when(t.sla.due_at))}">${esc(slaLabel(t.sla))}</span></td>
        <td class="muted">${esc(ago(t.created_at))}</td>
        <td><button class="btn btn-primary btn-sm" type="button" data-open="${t.id}">View</button></td>
      </tr>`).join("");
  }

  // ----------------------------------------------------------------- drawer
  async function openTicket(id) {
    try {
      const { data } = await api("GET", `/tickets/${id}`);
      state.current = data;
      renderDrawer();
      $("#drawer").classList.remove("hidden");
      $("#drawer-backdrop").classList.remove("hidden");
      $("#drawer-close").focus();
    } catch (e) { fail(e); }
  }

  function closeDrawer() {
    state.current = null;
    $("#drawer").classList.add("hidden");
    $("#drawer-backdrop").classList.add("hidden");
  }

  function renderDrawer() {
    const t = state.current;
    $("#d-key").textContent = `${t.key} · ${TYPES[t.type]}`;
    $("#d-title").textContent = t.title;
    $("#d-pills").innerHTML = pill("p-" + t.priority, PRIORITIES[t.priority]) + pill("s-" + t.status, STATUSES[t.status]) +
      `<span class="sla sla-${esc(t.sla.state)}">${esc(slaLabel(t.sla))}</span>`;
    $("#d-meta").innerHTML = `
      <dt>Team</dt><dd>${esc(TEAMS[t.team] || t.team)}</dd>
      <dt>Requester</dt><dd>${person(t.requester_name)}</dd>
      <dt>Assignee</dt><dd>${person(t.assignee_name)}</dd>
      <dt>Created</dt><dd>${esc(when(t.created_at))}</dd>
      <dt>Triage due</dt><dd>${esc(when(t.sla.due_at))}</dd>
      <dt>Triaged</dt><dd>${esc(when(t.triaged_at))}</dd>
      <dt>Resolved</dt><dd>${esc(when(t.resolved_at))}</dd>`;
    $("#d-desc").textContent = t.description || "";

    // alert card (tickets opened by Alertmanager)
    const al = t.alert;
    const alertEl = $("#d-alert");
    alertEl.classList.toggle("hidden", !al);
    if (al) {
      const runbook = safeUrl(al.runbook_url), source = safeUrl(al.generator_url);
      const badge = al.resolved_at ? pill("s-resolved", "Recovered") : pill("p-critical", "Firing");
      alertEl.innerHTML = `
        <h3>Alertmanager ${badge}</h3>
        <dl class="meta">
          <dt>Alert</dt><dd class="mono">${esc(al.alertname)}</dd>
          <dt>Severity</dt><dd>${esc(al.severity)}</dd>
          ${al.labels && al.labels.layer ? `<dt>Suspected layer</dt><dd>${pill("layer layer-" + esc(al.labels.layer), LAYERS[al.labels.layer] || al.labels.layer)}</dd>` : ""}
          ${al.summary ? `<dt>Summary</dt><dd>${esc(al.summary)}</dd>` : ""}
          <dt>Started</dt><dd>${esc(when(al.started_at))}</dd>
          <dt>Recovered</dt><dd>${esc(when(al.resolved_at))}</dd>
          <dt>Time to recover</dt><dd>${esc(al.resolved_at ? secs(al.time_to_recover_s) : "still firing")}</dd>
        </dl>
        ${runbook || source ? `<div class="row">${runbook ? `<a class="btn btn-ghost btn-sm" href="${esc(runbook)}" target="_blank" rel="noopener noreferrer">Runbook</a>` : ""}${
          source ? `<a class="btn btn-ghost btn-sm" href="${esc(source)}" target="_blank" rel="noopener noreferrer">Alert query</a>` : ""}</div>` : ""}`;
    }

    // access request card
    const ar = t.access_request;
    const accessEl = $("#d-access");
    accessEl.classList.toggle("hidden", !ar);
    if (ar) {
      const own = state.me && t.requester_id === state.me.id;
      const canDecide = isApprover() && ar.decision === "pending";
      accessEl.innerHTML = `
        <h3>Access request ${pill("d-" + ar.decision, ar.decision)}</h3>
        <dl class="meta">
          <dt>Resource</dt><dd class="mono">${esc(ar.resource)}</dd>
          <dt>Role</dt><dd>${esc(ar.requested_role)}</dd>
          <dt>Duration</dt><dd>${esc(ar.duration_days)} days</dd>
          <dt>Justification</dt><dd>${esc(ar.justification)}</dd>
          ${ar.decided_at ? `<dt>Decided</dt><dd>${esc(when(ar.decided_at))}</dd>` : ""}
          ${ar.expires_at ? `<dt>Expires</dt><dd>${esc(when(ar.expires_at))}</dd>` : ""}
        </dl>
        ${canDecide ? `
          <div class="row">
            <input id="d-reason" placeholder="Reason (optional)" maxlength="1000">
            <button class="btn btn-ok btn-sm" type="button" data-decide="approve">Approve</button>
            <button class="btn btn-danger btn-sm" type="button" data-decide="reject">Reject</button>
          </div>
          ${own ? '<p class="hint">This is your own request: the server will refuse self-approval (403).</p>' : ""}` : ""}`;
    }

    // workflow + assignment
    const actions = [];
    if (isApprover()) {
      const next = t.next_statuses || [];
      actions.push(`<h3>Workflow</h3><div class="row">${next.length
        ? next.map((s) => `<button class="btn btn-ghost btn-sm" type="button" data-move="${s}">Move to ${esc(STATUSES[s])}</button>`).join("")
        : '<span class="muted">No further transitions (closed).</span>'}</div>`);
      actions.push(`<div class="row"><select id="d-assignee" aria-label="Assignee"><option value="">Unassigned</option>${
        state.approvers.map((u) => `<option value="${u.id}" ${u.id === t.assignee_id ? "selected" : ""}>${esc(u.name)} (${esc(u.role)})</option>`).join("")
      }</select><button class="btn btn-ghost btn-sm" type="button" id="d-assign">Assign</button>${
        t.assignee_id !== state.me.id ? '<button class="btn btn-ghost btn-sm" type="button" id="d-assign-me">Assign to me</button>' : ""}</div>`);
    } else {
      actions.push('<h3>Workflow</h3><p class="muted">Approvers move tickets through the workflow. You can follow progress and comment.</p>');
    }
    $("#d-actions").innerHTML = actions.join("");
    renderSub();
  }

  async function renderSub() {
    const t = state.current;
    if (!t) return;
    $$(".subtabs button").forEach((b) => b.classList.toggle("active", b.dataset.sub === state.sub));
    const panel = $("#d-sub");
    if (state.sub === "comments") {
      panel.innerHTML = (t.comments.length ? t.comments.map((c) => `
        <div class="comment"><div><span class="who">${esc(c.author_name || "user " + c.author_id)}</span> <span class="muted small">${esc(ago(c.created_at))}</span></div>
        <div>${esc(c.body)}</div></div>`).join("") : '<p class="muted">No comments yet.</p>') +
        `<form class="comment-form" id="comment-form"><input id="comment-body" placeholder="Add a comment…" maxlength="5000" required><button class="btn btn-primary btn-sm" type="submit">Post</button></form>`;
      return;
    }
    if (state.sub === "audit") {
      if (!isApprover()) { panel.innerHTML = '<p class="muted">The audit trail is visible to approvers and admins.</p>'; return; }
      panel.innerHTML = '<p class="muted">Loading…</p>';
      try {
        const { data } = await api("GET", `/tickets/${t.id}/audit`);
        panel.innerHTML = `<ul class="timeline">${data.map((a) => {
          const link = grafanaTraceUrl(a.trace_id);
          return `<li><div><strong>${esc(a.action.replace(/_/g, " "))}</strong> by ${esc(a.actor_name || a.actor_id)}</div>
            <div class="when">${esc(when(a.created_at))}</div>
            ${a.new_value ? `<div class="small mono">${esc(JSON.stringify(a.new_value))}</div>` : ""}
            ${a.trace_id ? `<div class="small mono">trace ${esc(a.trace_id)} ${link ? `<a href="${esc(link)}" target="_blank" rel="noopener">open</a>` : ""}</div>` : ""}</li>`;
        }).join("")}</ul><p class="hint">Append-only: the database rejects UPDATE and DELETE on this table.</p>`;
      } catch (e) { panel.innerHTML = ""; fail(e); }
      return;
    }
    panel.innerHTML = '<p class="muted">Loading…</p>';
    try {
      const { data } = await api("GET", `/tickets/${t.id}/notifications`);
      panel.innerHTML = data.length ? `<table class="delivery"><thead><tr><th>Event</th><th>Status</th><th>Attempts</th><th>Delivered in</th></tr></thead><tbody>${
        data.map((n) => {
          const secs = n.sent_at ? ((new Date(n.sent_at) - new Date(n.enqueued_at)) / 1000).toFixed(2) + " s" : "—";
          return `<tr><td>${esc(n.event.replace(/_/g, " "))}</td><td>${esc(n.status)}${n.last_error ? `<div class="small error">${esc(n.last_error)}</div>` : ""}</td><td>${esc(n.attempts)}</td><td>${esc(secs)}</td></tr>`;
        }).join("")}</tbody></table><p class="hint">Delivered by ticket-worker via SQS. SLO: 95% within 30 s.</p>` : '<p class="muted">No notifications.</p>';
    } catch (e) { panel.innerHTML = ""; fail(e); }
  }

  async function act(fn, okMsg) {
    try {
      const { traceId } = await fn();
      toast(okMsg, { traceId });
      await openTicket(state.current.id);
      refresh(true);
    } catch (e) { fail(e); }
  }

  // ------------------------------------------------------------- new ticket
  function openNew() {
    const form = $("#new-form");
    form.reset();
    $("#n-access").classList.add("hidden");
    $("#new-dialog").showModal();
  }

  async function submitNew(ev) {
    const submitter = ev.submitter;
    if (!submitter || submitter.value !== "create") return; // Cancel closes the dialog
    ev.preventDefault();
    const f = new FormData($("#new-form"));
    const body = { type: f.get("type"), title: f.get("title"), priority: f.get("priority"), team: f.get("team"), description: f.get("description") || "" };
    if (body.type === "access_request") {
      body.access = { resource: f.get("resource"), requested_role: f.get("requested_role"), justification: f.get("justification"), duration_days: Number(f.get("duration_days") || 7) };
    }
    try {
      const { data, traceId } = await api("POST", "/tickets", body);
      $("#new-dialog").close();
      toast(`${data.key} created and assigned to ${data.assignee_name || "nobody"}`, { traceId });
      await refresh(true);
      openTicket(data.id);
    } catch (e) { fail(e); }
  }

  // ------------------------------------------------------------------ events
  document.addEventListener("click", (ev) => {
    const t = ev.target.closest("button, a");
    if (!t) return;
    if (t.matches("#tabs button")) return selectView(t.dataset.view);
    if (t.dataset.open) return openTicket(t.dataset.open);
    if (t.id === "drawer-close") return closeDrawer();
    if (t.id === "logout") return signOut();
    if (t.id === "new-ticket") return openNew();
    if (t.id === "crumb-home") { ev.preventDefault(); return selectView("all"); }
    if (t.classList.contains("demo-user")) return signIn(state.config.demo_users[Number(t.dataset.i)].api_key);
    if (t.matches(".subtabs button")) { state.sub = t.dataset.sub; return renderSub(); }
    const cur = state.current;
    if (!cur) return;
    if (t.dataset.move) return act(() => api("PATCH", `/tickets/${cur.id}/status`, { status: t.dataset.move }), `${cur.key} moved to ${STATUSES[t.dataset.move]}`);
    if (t.dataset.decide) {
      const reason = ($("#d-reason") || {}).value || "";
      return act(() => api("POST", `/tickets/${cur.id}/${t.dataset.decide}`, { reason }), `${cur.key} ${t.dataset.decide === "approve" ? "approved" : "rejected"}`);
    }
    if (t.id === "d-assign") {
      const v = $("#d-assignee").value;
      return act(() => api("PATCH", `/tickets/${cur.id}/assignee`, { assignee_id: v ? Number(v) : null }), `${cur.key} reassigned`);
    }
    if (t.id === "d-assign-me") return act(() => api("PATCH", `/tickets/${cur.id}/assignee`, { assignee_id: state.me.id }), `${cur.key} assigned to you`);
  });

  document.addEventListener("submit", (ev) => {
    if (ev.target.id === "login-form") { ev.preventDefault(); return signIn($("#api-key").value.trim()); }
    if (ev.target.id === "new-form") return submitNew(ev);
    if (ev.target.id === "comment-form") {
      ev.preventDefault();
      const body = $("#comment-body").value.trim();
      if (body) act(() => api("POST", `/tickets/${state.current.id}/comments`, { body }), "Comment posted");
    }
  });

  document.addEventListener("keydown", (ev) => { if (ev.key === "Escape" && state.current) closeDrawer(); });
  $("#drawer-backdrop").addEventListener("click", closeDrawer);
  $("#n-type").addEventListener("change", (ev) => {
    const access = ev.target.value === "access_request";
    $("#n-access").classList.toggle("hidden", !access);
    $$("#n-access input, #n-access textarea").forEach((el) => { el.required = access && el.name !== "duration_days"; });
  });

  let debounce;
  $("#f-q").addEventListener("input", (ev) => { clearTimeout(debounce); debounce = setTimeout(() => { state.filters.q = ev.target.value.trim(); refresh(); }, 250); });
  for (const [id, key] of [["#f-team", "team"], ["#f-priority", "priority"], ["#f-type", "type"]]) {
    $(id).addEventListener("change", (ev) => { state.filters[key] = ev.target.value; refresh(); });
  }

  boot();
})();
