// Supabase Edge Function: send-signal-notification
// Delivers a Web Push notification (Web Push Protocol + VAPID) to a user's
// subscriptions — or to everyone when no user_id is given.
//
// Request body (JSON):
//   { user_id?: string, title: string, body: string, url?: string, tag?: string }
//
// Required environment variables (Supabase → Edge Functions → Secrets):
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (e.g. mailto:you@site.com)
//   SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.
//
// Deploy:  supabase functions deploy send-signal-notification
//
import webpush from "npm:web-push@3.6.7";
import { createClient } from "jsr:@supabase/supabase-js@2";

const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@eurotrade.app";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

if (VAPID_PUBLIC && VAPID_PRIVATE) {
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);
}

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  if (!VAPID_PUBLIC || !VAPID_PRIVATE) {
    return json({ ok: false, error: "VAPID keys not configured" }, 500);
  }

  let payloadIn: Record<string, unknown>;
  try {
    payloadIn = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON body" }, 400);
  }

  const userId = (payloadIn.user_id as string | undefined)?.trim() || "";
  const title = (payloadIn.title as string | undefined) || "Euro Trade";
  const body = (payloadIn.body as string | undefined) || "";
  const url = (payloadIn.url as string | undefined) || "";
  const tag = (payloadIn.tag as string | undefined) || "euro-signal";

  // Target a single user's devices, or broadcast to all when user_id is absent.
  let query = supabase
    .from("push_subscriptions")
    .select("id, endpoint, subscription");
  if (userId) query = query.eq("user_id", userId);

  const { data: subs, error } = await query;
  if (error) return json({ ok: false, error: error.message }, 500);

  const message = JSON.stringify({ title, body, url, tag });
  let sent = 0;
  let removed = 0;

  for (const row of subs ?? []) {
    try {
      await webpush.sendNotification(row.subscription, message);
      sent++;
    } catch (err) {
      // 404/410 → the subscription is gone; clean it up.
      const code = (err as { statusCode?: number })?.statusCode;
      if (code === 404 || code === 410) {
        await supabase.from("push_subscriptions").delete().eq("id", row.id);
        removed++;
      }
    }
  }

  return json({ ok: true, total: subs?.length ?? 0, sent, removed });
});
