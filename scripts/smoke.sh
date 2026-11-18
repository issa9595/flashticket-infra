#!/usr/bin/env bash
# Tests de fumée du TD2 : API (202/400), doublon, message empoisonné vers la DLQ.
# Réutilisés au jour 3 pour valider la reconstruction (« make smoke »).
# Variables : AWS_CMD (aws), FUNCTION_URL (sinon lue dans LocalStack), SMOKE_DLQ=0 pour sauter le test lent.
set -uo pipefail
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}" AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}" AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
AWS="${AWS_CMD:-aws --endpoint-url $AWS_ENDPOINT_URL}"   # --endpoint-url explicite : l'AWS CLI v1 ignore AWS_ENDPOINT_URL pour SQS
FUNCTION_URL="${FUNCTION_URL:-$($AWS lambda list-function-url-configs --function-name create-order --query 'FunctionUrlConfigs[0].FunctionUrl' --output text 2>/dev/null)}"
fail=0
pass() { printf '  [OK] %s\n' "$1"; }
ko()   { printf '  [KO] %s\n' "$1"; fail=1; }
post() { # post <clé|-> -> code HTTP
  local h=(-H 'content-type: application/json')
  [ "$1" != "-" ] && h+=(-H "Idempotency-Key: $1")
  curl -s -o /dev/null -w '%{http_code}' -X POST "${h[@]}" \
    -d '{"eventId":"smoke","seats":2,"email":"smoke@example.com"}' "$FUNCTION_URL"
}
count_orders() { $AWS dynamodb scan --table-name orders --select COUNT \
  --filter-expression 'idempotencyKey = :k' --expression-attribute-values "{\":k\":{\"S\":\"$1\"}}" \
  --query Count --output text; }

[ -n "$FUNCTION_URL" ] && [ "$FUNCTION_URL" != "None" ] || { echo "URL de create-order introuvable (FUNCTION_URL)."; exit 2; }
echo "== API"
[ "$(post "smoke-ok-$$")" = 202 ] && pass "requête valide : 202" || ko "requête valide : 202 attendu"
[ "$(post -)" = 400 ] && pass "sans Idempotency-Key : 400" || ko "sans Idempotency-Key : 400 attendu"

echo "== Idempotence (5 envois, 1 commande)"
key="smoke-dup-$(date +%s)-$$"
for _ in 1 2 3 4 5; do post "$key" >/dev/null; done
n=0
for _ in $(seq 1 30); do n=$(count_orders "$key"); [ "$n" -ge 1 ] && break; sleep 1; done
sleep 5; n=$(count_orders "$key")
[ "$n" = 1 ] && pass "une seule commande pour 5 envois" || ko "$n commandes pour 5 envois (1 attendue)"

if [ "${SMOKE_DLQ:-1}" = 1 ]; then
  echo "== Message empoisonné (jusqu'à 4 min : 3 tentatives x 60 s de visibilité)"
  q=$($AWS sqs get-queue-url --queue-name flashticket-orders-dlq --query QueueUrl --output text)
  dlq() { $AWS sqs get-queue-attributes --queue-url "$q" --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text; }
  before=$(dlq)
  $AWS sqs send-message --queue-url "$($AWS sqs get-queue-url --queue-name flashticket-orders --query QueueUrl --output text)" \
    --message-body '{pas du json' >/dev/null
  start=$(date +%s); ok=0
  while [ $(( $(date +%s) - start )) -lt 270 ]; do
    [ "$(dlq)" -gt "$before" ] && { ok=1; break; }; sleep 5
  done
  [ $ok = 1 ] && pass "message en DLQ après $(( $(date +%s) - start )) s" || ko "aucun message en DLQ après 270 s"
fi
echo; [ $fail = 0 ] && echo "Tout est vert." || echo "Des tests ont échoué."
exit $fail
