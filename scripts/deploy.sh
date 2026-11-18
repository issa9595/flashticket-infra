#!/usr/bin/env bash
# Déploie create-order et process-order dans LocalStack. Fourni : c'est de la plomberie, pas l'objet du TD.
# Relançable à volonté : crée les fonctions si elles n'existent pas, sinon met à jour leur code.
# Prérequis : LocalStack démarré (make up) et ressources créées (make bootstrap).
# Usage : make deploy   (ou : bash scripts/deploy.sh ; sans argument il déploie les deux fonctions)
#         bash scripts/deploy.sh create-order   |   bash scripts/deploy.sh process-order
set -euo pipefail
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}" AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}" AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
AWS="${AWS_CMD:-aws --endpoint-url $AWS_ENDPOINT_URL}"   # --endpoint-url explicite : l'AWS CLI v1 ignore AWS_ENDPOINT_URL pour SQS
ROLE="${ROLE_ARN:-arn:aws:iam::000000000000:role/lambda-role}"   # LocalStack ne vérifie pas le contenu du rôle
QUEUE_NAME="${QUEUE_NAME:-flashticket-orders}"
WHAT="${1:-all}"

QUEUE_URL=$($AWS sqs get-queue-url --queue-name "$QUEUE_NAME" --query QueueUrl --output text 2>/dev/null) || {
  echo "File '$QUEUE_NAME' introuvable : lancez d'abord 'make up' puis 'make bootstrap'." >&2; exit 1; }

exists() { $AWS lambda get-function --function-name "$1" >/dev/null 2>&1; }

deploy_create_order() {
  echo "== create-order : construction du paquet"
  (cd functions/create-order && { [ -f package-lock.json ] && npm ci --silent || npm install --silent; } && npm run --silent package)
  local zip="fileb://functions/create-order/create-order.zip"
  if exists create-order; then
    echo "== create-order : mise à jour du code"
    $AWS lambda update-function-code --function-name create-order --zip-file "$zip" >/dev/null
    $AWS lambda wait function-updated --function-name create-order 2>/dev/null || true
  else
    echo "== create-order : création"
    $AWS lambda create-function --function-name create-order \
      --runtime nodejs20.x --handler index.handler --role "$ROLE" --zip-file "$zip" \
      --timeout 10 --environment "Variables={QUEUE_URL=$QUEUE_URL}" >/dev/null
  fi
  if ! $AWS lambda get-function-url-config --function-name create-order >/dev/null 2>&1; then
    $AWS lambda create-function-url-config --function-name create-order --auth-type NONE >/dev/null
  fi
  echo "Adresse de create-order :"
  $AWS lambda get-function-url-config --function-name create-order --query FunctionUrl --output text
}

deploy_process_order() {
  echo "== process-order : construction du paquet"
  (cd functions/process-order && rm -f ../process-order.zip && zip -q -j ../process-order.zip handler.py)
  local zip="fileb://functions/process-order.zip"
  if exists process-order; then
    echo "== process-order : mise à jour du code"
    $AWS lambda update-function-code --function-name process-order --zip-file "$zip" >/dev/null
    $AWS lambda wait function-updated --function-name process-order 2>/dev/null || true
  else
    echo "== process-order : création"
    $AWS lambda create-function --function-name process-order \
      --runtime python3.12 --handler handler.handler --role "$ROLE" --zip-file "$zip" \
      --timeout 10 >/dev/null
  fi
  local queue_arn mappings
  queue_arn=$($AWS sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn \
    --query Attributes.QueueArn --output text)
  mappings=$($AWS lambda list-event-source-mappings --function-name process-order \
    --query 'length(EventSourceMappings)' --output text)
  if [ "$mappings" = "0" ]; then
    echo "== process-order : liaison avec la file (lot de 10, échecs partiels)"
    $AWS lambda create-event-source-mapping --function-name process-order \
      --event-source-arn "$queue_arn" --batch-size 10 \
      --function-response-types ReportBatchItemFailures >/dev/null
  else
    echo "== process-order : liaison avec la file déjà présente"
  fi
}

case "$WHAT" in
  all)           deploy_create_order; deploy_process_order ;;
  create-order)  deploy_create_order ;;
  process-order) deploy_process_order ;;
  *) echo "Usage : bash scripts/deploy.sh [create-order|process-order]" >&2; exit 2 ;;
esac
echo "Déploiement terminé."
