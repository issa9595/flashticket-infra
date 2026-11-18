#!/usr/bin/env bash
# Crée toutes les ressources du TD2 dans LocalStack : DLQ, file principale, tables orders et idempotency, stream.
# Relançable : une ressource déjà présente est laissée telle quelle (ses réglages sont réappliqués).
# Usage : make bootstrap   (après make up, ou après make reset)
set -euo pipefail
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}" AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}" AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
AWS="${AWS_CMD:-aws --endpoint-url $AWS_ENDPOINT_URL}"   # --endpoint-url explicite : l'AWS CLI v1 ignore AWS_ENDPOINT_URL pour SQS

QUEUE_NAME="${QUEUE_NAME:-flashticket-orders}"
DLQ_NAME="${DLQ_NAME:-flashticket-orders-dlq}"
TABLE_ORDERS="${TABLE_ORDERS:-orders}"
TABLE_IDEMPOTENCY="${TABLE_IDEMPOTENCY:-idempotency}"
STREAM_NAME="${STREAM_NAME:-flashticket-sales}"
VISIBILITY=60        # >= 6 x la durée maximale de process-order (timeout 10 s)
MAX_RECEIVE=3        # après 3 réceptions sans suppression : DLQ

echo "== Files SQS"
# create-queue renvoie l'URL existante si la file existe déjà avec les mêmes attributs.
DLQ_URL=$($AWS sqs create-queue --queue-name "$DLQ_NAME" --query QueueUrl --output text)
DLQ_ARN=$($AWS sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn \
  --query Attributes.QueueArn --output text)

REDRIVE="{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"$MAX_RECEIVE\"}"
ATTRS=$(python3 -c 'import json,sys; print(json.dumps({"VisibilityTimeout": sys.argv[1], "RedrivePolicy": sys.argv[2]}))' "$VISIBILITY" "$REDRIVE")
if QUEUE_URL=$($AWS sqs get-queue-url --queue-name "$QUEUE_NAME" --query QueueUrl --output text 2>/dev/null); then
  $AWS sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "$ATTRS"
else
  QUEUE_URL=$($AWS sqs create-queue --queue-name "$QUEUE_NAME" --attributes "$ATTRS" --query QueueUrl --output text)
fi
echo "  $DLQ_NAME : $DLQ_URL"
echo "  $QUEUE_NAME : $QUEUE_URL (visibilité ${VISIBILITY} s, DLQ après $MAX_RECEIVE réceptions)"

echo "== Tables DynamoDB"
create_table() { # create_table <nom> <clé de partition>
  if $AWS dynamodb describe-table --table-name "$1" >/dev/null 2>&1; then
    echo "  $1 : déjà présente"
  else
    $AWS dynamodb create-table --table-name "$1" \
      --attribute-definitions "AttributeName=$2,AttributeType=S" \
      --key-schema "AttributeName=$2,KeyType=HASH" \
      --billing-mode PAY_PER_REQUEST >/dev/null
    $AWS dynamodb wait table-exists --table-name "$1"
    echo "  $1 : créée (clé $2)"
  fi
}
create_table "$TABLE_ORDERS" orderId
create_table "$TABLE_IDEMPOTENCY" pk
# TTL : DynamoDB efface les clés dont le champ ttl (epoch en secondes) est dépassé.
ttl_status=$($AWS dynamodb describe-time-to-live --table-name "$TABLE_IDEMPOTENCY" \
  --query TimeToLiveDescription.TimeToLiveStatus --output text 2>/dev/null || echo NONE)
if [ "$ttl_status" != "ENABLED" ]; then
  $AWS dynamodb update-time-to-live --table-name "$TABLE_IDEMPOTENCY" \
    --time-to-live-specification Enabled=true,AttributeName=ttl >/dev/null
fi
echo "  $TABLE_IDEMPOTENCY : TTL actif sur le champ ttl"

echo "== Stream Kinesis"
if $AWS kinesis describe-stream-summary --stream-name "$STREAM_NAME" >/dev/null 2>&1; then
  echo "  $STREAM_NAME : déjà présent"
else
  $AWS kinesis create-stream --stream-name "$STREAM_NAME" --shard-count 1
  $AWS kinesis wait stream-exists --stream-name "$STREAM_NAME"
  echo "  $STREAM_NAME : créé (1 shard)"
fi

echo "Ressources prêtes. Suite : make deploy"
