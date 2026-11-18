// Tests de create-order sans LocalStack : l'envoi SQS est remplacé par un faux.
// Lancer : npm test
import { test } from "node:test";
import assert from "node:assert/strict";
import { SQSClient } from "@aws-sdk/client-sqs";

process.env.QUEUE_URL = "http://test/queue";
const sent: any[] = [];
SQSClient.prototype.send = (async (cmd: any) => { sent.push(cmd.input); return { MessageId: "m-1" }; }) as any;
const { handler, parseOrder } = await import("./index.ts");

const body = { eventId: "concert-2026", seats: 2, email: "a@example.com" };
const call = (headers: Record<string, string>, b: unknown = body, base64 = false) => {
  const raw = typeof b === "string" ? b : JSON.stringify(b);
  return handler({ headers, body: base64 ? Buffer.from(raw).toString("base64") : raw, isBase64Encoded: base64 } as any) as Promise<any>;
};

test("commande valide : 202, message publié avec la clé et le correlationId", async () => {
  sent.length = 0;
  const res = await call({ "idempotency-key": "k-1", "x-correlation-id": "c-1" });
  assert.equal(res.statusCode, 202);
  const out = JSON.parse(res.body);
  assert.equal(out.correlationId, "c-1");
  assert.equal(res.headers["x-correlation-id"], "c-1");
  assert.equal(sent.length, 1);
  const msg = JSON.parse(sent[0].MessageBody);
  assert.equal(msg.orderId, out.orderId);
  assert.equal(msg.idempotencyKey, "k-1");
  assert.equal(msg.seats, 2);
  assert.equal(sent[0].QueueUrl, "http://test/queue");
});

test("sans Idempotency-Key : 400 et rien n'est publié", async () => {
  sent.length = 0;
  const res = await call({});
  assert.equal(res.statusCode, 400);
  assert.equal(sent.length, 0);
});

test("corps invalide : 400 avec la liste des erreurs", async () => {
  sent.length = 0;
  const res = await call({ "idempotency-key": "k-2" }, { eventId: "", seats: 9, email: "pas-un-mail" });
  assert.equal(res.statusCode, 400);
  assert.equal(JSON.parse(res.body).errors.length, 3);
  assert.equal(sent.length, 0);
});

test("JSON cassé : 400", async () => {
  const res = await call({ "idempotency-key": "k-3" }, "{pas du json");
  assert.equal(res.statusCode, 400);
});

test("corps en base64 accepté", async () => {
  const res = await call({ "idempotency-key": "k-4" }, body, true);
  assert.equal(res.statusCode, 202);
});

test("validation des places : 1 à 6, entier", () => {
  for (const seats of [1, 6]) assert.ok(parseOrder({ body: JSON.stringify({ ...body, seats }) } as any).order);
  for (const seats of [0, 7, 2.5, "2"]) assert.ok(parseOrder({ body: JSON.stringify({ ...body, seats }) } as any).errors.length);
});
