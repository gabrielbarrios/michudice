import { createClient } from "@supabase/supabase-js";

/**
 * Cliente de servicio (service role). Bypasses RLS — usar SOLO desde server
 * actions / route handlers, nunca exponer al cliente.
 */
export function createServiceSupabase() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    throw new Error(
      "SUPABASE_SERVICE_ROLE_KEY no está configurada. Añádela a .env.local " +
        "(Supabase Dashboard → Project Settings → API → service_role) y " +
        "reinicia `npm run dev`. Se necesita para acciones de bots.",
    );
  }
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
