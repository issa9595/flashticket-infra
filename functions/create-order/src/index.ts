// create-order : reçoit la commande (Function URL), valide, publie dans SQS, répond 202.
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { randomUUID } from "node:crypto";
import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from "aws-lambda";

// Astuce : le client est créé HORS du handler, il est réutilisé entre les invocations.
// L'endpoint LocalStack est lu automatiquement dans AWS_ENDPOINT_URL quand il est défini.
const sqs = new SQSClient({});
const QUEUE_URL = process.env.QUEUE_URL!;

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

function reply(statusCode: number, body: unknown, correlationId?: string): APIGatewayProxyResultV2 {
  return {
    statusCode,
    headers: { "content-type": "application/json", ...(correlationId ? { "x-correlation-id": correlationId } : {}) },
    body: JSON.stringify(body),
  };
}

export const handler = async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> => {
  // L'identifiant de corrélation suit la commande de bout en bout (journaux).
  const correlationId = event.headers?.["x-correlation-id"] ?? randomUUID();

  // TODO 1 : lire l'en-tête « idempotency-key » (les en-têtes arrivent en minuscules).
  //          S'il manque : répondre 400.

  // TODO 2 : décoder le corps (JSON, éventuellement en base64 : event.isBase64Encoded)
  //          et valider : eventId (texte non vide), seats (entier de 1 à 6), email (EMAIL_RE).
  //          Corps invalide : répondre 400 avec la liste des erreurs.

  // TODO 3 : fabriquer le message {orderId, correlationId, idempotencyKey, eventId, seats, email, createdAt}
  //          et l'envoyer avec SendMessageCommand({ QueueUrl: QUEUE_URL, MessageBody: ... }).

  // TODO 4 : journaliser UNE ligne JSON {level, msg, correlationId, orderId} avec console.log.

  // TODO 5 : répondre 202 avec { orderId, correlationId }.
  return reply(501, { error: "not implemented" }, correlationId);
};
