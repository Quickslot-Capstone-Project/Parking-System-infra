import { BedrockRuntimeClient, ConverseCommand } from "@aws-sdk/client-bedrock-runtime";
import { DynamoDBClient, ScanCommand } from "@aws-sdk/client-dynamodb";

const region = process.env.BEDROCK_REGION || process.env.AWS_REGION || "us-east-1";
const modelId = process.env.BEDROCK_MODEL_ID || "amazon.nova-pro-v1:0";
const bookingsTable = process.env.BOOKINGS_TABLE;
const slotsTable = process.env.SLOTS_TABLE;

const bedrock = new BedrockRuntimeClient({ region });
const dynamodb = new DynamoDBClient({ region: process.env.AWS_REGION || "us-east-1" });

const unmarshallValue = (value) => {
  if (!value) return undefined;
  if ("S" in value) return value.S;
  if ("N" in value) return Number(value.N);
  if ("BOOL" in value) return value.BOOL;
  if ("NULL" in value) return null;
  if ("SS" in value) return value.SS;
  if ("NS" in value) return value.NS.map(Number);
  if ("L" in value) return value.L.map(unmarshallValue);
  if ("M" in value) return unmarshallItem(value.M);
  return undefined;
};

const unmarshallItem = (item) =>
  Object.fromEntries(Object.entries(item || {}).map(([key, value]) => [key, unmarshallValue(value)]));

const scanRecent = async ({ tableName, projectionExpression, expressionAttributeNames, limit }) => {
  const response = await dynamodb.send(
    new ScanCommand({
      TableName: tableName,
      ProjectionExpression: projectionExpression,
      ExpressionAttributeNames: expressionAttributeNames,
      Limit: limit,
    })
  );

  return (response.Items || []).map(unmarshallItem);
};

const loadLiveContext = async () => {
  const [bookings, slots] = await Promise.all([
    scanRecent({
      tableName: bookingsTable,
      projectionExpression:
        "bookingId, userId, slotId, vehicleType, durationHours, amount, #status, createdAt, expiresAt, paidAt",
      expressionAttributeNames: { "#status": "status" },
      limit: 120,
    }),
    scanRecent({
      tableName: slotsTable,
      projectionExpression: "slotId, #location, #status, price",
      expressionAttributeNames: { "#location": "location", "#status": "status" },
      limit: 200,
    }),
  ]);

  return { bookings, slots, generatedAt: new Date().toISOString() };
};

export const handler = async (event = {}) => {
  if (!event.prompt || String(event.prompt).trim().length < 2) {
    throw new Error("prompt is required");
  }

  const context = await loadLiveContext();
  const groundedPrompt = `${String(event.prompt).trim()}

Authoritative live DynamoDB context follows. Use only this context for parking availability, price, booking history, and demand claims. Never invent a slot or booking.
${JSON.stringify(context)}`;

  const response = await bedrock.send(
    new ConverseCommand({
      modelId,
      messages: [{ role: "user", content: [{ text: groundedPrompt }] }],
      inferenceConfig: {
        maxTokens: Math.min(Number(event.maxTokens) || 1200, 2000),
        temperature: Number.isFinite(Number(event.temperature)) ? Number(event.temperature) : 0.2,
      },
    })
  );

  const text = (response.output?.message?.content || [])
    .map((part) => part.text || "")
    .join("")
    .trim();

  if (!text) throw new Error("Nova returned an empty response");

  return {
    text,
    modelId,
    groundingSource: "DYNAMODB_LAMBDA",
    contextCounts: { bookings: context.bookings.length, slots: context.slots.length },
  };
};
