import { Resend } from "resend";

const resend = new Resend(process.env.RESEND_API_KEY);

export async function handler(event) {
  try {
    // 1) Sicherheit: Secret prüfen
    const secret = event.headers["x-webhook-secret"];
    if (!secret || secret !== process.env.WEBHOOK_SECRET) {
      return { statusCode: 401, body: "Unauthorized" };
    }

    // 2) Supabase Payload lesen
    const body = JSON.parse(event.body || "{}");
    const record = body.record;
    if (!record) return { statusCode: 400, body: "No record" };

    const plate = record.plate ?? "-";
    const action = record.action ?? "-";
    const by = record.by_user ?? "-";
    const time = record.time ?? new Date().toISOString();

    // 3) Mail senden
    await resend.emails.send({
      from: "Intelligentes Gartentor <onboarding@resend.dev>",
      to: process.env.ADMIN_EMAIL,
      subject: `Gartentor Event: ${action} — ${plate}`,
      text: `Neues Ereignis im Gartentor-System

Zeit: ${time}
Kennzeichen: ${plate}
Aktion: ${action}
Von: ${by}
`,
    });

    return { statusCode: 200, body: "OK" };
  } catch (e) {
    console.error(e);
    return { statusCode: 500, body: "Server error" };
  }
}
