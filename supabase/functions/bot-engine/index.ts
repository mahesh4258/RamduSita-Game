// ============================================================================
// Supabase Edge Function: bot-engine/index.ts
// Server-side AI Bot decision engine supporting 6 personalities.
// Bots NEVER access private human character_assignments; they only inspect
// their own assignment, public room_messages, and public reactions.
// ============================================================================

import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

export type BotPersonality =
  | "smart_observer"
  | "confident_bluffer"
  | "silent_player"
  | "funny_player"
  | "aggressive_guesser"
  | "strategic_player";

interface PublicSignal {
  player_id: string;
  message_count: number;
  reaction_count: number;
  claimed_sita_or_bluffed: boolean;
  suspicious_reactions: number;
}

export function selectBotRamaTarget(
  personality: BotPersonality,
  ramaPlayerId: string,
  candidates: PublicSignal[]
): string {
  const eligible = candidates.filter((c) => c.player_id !== ramaPlayerId);
  if (eligible.length === 0) throw new Error("No eligible target candidates");

  // Compute suspicion weights strictly from PUBLIC chat/reaction signals
  const scored = eligible.map((c) => {
    let weight = 10;
    switch (personality) {
      case "smart_observer":
        // Suspects players who are overly quiet or send nervous reactions (😳, 🤫)
        weight += (c.message_count === 0 ? 15 : 0) + c.suspicious_reactions * 12;
        break;
      case "confident_bluffer":
        // Suspects players who loudly bluff in chat
        weight += c.claimed_sita_or_bluffed ? 25 : c.message_count * 6;
        break;
      case "silent_player":
        // Targets the most talkative player
        weight += c.message_count * 10 + c.reaction_count * 5;
        break;
      case "aggressive_guesser":
        // Rapidly targets players with high reaction activity
        weight += c.reaction_count * 14;
        break;
      case "strategic_player":
        // Balances silence and bluffing signals
        weight += (c.claimed_sita_or_bluffed ? 18 : 8) + c.suspicious_reactions * 10;
        break;
      case "funny_player":
      default:
        weight += Math.floor(Math.random() * 20);
        break;
    }
    return { player_id: c.player_id, weight };
  });

  scored.sort((a, b) => b.weight - a.weight);
  return scored[0].player_id;
}

serve(async (req: Request) => {
  const supabaseAdmin = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  );

  const { round_id, room_id, bot_player_id, personality } = await req.json();

  // Fetch ONLY public room players, public messages, and public reactions
  const { data: players } = await supabaseAdmin
    .from("room_players")
    .select("id")
    .eq("room_id", room_id)
    .in("player_type", ["human", "bot"]);

  const { data: messages } = await supabaseAdmin
    .from("room_messages")
    .select("player_id, message")
    .eq("room_id", room_id);

  const { data: reactions } = await supabaseAdmin
    .from("reactions")
    .select("player_id, reaction")
    .eq("room_id", room_id);

  const signals: PublicSignal[] = (players ?? []).map((p: { id: string }) => {
    const pMsgs = (messages ?? []).filter((m: { player_id: string }) => m.player_id === p.id);
    const pReacts = (reactions ?? []).filter((r: { player_id: string }) => r.player_id === p.id);
    return {
      player_id: p.id,
      message_count: pMsgs.length,
      reaction_count: pReacts.length,
      claimed_sita_or_bluffed: pMsgs.some((m: { message: string }) =>
        /sita|catch me|not me|hanuman|ravana/i.test(m.message)
      ),
      suspicious_reactions: pReacts.filter((r: { reaction: string }) =>
        ["😳", "👀", "🤫"].includes(r.reaction)
      ).length,
    };
  });

  const targetId = selectBotRamaTarget(personality ?? "smart_observer", bot_player_id, signals);

  const { data: resolution, error } = await supabaseAdmin.rpc("submit_rama_guess", {
    p_round_id: round_id,
    p_rama_player_id: bot_player_id,
    p_guessed_player_id: targetId,
  });

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 400 });
  }

  return new Response(JSON.stringify({ guessed_player_id: targetId, resolution }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
