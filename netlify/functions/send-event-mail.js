import { Resend } from "resend";

const resend = new Resend(process.env.RESEND_API_KEY);

export async function handler(event) {
  try {
    console.log("=== send-event-mail called ===");
    console.log("Has RESEND_API_KEY:", !!process.env.RESEND_API_KEY);
    console.log("Has ADMIN_EMAIL:", !!process.env.ADMIN_EMAIL);

    // 1) Sicherheit: Secret prüfen
    const secret = event.headers["x-webhook-secret"];
    if (!secret || secret !== process.env.WEBHOOK_SECRET) {
      console.log("Unauthorized: secret missing or mismatch");
      return { statusCode: 401, body: "Unauthorized" };
    }

    // 2) Supabase Payload lesen
    const body = JSON.parse(event.body || "{}");
    const record = body.record;
    if (!record) {
      console.log("No record in payload:", body);
      return { statusCode: 400, body: "No record" };
    }

    const plate = record.plate ?? "-";
    const action = record.action ?? "-";
    const by = record.by_user ?? "-";
    const rawTime = record.time ?? new Date().toISOString();
	const d = new Date(rawTime);

	const time = new Intl.DateTimeFormat("de-AT", {
	timeZone: "Europe/Vienna",
	year: "numeric",
	month: "2-digit",
	day: "2-digit",
	hour: "2-digit",
	minute: "2-digit",
	}).format(d);


    console.log("Sending email to:", process.env.ADMIN_EMAIL);
    console.log("Event:", { plate, action, by, time });

    // 3) Mail senden
    const resp = await resend.emails.send({
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

    console.log("Resend response:", resp);

    return { statusCode: 200, body: "OK" };
  } catch (e) {
    console.error("Server error:", e);
    return { statusCode: 500, body: "Server error" };
  }
}
