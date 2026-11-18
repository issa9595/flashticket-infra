"""Tests de process-order sans LocalStack : DynamoDB et Kinesis sont remplacés par des faux en mémoire.

Lancer depuis functions/process-order : python3 -m unittest -v   (boto3 requis)
"""
import json
import os
import unittest
from unittest import mock

os.environ.setdefault("AWS_DEFAULT_REGION", "eu-west-3")
os.environ["FAULT_INJECTION"] = "1"
from botocore.exceptions import ClientError  # noqa: E402

import handler  # noqa: E402


def conditional_failed():
    return ClientError({"Error": {"Code": "ConditionalCheckFailedException"}}, "Op")


class FakeDynamo:
    """Juste ce que handler.py utilise : put/get/update, conditions attribute_not_exists et startedAt."""

    def __init__(self):
        self.tables = {"orders": {}, "idempotency": {}}

    @staticmethod
    def _key(table, item):
        return item["pk"]["S"] if table == "idempotency" else item["orderId"]["S"]

    def put_item(self, TableName, Item, ConditionExpression=None):
        k = self._key(TableName, Item)
        if ConditionExpression == "attribute_not_exists(pk)" and k in self.tables[TableName]:
            raise conditional_failed()
        self.tables[TableName][k] = dict(Item)

    def get_item(self, TableName, Key, ConsistentRead=False):
        item = self.tables[TableName].get(Key["pk"]["S"])
        return {"Item": dict(item)} if item else {}

    def update_item(self, TableName, Key, UpdateExpression, ExpressionAttributeValues, ConditionExpression=None, ExpressionAttributeNames=None):
        item = self.tables[TableName][Key["pk"]["S"]]
        v = ExpressionAttributeValues
        if ConditionExpression and (item["status"] != v[":p"] or item["startedAt"] != v[":old"]):
            raise conditional_failed()
        if ":d" in v:
            item["status"] = v[":d"]
        item["startedAt" if ":old" in v else "doneAt"] = v[":now"]


class FakeKinesis:
    def __init__(self):
        self.records = []

    def put_record(self, StreamName, Data, PartitionKey):
        self.records.append(json.loads(Data))


def msg(n, key=None, **extra):
    body = {"orderId": f"o-{n}", "idempotencyKey": key or f"k-{n}", "correlationId": f"c-{n}",
            "eventId": "concert-2026", "seats": 2, "email": "a@example.com", **extra}
    return {"messageId": f"m-{n}", "body": json.dumps(body), "attributes": {"ApproximateReceiveCount": "1"}}


class ProcessOrderTest(unittest.TestCase):
    def setUp(self):
        self.ddb, self.kin = FakeDynamo(), FakeKinesis()
        patches = [mock.patch.object(handler, "dynamodb", self.ddb), mock.patch.object(handler, "kinesis", self.kin),
                   mock.patch.object(handler.time, "time", return_value=1_000_000)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def run_batch(self, *records):
        return handler.handler({"Records": list(records)}, None)["batchItemFailures"]

    def test_commande_traitee_de_bout_en_bout(self):
        self.assertEqual(self.run_batch(msg(1)), [])
        self.assertIn("o-1", self.ddb.tables["orders"])
        self.assertEqual(self.ddb.tables["idempotency"]["k-1"]["status"]["S"], "DONE")
        self.assertEqual(self.kin.records[0]["type"], "OrderConfirmed")
        self.assertEqual(int(self.ddb.tables["idempotency"]["k-1"]["ttl"]["N"]), 1_000_000 + 86400)

    def test_cinq_envois_meme_cle_une_seule_commande(self):
        # 5 requêtes HTTP = 5 messages avec 5 orderId différents mais la même clé.
        for n in range(5):
            self.run_batch(msg(n, key="achat-42"))
        self.assertEqual(len(self.ddb.tables["orders"]), 1)
        self.assertEqual(len(self.kin.records), 1)

    def test_doublon_pendant_un_traitement_en_cours_est_retente(self):
        self.ddb.tables["idempotency"]["achat-42"] = {"pk": {"S": "achat-42"}, "status": {"S": "IN_PROGRESS"},
                                                      "orderId": {"S": "o-0"}, "startedAt": {"N": str(1_000_000 - 2)}}
        self.assertEqual(self.run_batch(msg(1, key="achat-42")), [{"itemIdentifier": "m-1"}])
        self.assertEqual(self.ddb.tables["orders"], {})

    def test_message_empoisonne_signale_en_echec(self):
        bad = {"messageId": "m-x", "body": "{pas du json"}
        self.assertEqual(self.run_batch(bad), [{"itemIdentifier": "m-x"}])

    def test_echec_partiel_seuls_les_rates_sont_renvoyes(self):
        batch = [msg(n, _fault="fail") if n % 2 else msg(n) for n in range(10)]
        failed = {f["itemIdentifier"] for f in self.run_batch(*batch)}
        self.assertEqual(failed, {f"m-{n}" for n in range(1, 10, 2)})
        self.assertEqual(sorted(self.ddb.tables["orders"]), [f"o-{n}" for n in range(0, 10, 2)])

    def test_plantage_avant_done_puis_reprise_sans_doublon(self):
        self.assertEqual(self.run_batch(msg(1, key="achat-42", _fault="crash_after_write")), [{"itemIdentifier": "m-1"}])
        self.assertEqual(self.ddb.tables["idempotency"]["achat-42"]["status"]["S"], "IN_PROGRESS")
        self.assertEqual(self.kin.records, [])
        # SQS renvoie le même message 60 s plus tard (visibilité), sans la panne cette fois.
        with mock.patch.object(handler.time, "time", return_value=1_000_060):
            self.assertEqual(self.run_batch(msg(1, key="achat-42")), [])
        self.assertEqual(list(self.ddb.tables["orders"]), ["o-1"])
        self.assertEqual(self.ddb.tables["idempotency"]["achat-42"]["status"]["S"], "DONE")
        self.assertEqual(len(self.kin.records), 1)

    def test_champs_manquants(self):
        self.assertEqual(self.run_batch({"messageId": "m-y", "body": json.dumps({"orderId": "o"})}), [{"itemIdentifier": "m-y"}])


if __name__ == "__main__":
    unittest.main()
