import { GetObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { SendRawEmailCommand, SESClient } from "@aws-sdk/client-ses";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";

const region = process.env.AWS_REGION || "us-east-1";
const s3 = new S3Client({ region });
const ses = new SESClient({ region });
const dynamodb = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));
const tableName = process.env.DELIVERY_TABLE;
const senderEmail = process.env.SENDER_EMAIL;
const maxAttachmentBytes = Number(process.env.MAX_ATTACHMENT_BYTES || 8388608);

const cleanHeader = (value) => String(value || "").replace(/[\r\n]/g, " ").trim();
const isEmail = (value) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
const wrapBase64 = (buffer) => buffer.toString("base64").match(/.{1,76}/g)?.join("\r\n") || "";

const buildRawEmail = ({ recipient, bookingId, paymentId, pdf }) => {
  const boundary = `invoice-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const subject = cleanHeader(`Payment invoice for booking ${bookingId}`);
  const filename = cleanHeader(`invoice-${paymentId}.pdf`).replace(/[^A-Za-z0-9._-]/g, "-");
  const lines = [
    `From: Quickslot <${cleanHeader(senderEmail)}>`,
    `To: ${cleanHeader(recipient)}`,
    `Subject: ${subject}`,
    "MIME-Version: 1.0",
    `Content-Type: multipart/mixed; boundary="${boundary}"`,
    "",
    `--${boundary}`,
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: 7bit",
    "",
    `Your payment was successful. The invoice for booking ${cleanHeader(bookingId)} is attached.`,
    "",
    `--${boundary}`,
    `Content-Type: application/pdf; name="${filename}"`,
    "Content-Transfer-Encoding: base64",
    `Content-Disposition: attachment; filename="${filename}"`,
    "",
    wrapBase64(pdf),
    "",
    `--${boundary}--`,
    "",
  ];
  return Buffer.from(lines.join("\r\n"));
};

const processS3Record = async (record) => {
  const bucket = record.s3?.bucket?.name;
  const key = decodeURIComponent(String(record.s3?.object?.key || "").replace(/\+/g, " "));
  if (!bucket || !key.startsWith("payment-invoices/") || !key.toLowerCase().endsWith(".pdf")) {
    return;
  }

  const deliveryId = `${bucket}:${key}:${record.s3.object.versionId || record.s3.object.eTag || record.s3.object.sequencer}`;
  try {
    await dynamodb.send(new PutCommand({
      TableName: tableName,
      Item: {
        deliveryId,
        bucket,
        key,
        status: "PROCESSING",
        createdAt: new Date().toISOString(),
      },
      ConditionExpression: "attribute_not_exists(deliveryId)",
    }));
  } catch (error) {
    if (error.name !== "ConditionalCheckFailedException") throw error;
    const existing = await dynamodb.send(new GetCommand({ TableName: tableName, Key: { deliveryId } }));
    if (existing.Item?.status === "SENT") return;
  }

  try {
    const object = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    const recipient = cleanHeader(object.Metadata?.email);
    const bookingId = cleanHeader(object.Metadata?.bookingid || "booking");
    const paymentId = cleanHeader(object.Metadata?.paymentid || "payment");
    if (!isEmail(recipient)) throw new Error("Invoice object does not contain a valid recipient email");
    if (Number(object.ContentLength || 0) > maxAttachmentBytes) throw new Error("Invoice exceeds the email attachment limit");

    const pdf = Buffer.from(await object.Body.transformToByteArray());
    if (pdf.length > maxAttachmentBytes) throw new Error("Invoice exceeds the email attachment limit");
    const response = await ses.send(new SendRawEmailCommand({
      RawMessage: { Data: buildRawEmail({ recipient, bookingId, paymentId, pdf }) },
      Source: senderEmail,
      Destinations: [recipient],
    }));

    await dynamodb.send(new UpdateCommand({
      TableName: tableName,
      Key: { deliveryId },
      UpdateExpression: "SET #status = :sent, sentAt = :sentAt, sesMessageId = :messageId",
      ExpressionAttributeNames: { "#status": "status" },
      ExpressionAttributeValues: {
        ":sent": "SENT",
        ":sentAt": new Date().toISOString(),
        ":messageId": response.MessageId,
      },
    }));
  } catch (error) {
    await dynamodb.send(new UpdateCommand({
      TableName: tableName,
      Key: { deliveryId },
      UpdateExpression: "SET #status = :failed, failedAt = :failedAt, errorMessage = :error",
      ExpressionAttributeNames: { "#status": "status" },
      ExpressionAttributeValues: {
        ":failed": "FAILED",
        ":failedAt": new Date().toISOString(),
        ":error": cleanHeader(error.message).slice(0, 500),
      },
    }));
    throw error;
  }
};

export const handler = async (event) => {
  const failures = [];
  for (const sqsRecord of event.Records || []) {
    try {
      const body = JSON.parse(sqsRecord.body);
      for (const s3Record of body.Records || []) await processS3Record(s3Record);
    } catch (error) {
      console.error("Invoice email delivery failed", { messageId: sqsRecord.messageId, error: error.message });
      failures.push({ itemIdentifier: sqsRecord.messageId });
    }
  }
  return { batchItemFailures: failures };
};

