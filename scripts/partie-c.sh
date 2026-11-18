#!/usr/bin/env bash
# Mesures de la partie C.
#   bash scripts/partie-c.sh compteurs        après make load : 202, traités, lignes orders, DLQ
#   bash scripts/partie-c.sh coldstart        premier appel après 10 min d'inactivité, puis un second
#   bash scripts/partie-c.sh suivre <corrId>  une commande de bout en bout dans les journaux
set -uo pipefail
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}" AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}" AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
AWS="${AWS_CMD:-aws --endpoint-url $AWS_ENDPOINT_URL}"
URL=$($AWS lambda get-function-url-config --function-name create-order --query FunctionUrl --output text)
qattr() { $AWS sqs get-queue-attributes --queue-url "$($AWS sqs get-queue-url --queue-name "$1" --query QueueUrl --output text)" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible --query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]' --output text; }
count_logs() { $AWS logs filter-log-events --log-group-name "$1" --filter-pattern "\"$2\"" --query 'length(events)' --output text; }

compteurs() {
  local accepted
  accepted=$(python3 -c 'import json; print(int(json.load(open("loadtest/summary.json"))["metrics"]["orders_accepted_202"]["values"]["count"]))' 2>/dev/null || echo "?")
  echo "202 acceptés (k6, orders_accepted_202) : $accepted"
  echo "commandes acceptées (journaux create-order) : $(count_logs /aws/lambda/create-order 'commande acceptée')"
  echo "messages traités (journaux « commande traitée ») : $(count_logs /aws/lambda/process-order 'commande traitée')"
  echo "lignes dans orders : $($AWS dynamodb scan --table-name orders --select COUNT --query Count --output text)"
  echo "file principale (visibles, en cours) : $(qattr flashticket-orders)"
  echo "DLQ (visibles, en cours) : $(qattr flashticket-orders-dlq)"
  echo "messages en échec (journaux) : $(count_logs /aws/lambda/process-order 'message en échec')"
}

appel() { curl -s -o /dev/null -w '%{http_code} en %{time_total} s' -X POST "$URL" -H 'content-type: application/json' \
  -H "Idempotency-Key: cold-$(date +%s%N)" -d '{"eventId":"concert-2026","seats":1,"email":"cold@example.com"}'; }

coldstart() {
  local wait="${COLD_WAIT:-660}"
  echo "inactivité de $wait s avant le premier appel (LocalStack libère une copie inutilisée après 10 min)…"
  sleep "$wait"
  echo "1er appel (froid) : $(appel)"
  echo "2e appel (chaud)  : $(appel)"
  echo "3e appel (chaud)  : $(appel)"
  echo "durées vues par Lambda (REPORT, dernières lignes de create-order) :"
  $AWS logs filter-log-events --log-group-name /aws/lambda/create-order --filter-pattern REPORT \
    --start-time $(( ($(date +%s) - 60) * 1000 )) --query 'events[].message' --output text | tr '\t' '\n' | grep -o 'Duration: [0-9.]* ms.*Init Duration: [0-9.]* ms\|Duration: [0-9.]* ms' | sed 's/^/  /'
}

suivre() {
  local cid="$1"
  for fn in create-order process-order; do
    echo "== /aws/lambda/$fn"
    $AWS logs filter-log-events --log-group-name "/aws/lambda/$fn" --filter-pattern "\"$cid\"" \
      --query 'events[].[timestamp,message]' --output text | while IFS=$'\t' read -r ts m; do
        printf '  %s  %s\n' "$(python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1])/1000).strftime('%H:%M:%S.%f')[:-3])" "$ts")" "$m"
      done
  done
  echo "== orders"
  $AWS dynamodb scan --table-name orders --filter-expression 'correlationId = :c' \
    --expression-attribute-values "{\":c\":{\"S\":\"$cid\"}}" --query 'Items[0].{orderId:orderId.S,status:status.S,seats:seats.N}' --output text | sed 's/^/  /'
}

case "${1:-}" in
  compteurs) compteurs ;; coldstart) coldstart ;; suivre) suivre "${2:?correlationId attendu}" ;;
  *) echo "Usage : $0 compteurs | coldstart | suivre <correlationId>" >&2; exit 2 ;;
esac
