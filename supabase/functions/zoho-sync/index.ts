// Zoho Flow -> MyEGL synchronization endpoint.
// Deploy as Supabase Edge Function with JWT verification DISABLED ONLY for this
// function; require x-ersy-flow-secret on every request. Never use from a browser.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const secret = Deno.env.get("ZOHO_SYNC_SECRET");
  const provided = req.headers.get("x-ersy-flow-secret");
  if (!secret || !provided || secret.length < 32 || provided !== secret)
    return new Response("Unauthorized", { status: 401 });
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return new Response("Server not configured", { status: 503 });
  let input: Record<string, unknown>;
  try { input = await req.json(); } catch { return new Response("Invalid JSON", { status: 400 }); }
  const required = ["zoho_record_id", "reference", "customer_email", "service_type"];
  if (required.some(k => typeof input[k] !== "string" || !(input[k] as string).trim()))
    return new Response("Missing required fields", { status: 400 });
  const email = String(input.customer_email).trim().toLowerCase();
  if (email.length > 254 || !email.includes("@")) return new Response("Invalid email", { status: 400 });
  const db = createClient(url, key, { auth: { persistSession: false } });
  // Match only approved accounts. A newly signed-up customer sees NO records
  // until an ERSY GLOBAL administrator explicitly approves their account.
  const { data: customer, error: lookupError } = await db.from("portal_customers")
    .select("id").eq("email", email).eq("approved", true).maybeSingle();
  if (lookupError) return new Response("Customer lookup failed", { status: 500 });
  const text = (name: string, max = 500) => typeof input[name] === "string"
    ? String(input[name]).slice(0, max) : null;
  const statuses = ["not_quoted", "pending", "approved", "declined", "revision_requested", "expired"];
  const payments = ["not_requested", "pending", "paid", "failed", "refunded"];
  const quoteStatus = statuses.includes(String(input.quote_status)) ? String(input.quote_status) : "not_quoted";
  const paymentStatus = payments.includes(String(input.payment_status)) ? String(input.payment_status) : "not_requested";
  const total = input.quoted_total == null || input.quoted_total === "" ? null : Number(input.quoted_total);
  if (total !== null && (!Number.isFinite(total) || total < 0)) return new Response("Invalid quote amount", { status: 400 });
  const details = input.request_details && typeof input.request_details === "object" && !Array.isArray(input.request_details)
    ? input.request_details : {};
  const included = Array.isArray(input.included_services) ? input.included_services : [];
  const payload = {
    zoho_record_id: text("zoho_record_id", 120),
    reference: text("reference", 80),
    customer_email: email,
    customer_id: customer?.id ?? null,
    service_type: text("service_type", 120),
    origin: text("origin"),
    destination: text("destination"),
    request_details: details,
    included_services: included,
    currency: text("currency", 12),
    quoted_total: total,
    quote_status: quoteStatus,
    payment_status: paymentStatus,
    shipment_status: text("shipment_status", 120),
    tracking_number: text("tracking_number", 120),
    updated_at: new Date().toISOString()
  };
  const { error } = await db.from("portal_jobs").upsert(payload, { onConflict: "zoho_record_id" });
  if (error) return new Response("Sync failed", { status: 500 });
  return Response.json({ ok: true, reference: payload.reference, linked_to_approved_customer: !!customer });
});
