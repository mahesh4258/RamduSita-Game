// ============================================================================
// Supabase Edge Function: admin-ops/index.ts
// Enforces backend RBAC (role = 'admin' in public.profiles) and logs every
// administrative mutation into public.admin_logs.
// ============================================================================

import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing Authorization header" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authErr } = await supabaseAdmin.auth.getUser(token);
    if (authErr || !user) {
      return new Response(JSON.stringify({ error: "Invalid token" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Strict backend role verification against public.profiles
    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("id, role, is_disabled")
      .eq("id", user.id)
      .single();

    if (!profile || profile.role !== "admin" || profile.is_disabled) {
      return new Response(
        JSON.stringify({ error: "Forbidden: Backend RBAC check failed (admin role required)" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body = await req.json();
    const { action, payload } = body;

    if (action === "upsert_ad") {
      // Sanitize third-party snippet if present (only allow sandboxed iframe attributes)
      const sanitizedPayload = {
        ...payload,
        ad_code: payload.ad_code
          ? String(payload.ad_code).replace(/<script\b[^>]*>([\s\S]*?)<\/script>/gim, "")
          : null,
      };

      const { data: ad, error } = await supabaseAdmin
        .from("advertisements")
        .upsert(sanitizedPayload)
        .select()
        .single();
      if (error) throw error;

      await supabaseAdmin.from("admin_logs").insert({
        admin_id: user.id,
        action: payload.id ? "UPDATE_ADVERTISEMENT" : "CREATE_ADVERTISEMENT",
        target_type: "advertisements",
        target_id: ad.id,
        metadata: { title: ad.title, placement: ad.placement },
      });

      return new Response(JSON.stringify({ ad }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (action === "update_character_score") {
      const { character_id, default_score, is_active } = payload;
      const { data: character, error } = await supabaseAdmin
        .from("characters")
        .update({ default_score, is_active })
        .eq("id", character_id)
        .select()
        .single();
      if (error) throw error;

      await supabaseAdmin.from("admin_logs").insert({
        admin_id: user.id,
        action: "UPDATE_CHARACTER_CONFIG",
        target_type: "characters",
        target_id: character_id,
        metadata: { default_score, is_active },
      });

      return new Response(JSON.stringify({ character }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (action === "toggle_user_ban") {
      const { target_user_id, is_disabled } = payload;
      const { data: updatedUser, error } = await supabaseAdmin
        .from("profiles")
        .update({ is_disabled })
        .eq("id", target_user_id)
        .select()
        .single();
      if (error) throw error;

      await supabaseAdmin.from("admin_logs").insert({
        admin_id: user.id,
        action: is_disabled ? "DISABLE_USER_ACCOUNT" : "ENABLE_USER_ACCOUNT",
        target_type: "profiles",
        target_id: target_user_id,
      });

      return new Response(JSON.stringify({ profile: updatedUser }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ error: "Unknown admin action" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
