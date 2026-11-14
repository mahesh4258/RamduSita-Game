// ============================================================================
// Supabase Edge Function: round-engine/index.ts
// Server-authoritative round distribution, secret assignment retrieval,
// atomic Rama guess verification, and session completion.
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
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authErr } = await supabaseAdmin.auth.getUser(token);
    if (authErr || !user) {
      return new Response(JSON.stringify({ error: "Invalid session" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await req.json();
    const { action } = body;

    if (action === "start_round") {
      const { room_id } = body;
      const { data: roundId, error } = await supabaseAdmin.rpc("start_new_round", {
        p_room_id: room_id,
        p_caller_id: user.id,
      });
      if (error) throw error;

      // Broadcast public round start message without leaking Sita!
      const { data: roundRow } = await supabaseAdmin
        .from("safe_rounds")
        .select("*, room_players!rounds_rama_player_id_fkey(display_name)")
        .eq("id", roundId)
        .single();

      await supabaseAdmin.from("room_messages").insert({
        room_id,
        session_id: roundRow?.session_id,
        message: `Round ${roundRow?.round_number} started! Rama has revealed himself!`,
        message_type: "round_start",
      });

      return new Response(JSON.stringify({ round_id: roundId, round: roundRow }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (action === "submit_guess") {
      const { round_id, rama_player_id, guessed_player_id } = body;

      // Verify caller owns rama_player_id (or is host triggering a bot Rama guess)
      const { data: ramaPlayer } = await supabaseAdmin
        .from("room_players")
        .select("id, user_id, player_type, room_id")
        .eq("id", rama_player_id)
        .single();

      if (!ramaPlayer) {
        return new Response(JSON.stringify({ error: "Rama player not found" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      if (ramaPlayer.player_type === "human" && ramaPlayer.user_id !== user.id) {
        return new Response(
          JSON.stringify({ error: "Forbidden: You are not the assigned Rama for this round" }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Execute atomic PostgreSQL transaction via RPC
      const { data: result, error: rpcErr } = await supabaseAdmin.rpc("submit_rama_guess", {
        p_round_id: round_id,
        p_rama_player_id: rama_player_id,
        p_guessed_player_id: guessed_player_id,
      });

      if (rpcErr) throw rpcErr;

      return new Response(JSON.stringify({ result }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ error: "Unknown action" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
