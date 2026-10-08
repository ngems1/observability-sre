// Steady synthetic traffic so SLIs, dashboards and burn-rate alerts have data.
// Mix: ~60% reads, ~25% creates, ~15% transitions/approvals.  Default 5 req/s.
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://opsdesk-api.opsdesk.svc.cluster.local:8080';
const RATE = parseInt(__ENV.RATE || '5');
const KEYS = {
  requester: __ENV.REQUESTER_KEY || 'alice-local-key',
  approver: __ENV.APPROVER_KEY || 'bob-local-key',
};

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: __ENV.DURATION || '24h',
      preAllocatedVUs: 10,
      maxVUs: 50,
    },
  },
  discardResponseBodies: false,
};

const json = (key) => ({ headers: { 'X-API-Key': key, 'Content-Type': 'application/json' } });
const TEAMS = ['platform', 'network_ops', 'security', 'database', 'core_network'];
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];
const NEXT = { open: 'triaged', triaged: 'in_progress', in_progress: 'resolved', resolved: 'closed' };

function createTicket() {
  const access = Math.random() < 0.35;
  const body = access
    ? {
        type: 'access_request',
        title: `k6 access request ${Date.now()}`,
        priority: 'medium',
        team: pick(TEAMS),
        access: { resource: 'staging-eks', requested_role: 'read-only', justification: 'synthetic load test', duration_days: 1 },
      }
    : {
        type: Math.random() < 0.6 ? 'change_request' : 'incident_followup',
        title: `k6 ticket ${Date.now()}`,
        priority: pick(['low', 'medium', 'high']),
        team: pick(TEAMS),
      };
  const res = http.post(`${BASE}/tickets`, JSON.stringify(body), json(KEYS.requester));
  check(res, { 'create 201': (r) => r.status === 201 });
  return res.status === 201 ? res.json() : null;
}

export default function () {
  const roll = Math.random();
  if (roll < 0.6) {
    // same calls the web UI makes on every refresh
    const view = pick(['all', 'open', 'mine', 'pending_approval']);
    const res = http.get(`${BASE}/tickets?view=${view}&limit=50`, json(KEYS.approver));
    http.get(`${BASE}/tickets/summary`, json(KEYS.approver));
    check(res, { 'list 200': (r) => r.status === 200 });
    return;
  }
  if (roll < 0.85) {
    createTicket();
    return;
  }
  // transitions / approvals on a fresh ticket
  const t = createTicket();
  if (!t) return;
  if (t.type === 'access_request') {
    const verb = Math.random() < 0.8 ? 'approve' : 'reject';
    const res = http.post(`${BASE}/tickets/${t.id}/${verb}`, '{}', json(KEYS.approver));
    check(res, { 'decision 200': (r) => r.status === 200 });
    return;
  }
  let status = t.status;
  const steps = 1 + Math.floor(Math.random() * 4);
  for (let i = 0; i < steps && NEXT[status]; i++) {
    const res = http.patch(`${BASE}/tickets/${t.id}/status`, JSON.stringify({ status: NEXT[status] }), json(KEYS.approver));
    check(res, { 'transition 200': (r) => r.status === 200 });
    status = NEXT[status];
  }
}
