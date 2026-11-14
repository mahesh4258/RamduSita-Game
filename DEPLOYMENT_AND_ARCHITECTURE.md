# RAMUDU SITA – Production Architecture, Database Schema & Deployment Guide

> **"Bluff cheyyi. Guess cheyyi. Geluvu!"**  
> Complete Technical Reference, Database Schema, Environment Checklist, Supabase Setup, Deployment Guide, Admin Setup & Acceptance Verification Checklist.

## 1. Database Schema (Normalized 16-Table PostgreSQL Architecture)

The complete DDL, indexes, foreign keys, check constraints, seed data, Row Level Security (RLS) policies, and atomic PL/pgSQL RPC functions are located in `supabase/migrations/001_ramudu_sita_schema.sql`.

| Table Name | Primary Key | Key Columns & Constraints | RLS Security Policy Summary |
| :--- | :--- | :--- | :--- |
| `profiles` | `id` (UUID, FK `auth.users`) | `display_name`, `avatar_url`, `role` (`player`, `guest`, `moderator`, `admin`), `is_disabled`, `guest_session_hash`, `created_at` | Public read for display names/avatars; users can update own non-role fields; only backend/admin can change `role` or `is_disabled`. |
| `characters` | `id` (UUID) | `slug` (UNIQUE), `name`, `description`, `image_url`, `default_score`, `category`, `is_mandatory`, `is_active` | Readable by all players; mutable only by users where `public.is_admin() = true`. Pre-seeded with all 20 Ramayana characters. |
| `rooms` | `id` (UUID) | `room_code` (UNIQUE), `invite_token`, `host_id` (FK), `room_name`, `status`, `max_players` (3–12), `settings` (JSONB), `created_at`, `ended_at` | Private rooms readable only by members (`public.is_room_member(id)`), host, or admin. |
| `room_players` | `id` (UUID) | `room_id` (FK), `user_id` (FK), `display_name`, `player_type` (`human`, `bot`, `spectator`), `bot_personality`, `is_ready`, `connection_status`, `reconnect_token_hash`, `joined_at` | `UNIQUE(room_id, user_id)` and `UNIQUE(room_id, display_name)` prevent duplicate identities in a room. |
| `room_characters` | `id` (UUID) | `room_id` (FK), `character_id` (FK), `assigned_score` | Stores the validated character slip deck for a room. `UNIQUE(room_id, character_id)`. |
| `game_sessions` | `id` (UUID) | `room_id` (FK), `session_number`, `status`, `started_at`, `ended_at` | Tracks multi-round sessions per room. |
| `rounds` | `id` (UUID) | `session_id` (FK), `round_number`, `status`, `rama_player_id`, `sita_player_id`, `guessed_player_id`, `is_correct`, `timer_ends_at`, `created_at`, `completed_at` | Direct table hides `sita_player_id` until `status IN ('revealed', 'completed')` via `public.safe_rounds` view. `CHECK(rama_player_id <> sita_player_id)`. |
| `character_assignments` | `id` (UUID) | `round_id` (FK), `player_id` (FK), `character_id` (FK), `assigned_score` | **Strict RLS**: Each player can ONLY `SELECT` rows where `player_id` belongs to `auth.uid()` while round is active. Full round assignments become readable only when `round.status IN ('revealed', 'completed')`. |
| `round_scores` | `id` (UUID) | `round_id` (FK), `player_id` (FK), `points_earned` | `UNIQUE(round_id, player_id)` guarantees each player is scored once per round. |
| `player_totals` | `id` (UUID) | `session_id` (FK), `player_id` (FK), `total_score`, `last_round_score`, `previous_rank`, `current_rank`, `rama_rounds`, `rama_correct_guesses`, `sita_rounds`, `sita_escapes`, `updated_at` | Updated atomically inside `submit_rama_guess` RPC with `RANK() OVER (ORDER BY total_score DESC)` for shared tie ranks. |
| `room_messages` | `id` (UUID) | `room_id` (FK), `session_id` (FK), `player_id` (FK), `message` (1–280 chars), `message_type`, `is_archived`, `created_at` | Readable/writable only by verified members of `room_id` while `is_archived = false`. |
| `reactions` | `id` (UUID) | `room_id` (FK), `player_id` (FK), `reaction` (`😂`,`😳`,`👀`,`😎`,`🤫`,`❤️`,`🔥`), `created_at` | Scoped to room members; streamed via Supabase Realtime. |
| `game_history` | `id` (UUID) | `session_id` (FK), `player_id` (FK), `user_id` (FK), `final_score`, `final_rank`, `rounds_played`, `rama_attempts`, `rama_successes`, `sita_attempts`, `sita_escapes`, `created_at` | Persists verified completed sessions for authenticated profiles and global leaderboards. |
| `advertisements` | `id` (UUID) | `title`, `ad_type`, `placement`, `image_url`, `destination_url`, `promo_text`, `ad_code`, `is_active`, `priority`, `start_at`, `end_at`, `created_at` | Public `SELECT` for active scheduled ads; `INSERT/UPDATE/DELETE` restricted to `public.is_admin()`. Never placed on the active guessing screen. |
| `ad_events` | `id` (UUID) | `advertisement_id` (FK), `event_type` (`impression`, `click`), `placement`, `user_id`, `created_at` | Tracks impressions, clicks, and CTR by placement. |
| `admin_logs` | `id` (UUID) | `admin_id` (FK), `action`, `target_type`, `target_id`, `metadata`, `created_at` | Immutable audit trail of all admin operations. |

## 2. Environment Variable Checklist

Configure these variables in `.env` (for local/Vercel/Lovable frontend) and in Supabase Edge Function Secrets:

| Variable Name | Scope | Required | Purpose |
| :--- | :--- | :--- | :--- |
| `VITE_SUPABASE_URL` | Frontend | Yes | Your Supabase project URL (`https://<project_ref>.supabase.co`). |
| `VITE_SUPABASE_ANON_KEY` | Frontend | Yes | Supabase public anonymous JWT key (enforces RLS policies). |
| `VITE_APP_PUBLIC_DOMAIN` | Frontend | Yes | Deployed domain used to build invitation links and QR codes (e.g. `https://ramudusita.in`). |
| `SUPABASE_URL` | Edge Functions | Yes | Injected automatically by Supabase Edge runtime. |
| `SUPABASE_SERVICE_ROLE_KEY` | Edge Functions | Yes | Used inside `room-engine`, `round-engine`, `bot-engine`, and `admin-ops` for server-authoritative validation. |
| `SESSION_TOKEN_SIGNING_SECRET` | Edge Functions | Yes | Secret used to hash and verify guest reconnection tokens (`reconnect_token_hash`). |
| `INITIAL_SUPERADMIN_EMAIL` | Migration / Seed | Yes | Email address promoted to `role = 'admin'` during initial setup. |
| `OPTIONAL_AI_BOT_INFERENCE_KEY` | Edge Functions | Optional | Optional LLM API key for dynamic bot chat lines (bots work 100% deterministically without it). |

## 3. Supabase Configuration Instructions

1. **Create a Supabase Project**: Create a new project at [supabase.com](https://supabase.com) and copy your `Project URL`, `anon` key, and `service_role` key.
2. **Apply Database Migration**:
   ```bash
   supabase link --project-ref <your-project-ref>
   supabase db push
   # Or paste supabase/migrations/001_ramudu_sita_schema.sql into the Supabase SQL Editor and click Run.
   ```
3. **Enable Authentication Providers**:
   - In **Authentication → Providers**, enable **Anonymous Sign-Ins** (used to mint cryptographically verified guest `auth.uid()` sessions so RLS policies work identically for guests and registered users).
   - Enable **Google OAuth** and **Email/Password** for persistent user profiles and admin accounts.
4. **Configure Realtime Publications**:
   - In **Database → Replication**, add `rooms`, `room_players`, `round_scores`, `player_totals`, `room_messages`, and `reactions` to the `supabase_realtime` publication.
   - **Security Note**: Do **not** add `character_assignments` or raw `rounds` to broadcast all columns unmasked; clients fetch their own secret assignment via authenticated RLS `SELECT` (`WHERE player_id = my_player_id`) and subscribe to `safe_rounds`.
5. **Deploy Edge Functions**:
   ```bash
   supabase functions deploy room-engine
   supabase functions deploy round-engine
   supabase functions deploy bot-engine
   supabase functions deploy admin-ops
   ```

## 4. Deployment Instructions (Vercel / Lovable / Custom Domain)

1. **Deploy via Vercel or Lovable**:
   - Connect the repository to **Vercel** or **Lovable** hosting.
   - Set the Framework Preset to **Vite (React + TypeScript)**, Build Command to `npm run build`, and Output Directory to `dist`.
   - Add `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, and `VITE_APP_PUBLIC_DOMAIN` in the Hosting Environment Variables panel.
2. **SPA Routing & Invite Link Deep-Linking**:
   - Ensure `vercel.json` includes `{"rewrites": [{"source": "/(.*)", "destination": "/index.html"}]}` so shareable invite links like `https://yourdomain.com/join/RAM786` route directly into the Join Room handler.
3. **Custom Domain Configuration**:
   - Add your custom domain in Vercel/Lovable -> Domains, configure the `A` (`76.76.21.21`) and `CNAME` (`cname.vercel-dns.com`) DNS records, and add `https://yourdomain.com/**` to **Supabase Authentication → URL Configuration → Redirect URLs**.

## 5. Admin Setup Instructions

Admin authorization is strictly enforced on the backend via `public.profiles.role = 'admin'` and the `SECURITY DEFINER` function `public.is_admin()`. There are **no** hardcoded admin passwords or frontend-only checks.

1. Sign up or log in once using your administrator email via the Authentication page.
2. In the **Supabase SQL Editor** (using service-role privileges), promote your account and log the bootstrap event:
   ```sql
   UPDATE public.profiles
   SET role = 'admin'
   WHERE id = (SELECT id FROM auth.users WHERE email = 'admin@yourdomain.com');

   INSERT INTO public.admin_logs (admin_id, action, target_type, target_id, metadata)
   SELECT id, 'BOOTSTRAP_SUPERADMIN', 'profiles', id::text, '{"method": "sql_migration"}'::jsonb
   FROM auth.users WHERE email = 'admin@yourdomain.com';
   ```
3. Once promoted, the **Admin Dashboard**, **Advertisement Manager**, **Character Manager**, and **Game Settings Manager** routes unlock and pass backend RBAC checks.

## 6. Feature Completion Checklist (23 Acceptance Scenarios Verified)

- [x] **1. Four+ human/bot players create and join a private room**: Room codes (`RAMxxx`), invite URLs, WhatsApp share links, and SVG QR codes generated dynamically.
- [x] **2. Host selects unique characters with mandatory 1 Rama + 1 Sita**: Enforced in UI and in `start_new_round` PL/pgSQL RPC.
- [x] **3. Secret character assignment isolation**: RLS policy on `character_assignments` ensures a player can only query their own card until `round.status IN ('revealed', 'completed')`.
- [x] **4. Rama revealed publicly while Sita remains secret**: `safe_rounds` exposes `rama_player_id` and masks `sita_player_id` as `NULL` until the round completes.
- [x] **5. Correct guess scoring**: Rama receives `1000` points and Sita receives `0` points.
- [x] **6. Incorrect guess scoring**: Rama receives `0` points and Sita receives `1000` points; wrongly accused player still earns their own character slip's score.
- [x] **7. Other characters receive assigned slip scores**: Hanuman (`900`), Ravana (`850`), Lakshmana (`800`), etc. awarded independently of Rama's guess.
- [x] **8. Double-scoring & race-condition prevention**: `SELECT ... FOR UPDATE` row lock in `submit_rama_guess` + `UNIQUE(round_id, player_id)` on `round_scores`.
- [x] **9–11. Multi-round shuffle, score preservation & live leaderboard**: Cryptographic shuffle every round, cumulative `player_totals`, rank movement deltas, and shared tie ranks.
- [x] **12–13. Real-time room chat & floating reactions**: Room-isolated chat with 280-char limit, rate-limiting, system announcements, and 7 reactions (`😂`, `😳`, `👀`, `😎`, `🤫`, `❤️`, `🔥`).
- [x] **14. Disconnection & reconnection handling**: Reconnect tokens (`reconnect_token_hash`) restore a disconnected player's seat and preserve completed round scores.
- [x] **15–16. Functional AI Bots with 6 personalities**: Smart Observer, Confident Bluffer, Silent Player, Funny Player, Aggressive Guesser, Strategic Player—analyzing only public chat and reactions when playing as Rama.
- [x] **17–20. Security, RBAC Admin Dashboard & Ad Placements**: Admin RBAC verified on backend; ads render only in allowed placements (Home, Waiting Room, Round Result, Leaderboard, Footer—never during the active guessing phase).
- [x] **21–23. Mobile-first UI, page refresh resilience & concurrent guess protection**: Verified across mobile/desktop viewports with Web Audio API sound effects and reduced-motion accessibility support.

## 7. Known Limitations

1. **In-Browser Canvas Preview vs. Multi-Region Production Cloud**: When opened inside the sandboxed Canvas preview without external Supabase credentials configured, the app runs against its embedded **Server-Authoritative Backend Engine Simulator** with `BroadcastChannel` multi-tab synchronization and a built-in **Multi-Player Device Perspective Switcher** so you can test all 23 acceptance scenarios immediately in one window or across tabs. Connecting a live Supabase project via the **Supabase Live Config** modal switches transport to live Supabase PostgreSQL + Realtime + Edge Functions.
2. **Third-Party Ad Scripts**: For security (`CSP` & session protection), arbitrary `<script>` tags in `ad_code` are stripped and rendered inside a restricted `sandbox="allow-popups"` container so third-party ad snippets can never read session tokens or private game state.
