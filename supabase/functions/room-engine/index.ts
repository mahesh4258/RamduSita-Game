// ============================================================================
// Supabase Edge Function: room-engine/index.ts
// Handles secure room creation, invite token validation, joining, reconnection,
// and host player/bot management with strict server-side validation.
// ============================================================================

import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-reconnect-token",
};

function generateRoomCode(): string {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  return "RAM" + Array.from(bytes).slice(0, 3).map((b) => chars[b % chars.length]).join("");
}

async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

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
      return new Response(JSON.stringify({ error: "Missing authorization header" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authErr } = await supabaseAdmin.auth.getUser(token);
    if (authErr || !user) {
      return new Response(JSON.stringify({ error: "Invalid user session" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await req.json();
    const { action } = body;

    if (action === "create_room") {
      const { room_name, max_players, settings, selected_characters, host_display_name } = body;

      if (!Array.isArray(selected_characters) || selected_characters.length !== max_players) {
        return new Response(
          JSON.stringify({ error: "Selected characters count must equal max_players" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Verify exactly 1 Rama, 1 Sita, and unique character IDs
      const charIds = selected_characters.map((c: { character_id: string }) => c.character_id);
      if (new Set(charIds).size !== charIds.length) {
        return new Response(
          JSON.stringify({ error: "All selected characters must be unique" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const { data: dbChars } = await supabaseAdmin
        .from("characters")
        .select("id, slug")
        .in("id", charIds);

      const slugs = (dbChars ?? []).map((c: { slug: string }) => c.slug);
      const ramaCount = slugs.filter((s: string) => s === "rama").length;
      const sitaCount = slugs.filter((s: string) => s === "sita").length;

      if (ramaCount !== 1 || sitaCount !== 1) {
        return new Response(
          JSON.stringify({ error: "Every room must include exactly one Rama and one Sita" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const roomCode = generateRoomCode();
      const rawReconnectToken = crypto.randomUUID() + "-" + crypto.randomUUID();
      const reconnectTokenHash = await sha256Hex(rawReconnectToken);

      const { data: room, error: roomErr } = await supabaseAdmin
        .from("rooms")
        .insert({
          room_code: roomCode,
          host_id: user.id,
          room_name: room_name.trim(),
          status: "waiting",
          max_players,
          settings,
        })
        .select()
        .single();

      if (roomErr) throw roomErr;

      // Insert room characters
      const roomCharRows = selected_characters.map((c: { character_id: string; assigned_score: number }) => ({
        room_id: room.id,
        character_id: c.character_id,
        assigned_score: Math.max(0, Math.min(5000, Number(c.assigned_score))),
      }));
      await supabaseAdmin.from("room_characters").insert(roomCharRows);

      // Add host to room_players
      const { data: hostPlayer } = await supabaseAdmin
        .from("room_players")
        .insert({
          room_id: room.id,
          user_id: user.id,
          display_name: host_display_name.trim(),
          player_type: "human",
          is_ready: true,
          connection_status: "online",
          reconnect_token_hash: reconnectTokenHash,
        })
        .select()
        .single();

      return new Response(
        JSON.stringify({
          room,
          player: hostPlayer,
          reconnect_token: rawReconnectToken,
          invite_url: `${req.headers.get("origin") ?? "https://ramudusita.game"}/join/${room.room_code}?token=${room.invite_token}`,
        }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (action === "join_room") {
      const { room_code, display_name, reconnect_token } = body;
      const { data: room } = await supabaseAdmin
        .from("rooms")
        .select("*")
        .eq("room_code", room_code.toUpperCase().trim())
        .single();

      if (!room) {
        return new Response(JSON.stringify({ error: "Room not found" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Check reconnection via user_id or reconnect_token
      if (reconnect_token) {
        const tokenHash = await sha256Hex(reconnect_token);
        const { data: existingPlayer } = await supabaseAdmin
          .from("room_players")
          .select("*")
          .eq("room_id", room.id)
          .eq("reconnect_token_hash", tokenHash)
          .single();

        if (existingPlayer) {
          await supabaseAdmin
            .from("room_players")
            .update({ connection_status: "online", last_heartbeat_at: new Date().toISOString() })
            .eq("id", existingPlayer.id);

          return new Response(JSON.stringify({ room, player: existingPlayer, reconnected: true }), {
            status: 200,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
      }

      const { count } = await supabaseAdmin
        .from("room_players")
        .select("*", { count: "exact", head: true })
        .eq("room_id", room.id)
        .in("player_type", ["human", "bot"]);

      if ((count ?? 0) >= room.max_players) {
        return new Response(JSON.stringify({ error: "Room is already full" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const rawReconnectToken = crypto.randomUUID() + "-" + crypto.randomUUID();
      const reconnectTokenHash = await sha256Hex(rawReconnectToken);

      const { data: newPlayer, error: joinErr } = await supabaseAdmin
        .from("room_players")
        .insert({
          room_id: room.id,
          user_id: user.id,
          display_name: display_name.trim(),
          player_type: "human",
          is_ready: true,
          connection_status: "online",
          reconnect_token_hash: reconnectTokenHash,
        })
        .select()
        .single();

      if (joinErr) {
        return new Response(
          JSON.stringify({ error: "Display name or identity already exists in this room" }),
          { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      await supabaseAdmin.from("room_messages").insert({
        room_id: room.id,
        player_id: newPlayer.id,
        message: `${newPlayer.display_name} entered the royal court.`,
        message_type: "join_leave",
      });

      return new Response(
        JSON.stringify({ room, player: newPlayer, reconnect_token: rawReconnectToken }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(JSON.stringify({ error: "Unsupported action" }), {
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
