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
# Une clé IN_PROGRESS plus vieille que ça vient d'un traitement qui a planté : le timeout de la
# fonction est de 10 s, aucun traitement vivant ne peut durer 30 s. Plus récente : un autre traitement
# est peut-être en cours, on réessaiera après la visibilité (60 s).
STALE_AFTER_SECONDS = int(os.environ.get("STALE_AFTER_SECONDS", "30"))
# Injection de pannes pour les tests du TD (désactivée par défaut) : champ "_fault" du message.
FAULT_INJECTION = os.environ.get("FAULT_INJECTION") == "1"
REQUIRED = ("orderId", "idempotencyKey", "eventId", "seats", "email")


class InFlightElsewhere(Exception):
    """La clé est réservée par un traitement encore en cours : réessayer plus tard."""


def log(level, msg, **fields):
    print(json.dumps({"level": level, "msg": msg, "fn": "process-order", **fields}, ensure_ascii=False))


def fault(order, kind):
    if FAULT_INJECTION and order.get("_fault") == kind:
        raise RuntimeError(f"panne simulée : {kind}")


def reserve(order, now):
    """Réserve la clé. Renvoie l'orderId à utiliser, ou None si la commande est déjà faite (doublon)."""
    key = order["idempotencyKey"]
    try:
        dynamodb.put_item(
            TableName=TABLE_IDEMPOTENCY,
            Item={"pk": {"S": key}, "status": {"S": "IN_PROGRESS"}, "orderId": {"S": order["orderId"]},
                  "startedAt": {"N": str(now)}, "ttl": {"N": str(now + TTL_SECONDS)}},
            ConditionExpression="attribute_not_exists(pk)",
        )
        return order["orderId"]
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
    item = dynamodb.get_item(TableName=TABLE_IDEMPOTENCY, Key={"pk": {"S": key}}, ConsistentRead=True).get("Item")
    if item is None:  # la clé a expiré entre-temps : on retente la réservation
        return reserve(order, now)
    if item["status"]["S"] == "DONE":
        return None
    started = int(item.get("startedAt", {"N": "0"})["N"])
    if now - started < STALE_AFTER_SECONDS:
        raise InFlightElsewhere(f"clé {key} en cours de traitement depuis {now - started} s")
    # IN_PROGRESS abandonné par un plantage : on le reprend, avec SON orderId, pour réécrire la même ligne.
    try:
        dynamodb.update_item(
            TableName=TABLE_IDEMPOTENCY, Key={"pk": {"S": key}},
            UpdateExpression="SET startedAt = :now",
            ConditionExpression="#s = :p AND startedAt = :old",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":now": {"N": str(now)}, ":p": {"S": "IN_PROGRESS"}, ":old": {"N": str(started)}},
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise InFlightElsewhere(f"clé {key} reprise par un autre traitement") from exc
        raise
    return item["orderId"]["S"]


def process_message(order):
    """Traite UNE commande. Lève une exception pour la signaler en échec."""
    missing = [f for f in REQUIRED if f not in order]
    if missing:
        raise ValueError(f"champs manquants : {', '.join(missing)}")
    cid = order.get("correlationId")
    fault(order, "fail")
    now = int(time.time())

    # 1. Réserver la clé d'idempotence (écriture conditionnelle, atomique).
    order_id = reserve(order, now)
    if order_id is None:
        log("info", "doublon ignoré", correlationId=cid, idempotencyKey=order["idempotencyKey"])
        return
    if order_id != order["orderId"]:
        log("warn", "reprise après plantage", correlationId=cid, orderId=order_id)

    # 2. Écrire la commande. Même orderId à la reprise : la ligne est réécrite, pas dupliquée.
    dynamodb.put_item(TableName=TABLE_ORDERS, Item={
        "orderId": {"S": order_id}, "idempotencyKey": {"S": order["idempotencyKey"]},
        "eventId": {"S": str(order["eventId"])}, "seats": {"N": str(int(order["seats"]))},
        "email": {"S": str(order["email"])}, "correlationId": {"S": str(cid)},
        "status": {"S": "CONFIRMED"}, "createdAt": {"S": str(order.get("createdAt", ""))},
    })
    fault(order, "crash_after_write")

    # 3. Publier OrderConfirmed dans le stream (partition par commande).
    event = {"type": "OrderConfirmed", "orderId": order_id, "eventId": order["eventId"],
             "seats": order["seats"], "correlationId": cid, "confirmedAt": now}
    kinesis.put_record(StreamName=STREAM_NAME, Data=json.dumps(event).encode(), PartitionKey=order_id)

    # 4. Marquer la clé DONE, SEULEMENT maintenant que tout est fait.
    dynamodb.update_item(
        TableName=TABLE_IDEMPOTENCY, Key={"pk": {"S": order["idempotencyKey"]}},
        UpdateExpression="SET #s = :d, doneAt = :now",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":d": {"S": "DONE"}, ":now": {"N": str(now)}},
    )
    log("info", "commande traitée", correlationId=cid, orderId=order_id)


def handler(event, context):
    failures = []
    for record in event.get("Records", []):
        cid = None
        try:
            order = json.loads(record["body"])
            if not isinstance(order, dict):
                raise ValueError("objet JSON attendu")
            cid = order.get("correlationId")
            process_message(order)
        except Exception as exc:  # noqa: BLE001 : on renvoie l'élément en échec, pas tout le lot
            log("error", "message en échec", messageId=record["messageId"], correlationId=cid,
                receiveCount=record.get("attributes", {}).get("ApproximateReceiveCount"), error=str(exc))
            failures.append({"itemIdentifier": record["messageId"]})
    # ReportBatchItemFailures : seuls ces messages seront rejoués.
    return {"batchItemFailures": failures}
