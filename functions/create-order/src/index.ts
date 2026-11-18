// create-order : reçoit la commande (Function URL), valide, publie dans SQS, répond 202.
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { randomUUID } from "node:crypto";
import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from "aws-lambda";

// Astuce : le client est créé HORS du handler, il est réutilisé entre les invocations.
// L'endpoint LocalStack est lu automatiquement dans AWS_ENDPOINT_URL quand il est défini.
const sqs = new SQSClient({});
const QUEUE_URL = process.env.QUEUE_URL!;

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

export type Order = { eventId: string; seats: number; email: string };

function reply(statusCode: number, body: unknown, correlationId?: string): APIGatewayProxyResultV2 {
  return {
    statusCode,
    headers: { "content-type": "application/json", ...(correlationId ? { "x-correlation-id": correlationId } : {}) },
    body: JSON.stringify(body),
  };
}

function log(level: string, msg: string, fields: Record<string, unknown>) {
  console.log(JSON.stringify({ level, msg, fn: "create-order", ...fields }));
}

/** Décode et valide le corps. Renvoie la commande, ou la liste des erreurs. */
export function parseOrder(event: Pick<APIGatewayProxyEventV2, "body" | "isBase64Encoded">): { order?: Order; errors: string[] } {
  let raw = event.body ?? "";
  if (event.isBase64Encoded) raw = Buffer.from(raw, "base64").toString("utf8");
  let data: any;
  try {
    data = JSON.parse(raw);
  } catch {
    return { errors: ["corps : JSON invalide"] };
  }
  if (data === null || typeof data !== "object" || Array.isArray(data)) return { errors: ["corps : objet JSON attendu"] };
  const errors: string[] = [];
  if (typeof data.eventId !== "string" || data.eventId.trim() === "") errors.push("eventId : texte non vide attendu");
  if (!Number.isInteger(data.seats) || data.seats < 1 || data.seats > 6) errors.push("seats : entier de 1 à 6 attendu");
  if (typeof data.email !== "string" || !EMAIL_RE.test(data.email)) errors.push("email : adresse invalide");
  if (errors.length) return { errors };
  return { order: { eventId: data.eventId.trim(), seats: data.seats, email: data.email }, errors };
}

export const handler = async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> => {
  // L'identifiant de corrélation suit la commande de bout en bout (journaux).
  const correlationId = event.headers?.["x-correlation-id"] ?? randomUUID();

  // Les en-têtes arrivent en minuscules dans une Function URL.
  const idempotencyKey = event.headers?.["idempotency-key"]?.trim();
  if (!idempotencyKey) {
    log("warn", "commande refusée", { correlationId, reason: "Idempotency-Key manquant" });
    return reply(400, { errors: ["en-tête Idempotency-Key obligatoire"] }, correlationId);
  }

  const { order, errors } = parseOrder(event);
  if (!order) {
    log("warn", "commande refusée", { correlationId, idempotencyKey, errors });
    return reply(400, { errors }, correlationId);
  }

  const orderId = randomUUID();
  const message = { orderId, correlationId, idempotencyKey, ...order, createdAt: new Date().toISOString() };
  await sqs.send(new SendMessageCommand({
    QueueUrl: QUEUE_URL,
    MessageBody: JSON.stringify(message),
    MessageAttributes: {
      idempotencyKey: { DataType: "String", StringValue: idempotencyKey },
      correlationId: { DataType: "String", StringValue: correlationId },
    },
  }));

  log("info", "commande acceptée", { correlationId, orderId });
  return reply(202, { orderId, correlationId }, correlationId);
};
