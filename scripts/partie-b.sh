#!/usr/bin/env bash
# Les trois tests de la partie B, avec les mesures à reporter dans REPORT-j2.md.
# Usage : bash scripts/partie-b.sh doublon | poison | partiel | crash | tout
set -uo pipefail
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}" AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}" AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
AWS="${AWS_CMD:-aws --endpoint-url $AWS_ENDPOINT_URL}"
URL=$($AWS lambda get-function-url-config --function-name create-order --query FunctionUrl --output text)
Q=$($AWS sqs get-queue-url --queue-name flashticket-orders --query QueueUrl --output text)
DLQ=$($AWS sqs get-queue-url --queue-name flashticket-orders-dlq --query QueueUrl --output text)
dlq_count() { $AWS sqs get-queue-attributes --queue-url "$DLQ" --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text; }
START_MS=$(( $(date +%s) * 1000 ))
# Filtrage local (grep -F) : le --filter-pattern de LocalStack est trop large avec des identifiants à tirets.
logs() { $AWS logs filter-log-events --log-group-name /aws/lambda/process-order --start-time "$START_MS" \
  --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' | grep '^{' | grep -F -- "$1" ; }
orders_for() { $AWS dynamodb scan --table-name orders --select COUNT --filter-expression 'idempotencyKey = :k' \
  --expression-attribute-values "{\":k\":{\"S\":\"$1\"}}" --query Count --output text; }

doublon() {
  echo "== Test 3 : 5 envois avec la même Idempotency-Key"
  local key="doublon-$(date +%s)"
  for i in 1 2 3 4 5; do
    printf '  envoi %s : HTTP ' "$i"
    curl -s -o /dev/null -w '%{http_code}\n' -X POST "$URL" -H 'content-type: application/json' \
      -H "Idempotency-Key: $key" -d '{"eventId":"concert-2026","seats":2,"email":"doublon@example.com"}'
  done
  # Les 4 doublons voient la clé IN_PROGRESS ou DONE : ils sont ignorés, ou retentés après la visibilité (60 s).
  echo "  attente de 75 s (une visibilité complète) pour que les doublons retentés repassent…"
  sleep 75
  echo "  lignes dans orders pour la clé $key : $(orders_for "$key") (1 attendue)"
  $AWS dynamodb get-item --table-name idempotency --key "{\"pk\":{\"S\":\"$key\"}}" \
    --query 'Item.{status:status.S,orderId:orderId.S,ttl:ttl.N}' --output text | sed 's/^/  idempotency : /'
  echo "  journaux « doublon ignoré » pour cette clé : $(logs "$key" | grep -c 'doublon ignoré')"
}

poison() {
  echo "== Test 4 : message empoisonné (JSON invalide) envoyé directement dans la file"
  local before start mid now
  before=$(dlq_count)
  start=$(date +%s)
  mid=$($AWS sqs send-message --queue-url "$Q" --message-body '{pas du json' --query MessageId --output text)
  echo "  envoyé à $(date -r "$start" +%T), MessageId $mid, DLQ avant : $before"
  while :; do
    now=$(date +%s)
    [ "$(dlq_count)" -gt "$before" ] && break
    [ $((now - start)) -gt 300 ] && { echo "  [KO] pas en DLQ après 300 s"; return 1; }
    sleep 2
  done
  echo "  arrivé en DLQ après $((now - start)) s"
  echo "  tentatives vues dans les journaux de process-order :"
  logs "$mid" | python3 -c 'import sys,json
for l in sys.stdin:
    e=json.loads(l); print("    réception", e.get("receiveCount"), ":", e.get("error"))'
}

set_faults() { # set_faults 1|0 : active ou coupe l'injection de pannes de process-order
  local vars='Variables={}'; [ "$1" = 1 ] && vars='Variables={FAULT_INJECTION=1}'
  $AWS lambda update-function-configuration --function-name process-order --environment "$vars" >/dev/null
  $AWS lambda wait function-updated --function-name process-order
}

partiel() {
  echo "== Test 5 : un message sur deux échoue dans un lot de dix"
  set_faults 1
  local run entries
  run="partiel-$(date +%s)"
  entries=$(python3 - "$run" <<'PY'
import json, sys
run = sys.argv[1]
out = []
for n in range(10):
    body = {"orderId": f"{run}-o{n}", "idempotencyKey": f"{run}-k{n}", "correlationId": f"{run}-c{n}",
            "eventId": "concert-2026", "seats": 1, "email": "partiel@example.com"}
    if n % 2:
        body["_fault"] = "fail"
    out.append({"Id": str(n), "MessageBody": json.dumps(body)})
print(json.dumps(out))
PY
)
  $AWS sqs send-message-batch --queue-url "$Q" --entries "$entries" --query 'length(Successful)' --output text | sed 's/^/  messages envoyés : /'
  echo "  attente de 20 s (premier passage du lot)…"; sleep 20
  echo "  taille des lots reçus : $(logs "lot reçu" | grep -F "$run" | python3 -c 'import sys,json; print(sorted(json.loads(l)["size"] for l in sys.stdin))')"
  local ok=0 fail=0
  for n in 0 1 2 3 4 5 6 7 8 9; do
    local t f
    t=$(logs "$run-c$n" | grep -c 'commande traitée'); f=$(logs "$run-c$n" | grep -c 'message en échec')
    printf '  message %s : traité %s fois, en échec %s fois\n' "$n" "$t" "$f"
  done
  echo "  lignes dans orders : $($AWS dynamodb scan --table-name orders --select COUNT --filter-expression 'begins_with(orderId, :r)' \
    --expression-attribute-values "{\":r\":{\"S\":\"$run\"}}" --query Count --output text) (5 attendues : les pairs)"
  echo "  attente de 70 s : seuls les impairs doivent être retentés…"; sleep 70
  for n in 0 1 2 3 4 5 6 7 8 9; do
    printf '  message %s : traité %s fois, en échec %s fois\n' "$n" "$(logs "$run-c$n" | grep -c 'commande traitée')" "$(logs "$run-c$n" | grep -c 'message en échec')"
  done
  set_faults 0
  echo "  injection de pannes désactivée : les 5 impairs passeront à leur 3e réception."
}

crash() {
  echo "== Plantage après l'écriture de la commande, avant DONE"
  set_faults 1
  local run="crash-$(date +%s)"
  local body="{\"orderId\":\"$run-o\",\"idempotencyKey\":\"$run-k\",\"correlationId\":\"$run-c\",\"eventId\":\"concert-2026\",\"seats\":2,\"email\":\"crash@example.com\",\"_fault\":\"crash_after_write\"}"
  $AWS sqs send-message --queue-url "$Q" --message-body "$body" >/dev/null
  until logs "$run-c" | grep -q 'message en échec'; do sleep 1; done
  set_faults 0   # la panne ne se produit qu'une fois : le renvoi passera
  echo "  1er passage : $(logs "$run-c" | grep 'message en échec' | python3 -c 'import sys,json; print(json.loads(sys.stdin.readline())["error"])')"
  echo "  juste après : orders=$(orders_for "$run-k") ligne, clé=$($AWS dynamodb get-item --table-name idempotency --key "{\"pk\":{\"S\":\"$run-k\"}}" --query Item.status.S --output text)"
  echo "  attente du renvoi par SQS (visibilité 60 s)…"
  until logs "$run-c" | grep -q 'commande traitée'; do sleep 2; done
  logs "$run-c" | grep -v 'lot reçu' | sed 's/^/    /'
  echo "  après le renvoi : orders=$(orders_for "$run-k") ligne, clé=$($AWS dynamodb get-item --table-name idempotency --key "{\"pk\":{\"S\":\"$run-k\"}}" --query Item.status.S --output text)"
  local it n
  it=$($AWS kinesis get-shard-iterator --stream-name flashticket-sales --shard-id shardId-000000000000 --shard-iterator-type TRIM_HORIZON --query ShardIterator --output text)
  n=$($AWS kinesis get-records --shard-iterator "$it" --limit 10000 --query 'Records[].Data' --output text | tr '\t' '\n' | while read -r d; do echo "$d" | base64 -d; echo; done | grep -c "$run-o")
  echo "  événements OrderConfirmed pour cette commande dans le stream : $n"
}

case "${1:-tout}" in
  doublon) doublon ;; poison) poison ;; partiel) partiel ;; crash) crash ;;
  tout) doublon; poison; partiel; crash ;;
  *) echo "Usage : $0 doublon|poison|partiel|crash|tout" >&2; exit 2 ;;
esac
