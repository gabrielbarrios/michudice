import { createClient } from "@supabase/supabase-js";

/**
 * Cliente de servicio (service role). Bypasses RLS — usar SOLO desde server
 * actions / route handlers, nunca exponer al cliente.
 */
export function createServiceSupabase() {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}
