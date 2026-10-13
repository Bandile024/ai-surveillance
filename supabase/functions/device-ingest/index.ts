import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const maxSnapshotBytes = 8 * 1024 * 1024;
const supportedTypes = new Set([
  "INTRUSION",
  "MODE_CHANGE",
  "CONTROL_REQUESTED",
  "CONTROL_APPLIED",
  "CONTROL_FAILED",
]);

const jsonResponse = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

const hashToken = async (token: string): Promise<string> => {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(token),
  );
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
};

if (!supabaseUrl || !serviceRoleKey) {
  throw new Error("Supabase function environment is missing required secrets.");
}

const supabase = createClient(supabaseUrl, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  const authorization = request.headers.get("Authorization") ?? "";
  const tokenMatch = /^Bearer\s+(.+)$/i.exec(authorization);
  const token = tokenMatch?.[1];
  if (!token || token.length < 32) {
    return jsonResponse({ error: "Invalid device credentials" }, 401);
  }

  const tokenHash = await hashToken(token);
  const { data: credential, error: credentialError } = await supabase
    .from("device_credentials")
    .select("device_id")
    .eq("token_hash", tokenHash)
    .eq("is_active", true)
    .maybeSingle();
  if (credentialError) {
    console.error("Unable to validate device credential:", credentialError.message);
    return jsonResponse({ error: "Unable to authenticate device" }, 500);
  }
  if (!credential) {
    return jsonResponse({ error: "Invalid device credentials" }, 401);
  }

  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return jsonResponse({ error: "Expected multipart form data" }, 400);
  }

  const eventField = form.get("event");
  if (typeof eventField !== "string") {
    return jsonResponse({ error: "Missing event payload" }, 400);
  }

  let event: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(eventField);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return jsonResponse({ error: "Event must be a JSON object" }, 400);
    }
    event = parsed as Record<string, unknown>;
  } catch {
    return jsonResponse({ error: "Invalid event JSON" }, 400);
  }

  const eventId = event.event_id;
  const eventType = event.event_type;
  const timestamp = event.occurred_at;
  const data = event.data;
  if (
    typeof eventId !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(eventId) ||
    typeof eventType !== "string" ||
    !supportedTypes.has(eventType) ||
    typeof timestamp !== "string" ||
    Number.isNaN(Date.parse(timestamp)) ||
    !data ||
    typeof data !== "object" ||
    Array.isArray(data)
  ) {
    return jsonResponse({ error: "Invalid event fields" }, 400);
  }

  if (
    eventType === "MODE_CHANGE" &&
    !["SAFE", "GUARD"].includes((data as Record<string, unknown>).new_mode as string)
  ) {
    return jsonResponse({ error: "Invalid mode change data" }, 400);
  }

  const snapshotField = form.get("snapshot");
  let snapshotPath: string | null = null;
  if (snapshotField !== null) {
    if (
      eventType !== "INTRUSION" ||
      !(snapshotField instanceof File) ||
      snapshotField.type !== "image/jpeg" ||
      snapshotField.size > maxSnapshotBytes
    ) {
      return jsonResponse({ error: "Invalid snapshot image" }, 400);
    }

    snapshotPath = `${credential.device_id}/${eventId}.jpg`;
    const { error: uploadError } = await supabase.storage
      .from("intrusion-snapshots")
      .upload(snapshotPath, snapshotField, {
        contentType: "image/jpeg",
        upsert: true,
      });
    if (uploadError) {
      console.error("Snapshot upload failed:", uploadError.message);
      return jsonResponse({ error: "Snapshot upload failed" }, 502);
    }
  }

  const occurredAt = new Date(timestamp).toISOString();
  const { error: insertError } = await supabase.from("device_events").insert({
    id: eventId,
    device_id: credential.device_id,
    event_type: eventType,
    occurred_at: occurredAt,
    data,
    snapshot_path: snapshotPath,
  });

  let duplicate = false;
  if (insertError) {
    const { data: existing, error: lookupError } = await supabase
      .from("device_events")
      .select("device_id")
      .eq("id", eventId)
      .maybeSingle();
    if (lookupError || !existing || existing.device_id !== credential.device_id) {
      console.error("Event persistence failed:", insertError.message);
      return jsonResponse({ error: "Event persistence failed" }, 500);
    }
    duplicate = true;
  }

  return jsonResponse({
    event_id: eventId,
    snapshot_path: snapshotPath,
    duplicate,
  }, duplicate ? 200 : 201);
});
