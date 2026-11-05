# MyEGL — Zoho CRM to secure customer portal (integration preparation)

## Current state
- The existing public MyEGL `index.html` remains a DEMO with sample records.
- `portal.html` is a NEW authenticated portal implementation, not yet linked from the public website.
- The original website's tested Zoho Web-to-Lead form is untouched.
- No Zoho account, Supabase project, or live CRM records are connected yet.
- **Do not merge/deploy as a live customer portal until the checklist below is complete.**

## Architecture
1. Customer sends a service-specific form on the existing GitHub Pages website.
2. Zoho CRM receives the lead (existing workflow).
3. ERSY GLOBAL verifies the request, prepares a quote, and assigns a unique EGL reference in Zoho.
4. Zoho Flow triggers on CRM create/update, formats the fields, and sends an OUTGOING webhook to the Supabase `zoho-sync` Edge Function with a secret request header.
5. The Edge Function authenticates the webhook and upserts a customer request in Supabase.
6. Customer signs into `portal.html` by email OTP. New accounts are always unapproved.
7. ERSY GLOBAL approves the account and checks that it belongs to the correct customer. Only then can the customer view linked jobs.
8. Customer can approve or decline a pending quote. This saves a decision to Supabase only; **syncing that decision back to Zoho is a separate required integration**.
9. Payment collection is NOT implemented. Do not store card details or mark payment as paid from browser input.

## Setup required (do not share secrets in chat)
1. Create a Supabase project in your own account. Check current free-tier limits and email sending restrictions.
2. In Supabase SQL Editor, review and run `supabase/schema.sql`.
3. In Authentication > Email Templates, configure the Magic Link template to send a six-digit OTP with `{{ .Token }}`. This frontend uses `verifyOtp` with a numeric code, not a magic link.
4. Add the portal URL to Supabase Authentication URL configuration.
5. In Supabase Edge Functions, deploy `supabase/functions/zoho-sync/index.ts`. For this endpoint only, disable the default JWT requirement, and configure a **random secret at least 32 characters** as `ZOHO_SYNC_SECRET`. Supabase provides `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` in the Edge Function runtime. NEVER put the service role key in a public website.
6. In Zoho Flow (your own Zoho account), configure a CRM record-created/updated trigger and an outgoing webhook action to the Edge Function URL. Set the HTTP header `x-ersy-flow-secret` to the secret from step 5. Keep the secret private.
7. Map at least the following JSON fields from Zoho:
   - `zoho_record_id`: unique CRM record ID
   - `reference`: unique EGL reference assigned in Zoho
   - `customer_email`: verified email for this customer
   - `service_type`: e.g. Freight Forwarding, Buy For Me
   - `origin`, `destination`
   - `request_details`: JSON object of fields the customer supplied
   - `included_services`: JSON array of included charges/services
   - `currency`, `quoted_total` (numeric)
   - `quote_status`: `not_quoted`, `pending`, `approved`, `declined`, `revision_requested`, `expired`
   - `payment_status`: `not_requested`, `pending`, `paid`, `failed`, `refunded`
   - `shipment_status`, `tracking_number`
8. In `portal-config.js`, enter ONLY the public Supabase project URL and publishable/anon key. These are designed to be public, protected by Row Level Security.
9. Create a test customer via email OTP. In Supabase Table Editor, verify `portal_customers.approved=false` and that the account cannot view jobs.
10. After checking identity, approve the test customer via an authenticated admin action in Supabase. Example SQL (only for a verified test account):
   `update public.portal_customers set approved=true where email='verified-test@example.com';`
11. Re-run the Zoho Flow sync for that customer so the server can associate the CRM job with the now-approved account. Verify one user cannot see another user's jobs, even by changing the URL or API query.
12. Test a quote approval and rejection. Plan a server-to-Zoho update workflow so ERSY GLOBAL receives customer decisions.
13. Only after end-to-end tests, replace the demo navigation link with the live portal link.

## Security notes
- Public GitHub Pages cannot store CRM credentials or secret keys.
- The Edge Function must authenticate every Zoho Flow request; it must not expose CORS to browsers.
- RLS is enabled on both tables. Only approved users can read their own jobs.
- A user registering with a customer's email does not receive access until ERSY GLOBAL manually approves them.
- Quote approval does not authorize or process payments.
- Never use a direct client-side Zoho API key or place a payment processor secret in HTML/JavaScript.
- Customer account identity must be verified before approving.
- For launch, add rate limiting/abuse protection, webhook replay protection, audit logging, email delivery configuration and privacy terms.
