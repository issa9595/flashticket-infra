// Charge du TD2 : 20 requêtes/s pendant 150 s = 3 000 commandes, chacune avec une clé unique.
// Usage : k6 run -e URL=<url de la Function URL create-order> loadtest/k6.js
//
// Pourquoi 20 req/s et pas 50 : sous LocalStack, chaque requête concurrente sans environnement
// « chaud » démarre un nouveau conteneur Lambda. Sur un poste standard (VM Docker 3-4 CPU),
// 50 req/s font grimper le nombre de conteneurs jusqu'à saturation (timeouts au démarrage,
// LocalStack « unhealthy »). 20 req/s pendant 150 s donnent le même volume de commandes.
import http from "k6/http";
import { check } from "k6";
import { Counter } from "k6/metrics";

const accepted = new Counter("orders_accepted_202");

export const options = {
  scenarios: {
    // Chauffe : montée progressive pour que le pool de conteneurs grossisse avec la charge.
    warmup: {
      executor: "ramping-arrival-rate",
      startRate: 1,
      timeUnit: "1s",
      stages: [{ target: 20, duration: "30s" }],
      preAllocatedVUs: 10,
      maxVUs: 30,
    },
    // Mesure : 20 requêtes/s pendant 150 s = 3 000 commandes.
    orders: {
      executor: "constant-arrival-rate",
      startTime: "30s",
      rate: 20,
      timeUnit: "1s",
      duration: "150s",
      preAllocatedVUs: 20,
      maxVUs: 60,
    },
  },
  // Seuils évalués sur la phase de mesure uniquement.
  thresholds: {
    "http_req_failed{scenario:orders}": ["rate<0.01"],
    "http_req_duration{scenario:orders}": ["p(95)<2000"],
  },
};

export default function () {
  const key = `k6-${__VU}-${__ITER}-${Date.now()}`;
  const res = http.post(
    __ENV.URL,
    JSON.stringify({ eventId: "concert-2026", seats: 2, email: "load@example.com" }),
    { headers: { "content-type": "application/json", "Idempotency-Key": key } },
  );
  const ok = check(res, { "202 accepté": (r) => r.status === 202 });
  if (ok) accepted.add(1);
}

export function handleSummary(data) {
  return { "loadtest/summary.json": JSON.stringify(data, null, 2) };
}
