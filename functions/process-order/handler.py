"""process-order : consomme un lot de messages SQS, de façon idempotente.

Variables d'environnement : TABLE_ORDERS, TABLE_IDEMPOTENCY, STREAM_NAME.
L'endpoint LocalStack est lu automatiquement dans AWS_ENDPOINT_URL quand il est défini.
"""
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

# Clients créés hors du handler : réutilisés entre invocations.
dynamodb = boto3.client("dynamodb")
kinesis = boto3.client("kinesis")

TABLE_ORDERS = os.environ.get("TABLE_ORDERS", "orders")
TABLE_IDEMPOTENCY = os.environ.get("TABLE_IDEMPOTENCY", "idempotency")
STREAM_NAME = os.environ.get("STREAM_NAME", "flashticket-sales")
TTL_SECONDS = 24 * 3600


def log(level, msg, **fields):
    print(json.dumps({"level": level, "msg": msg, **fields}))


def process_message(order):
    """Traite UNE commande. Lève une exception pour la signaler en échec."""
    # TODO 1 : réserver la clé d'idempotence avec dynamodb.put_item et
    #          ConditionExpression="attribute_not_exists(pk)"
    #          Item : pk, status=IN_PROGRESS, orderId, ttl=maintenant + TTL_SECONDS.
    #          ConditionalCheckFailedException => doublon : décider quoi faire
    #          (indice : que se passe-t-il si la clé est IN_PROGRESS depuis un plantage ?).
    # TODO 2 : écrire la commande dans la table orders.
    # TODO 3 : publier l'événement OrderConfirmed dans le stream (kinesis.put_record).
    # TODO 4 : marquer la clé DONE (update_item) SEULEMENT à la fin.
    raise NotImplementedError


def handler(event, context):
    failures = []
    for record in event.get("Records", []):
        try:
            order = json.loads(record["body"])
            process_message(order)
        except Exception as exc:  # noqa: BLE001 : on renvoie l'élément en échec, pas tout le lot
            log("error", "message en échec", messageId=record["messageId"], error=str(exc))
            failures.append({"itemIdentifier": record["messageId"]})
    # ReportBatchItemFailures : seuls ces messages seront rejoués.
    return {"batchItemFailures": failures}
