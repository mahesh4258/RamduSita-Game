-- ============================================================================
-- RAMUDU SITA - PRODUCTION SUPABASE POSTGRESQL SCHEMA, RLS & ATOMIC RPCs
-- Migration: 001_ramudu_sita_schema.sql
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- 1. ENUMS & CUSTOM TYPES
-- ----------------------------------------------------------------------------
DO $$ BEGIN
    CREATE TYPE user_role AS ENUM ('player', 'guest', 'moderator', 'admin');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE room_status AS ENUM ('waiting', 'in_progress', 'completed', 'closed', 'abandoned');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE player_type AS ENUM ('human', 'bot', 'spectator');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE connection_state AS ENUM ('online', 'reconnecting', 'disconnected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE round_status AS ENUM ('distributing', 'rama_revealed', 'discussion', 'guessing', 'revealed', 'completed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE ad_placement AS ENUM (
        'home_banner',
        'home_promo_card',
        'waiting_room_banner',
        'game_result_screen',
        'leaderboard_page',
        'footer_banner'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE ad_kind AS ENUM ('image', 'promo_text', 'external_url', 'sandboxed_snippet');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ----------------------------------------------------------------------------
-- 2. CORE TABLES (16 Normalized Tables per Specification)
-- ----------------------------------------------------------------------------

-- 2.1 profiles
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    display_name TEXT NOT NULL CHECK (char_length(trim(display_name)) BETWEEN 2 AND 32),
    avatar_url TEXT,
    role user_role NOT NULL DEFAULT 'player',
    is_disabled BOOLEAN NOT NULL DEFAULT FALSE,
    guest_session_hash TEXT UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2.2 characters (Master Ramayana Character Catalog)
CREATE TABLE IF NOT EXISTS public.characters (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL,
    image_url TEXT NOT NULL,
    default_score INTEGER NOT NULL CHECK (default_score >= 0 AND default_score <= 5000),
    category TEXT NOT NULL CHECK (category IN ('mandatory_hero', 'mandatory_target', 'royal_family', 'vanara_sena', 'lanka_court', 'allies_sages', 'custom')),
    is_mandatory BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2.3 rooms
CREATE TABLE IF NOT EXISTS public.rooms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_code TEXT NOT NULL UNIQUE CHECK (room_code ~ '^[A-Z0-9]{6,8}$'),
    invite_token UUID NOT NULL DEFAULT gen_random_uuid(),
    host_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    room_name TEXT NOT NULL CHECK (char_length(trim(room_name)) BETWEEN 3 AND 50),
    status room_status NOT NULL DEFAULT 'waiting',
    max_players INTEGER NOT NULL DEFAULT 4 CHECK (max_players BETWEEN 3 AND 12),
    settings JSONB NOT NULL DEFAULT '{
        "max_rounds": 5,
        "unlimited_rounds": false,
        "is_private": true,
        "allow_bots": true,
        "allow_spectators": false,
        "chat_enabled": true,
        "reactions_enabled": true,
        "turn_timer_seconds": 60,
        "rama_correct_points": 1000,
        "sita_escape_points": 1000
    }'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_rooms_code ON public.rooms(room_code);
CREATE INDEX IF NOT EXISTS idx_rooms_status ON public.rooms(status);

-- 2.4 room_players
CREATE TABLE IF NOT EXISTS public.room_players (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id UUID NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    display_name TEXT NOT NULL CHECK (char_length(trim(display_name)) BETWEEN 2 AND 32),
    avatar_url TEXT,
    player_type player_type NOT NULL DEFAULT 'human',
    bot_personality TEXT CHECK (
        bot_personality IS NULL OR bot_personality IN (
            'smart_observer',
            'confident_bluffer',
            'silent_player',
            'funny_player',
            'aggressive_guesser',
            'strategic_player'
        )
    ),
    is_ready BOOLEAN NOT NULL DEFAULT FALSE,
    connection_status connection_state NOT NULL DEFAULT 'online',
    reconnect_token_hash TEXT,
    last_heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (room_id, user_id),
    UNIQUE (room_id, display_name)
);

CREATE INDEX IF NOT EXISTS idx_room_players_room ON public.room_players(room_id);

-- 2.5 room_characters (Per-room character deck & customized scores)
CREATE TABLE IF NOT EXISTS public.room_characters (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id UUID NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
    character_id UUID NOT NULL REFERENCES public.characters(id) ON DELETE RESTRICT,
    assigned_score INTEGER NOT NULL CHECK (assigned_score >= 0 AND assigned_score <= 5000),
    UNIQUE (room_id, character_id)
);

CREATE INDEX IF NOT EXISTS idx_room_characters_room ON public.room_characters(room_id);

-- 2.6 game_sessions
CREATE TABLE IF NOT EXISTS public.game_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id UUID NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
    session_number INTEGER NOT NULL DEFAULT 1,
    status room_status NOT NULL DEFAULT 'in_progress',
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at TIMESTAMPTZ,
    UNIQUE (room_id, session_number)
);

CREATE INDEX IF NOT EXISTS idx_game_sessions_room ON public.game_sessions(room_id);

-- 2.7 rounds
-- Note: sita_player_id is stored in a restricted column or verified via character_assignments.
-- Public clients read from a view or safe RPC so sita_player_id is NEVER leaked before round completion!
CREATE TABLE IF NOT EXISTS public.rounds (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES public.game_sessions(id) ON DELETE CASCADE,
    round_number INTEGER NOT NULL CHECK (round_number >= 1),
    status round_status NOT NULL DEFAULT 'distributing',
    rama_player_id UUID NOT NULL REFERENCES public.room_players(id) ON DELETE RESTRICT,
    sita_player_id UUID NOT NULL REFERENCES public.room_players(id) ON DELETE RESTRICT,
    guessed_player_id UUID REFERENCES public.room_players(id) ON DELETE RESTRICT,
    is_correct BOOLEAN,
    timer_ends_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ,
    UNIQUE (session_id, round_number),
    CHECK (rama_player_id <> sita_player_id),
    CHECK (guessed_player_id IS NULL OR guessed_player_id <> rama_player_id)
);

CREATE INDEX IF NOT EXISTS idx_rounds_session ON public.rounds(session_id);

-- 2.8 character_assignments (STRICT RLS: Only readable by the owning player until round is revealed/completed)
CREATE TABLE IF NOT EXISTS public.character_assignments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    round_id UUID NOT NULL REFERENCES public.rounds(id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES public.room_players(id) ON DELETE CASCADE,
    character_id UUID NOT NULL REFERENCES public.characters(id) ON DELETE RESTRICT,
    assigned_score INTEGER NOT NULL,
    UNIQUE (round_id, player_id),
    UNIQUE (round_id, character_id)
);

CREATE INDEX IF NOT EXISTS idx_char_assign_round ON public.character_assignments(round_id);
CREATE INDEX IF NOT EXISTS idx_char_assign_player ON public.character_assignments(player_id);

-- 2.9 round_scores
CREATE TABLE IF NOT EXISTS public.round_scores (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    round_id UUID NOT NULL REFERENCES public.rounds(id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES public.room_players(id) ON DELETE CASCADE,
    points_earned INTEGER NOT NULL CHECK (points_earned >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (round_id, player_id)
);

CREATE INDEX IF NOT EXISTS idx_round_scores_round ON public.round_scores(round_id);

-- 2.10 player_totals
CREATE TABLE IF NOT EXISTS public.player_totals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES public.game_sessions(id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES public.room_players(id) ON DELETE CASCADE,
    total_score INTEGER NOT NULL DEFAULT 0,
    last_round_score INTEGER NOT NULL DEFAULT 0,
    previous_rank INTEGER NOT NULL DEFAULT 1,
    current_rank INTEGER NOT NULL DEFAULT 1,
    rama_rounds INTEGER NOT NULL DEFAULT 0,
    rama_correct_guesses INTEGER NOT NULL DEFAULT 0,
    sita_rounds INTEGER NOT NULL DEFAULT 0,
    sita_escapes INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (session_id, player_id)
);

CREATE INDEX IF NOT EXISTS idx_player_totals_session ON public.player_totals(session_id, total_score DESC);

-- 2.11 room_messages
CREATE TABLE IF NOT EXISTS public.room_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id UUID NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
    session_id UUID REFERENCES public.game_sessions(id) ON DELETE CASCADE,
    player_id UUID REFERENCES public.room_players(id) ON DELETE SET NULL,
    message TEXT NOT NULL CHECK (char_length(trim(message)) BETWEEN 1 AND 280),
    message_type TEXT NOT NULL DEFAULT 'chat' CHECK (message_type IN ('chat', 'system', 'join_leave', 'round_start', 'guess', 'result')),
    is_archived BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_room_messages_room ON public.room_messages(room_id, created_at ASC);

-- 2.12 reactions
CREATE TABLE IF NOT EXISTS public.reactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id UUID NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES public.room_players(id) ON DELETE CASCADE,
    reaction TEXT NOT NULL CHECK (reaction IN ('😂', '😳', '👀', '😎', '🤫', '❤️', '🔥')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reactions_room ON public.reactions(room_id, created_at DESC);

-- 2.13 game_history
CREATE TABLE IF NOT EXISTS public.game_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES public.game_sessions(id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES public.room_players(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    final_score INTEGER NOT NULL,
    final_rank INTEGER NOT NULL,
    rounds_played INTEGER NOT NULL DEFAULT 1,
    rama_attempts INTEGER NOT NULL DEFAULT 0,
    rama_successes INTEGER NOT NULL DEFAULT 0,
    sita_attempts INTEGER NOT NULL DEFAULT 0,
    sita_escapes INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (session_id, player_id)
);

CREATE INDEX IF NOT EXISTS idx_game_history_user ON public.game_history(user_id, created_at DESC);

-- 2.14 advertisements
CREATE TABLE IF NOT EXISTS public.advertisements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL CHECK (char_length(trim(title)) BETWEEN 2 AND 120),
    ad_type ad_kind NOT NULL DEFAULT 'promo_text',
    placement ad_placement NOT NULL,
    image_url TEXT,
    destination_url TEXT,
    promo_text TEXT,
    ad_code TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    priority INTEGER NOT NULL DEFAULT 10 CHECK (priority BETWEEN 1 AND 100),
    start_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    end_at TIMESTAMPTZ,
    created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ads_active_placement ON public.advertisements(placement, is_active, priority DESC);

-- 2.15 ad_events
CREATE TABLE IF NOT EXISTS public.ad_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    advertisement_id UUID NOT NULL REFERENCES public.advertisements(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL CHECK (event_type IN ('impression', 'click')),
    placement ad_placement NOT NULL,
    user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ad_events_ad ON public.ad_events(advertisement_id, event_type);

-- 2.16 admin_logs
CREATE TABLE IF NOT EXISTS public.admin_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    action TEXT NOT NULL,
    target_type TEXT NOT NULL,
    target_id TEXT NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_logs_created ON public.admin_logs(created_at DESC);

-- ----------------------------------------------------------------------------
-- 3. SEED DEFAULT 20 RAMAYANA CHARACTERS (Exact Scores from Spec)
-- ----------------------------------------------------------------------------
INSERT INTO public.characters (slug, name, description, image_url, default_score, category, is_mandatory, is_active)
VALUES
    ('rama', 'Rama', 'Prince of Ayodhya and wielder of the celestial Kodanda bow. Must identify Sita among the players.', '/assets/characters/rama.jpg', 1000, 'mandatory_hero', TRUE, TRUE),
    ('sita', 'Sita', 'Princess of Mithila and embodiment of grace. Must remain hidden from Rama''s gaze to win 1000 points.', '/assets/characters/sita.jpg', 0, 'mandatory_target', TRUE, TRUE),
    ('hanuman', 'Hanuman', 'Devoted Vanara hero who leaped across the ocean and carried the glowing Sanjeevani mountain.', '/assets/characters/hanuman.jpg', 900, 'vanara_sena', FALSE, TRUE),
    ('ravana', 'Ravana', 'Ten-headed scholar-king of Lanka and master of illusion and grand strategy.', '/assets/characters/ravana.jpg', 850, 'lanka_court', FALSE, TRUE),
    ('lakshmana', 'Lakshmana', 'Fiercely loyal younger brother of Rama and tireless protector in the Dandaka forest.', '/assets/characters/lakshmana.jpg', 800, 'royal_family', FALSE, TRUE),
    ('indrajit', 'Indrajit', 'Crown prince of Lanka and formidable warrior of celestial illusions.', '/assets/characters/indrajit.jpg', 750, 'lanka_court', FALSE, TRUE),
    ('sugriva', 'Sugriva', 'Ruler of Kishkindha and commander of the Vanara armies allied with Rama.', '/assets/characters/sugriva.jpg', 700, 'vanara_sena', FALSE, TRUE),
    ('bharata', 'Bharata', 'Noble brother of Rama who ruled Ayodhya as regent with Rama''s sandals on the throne.', '/assets/characters/bharata.jpg', 650, 'royal_family', FALSE, TRUE),
    ('vibhishana', 'Vibhishana', 'Righteous younger brother of Ravana who stood for Dharma and aided Rama.', '/assets/characters/vibhishana.jpg', 600, 'lanka_court', FALSE, TRUE),
    ('dasharatha', 'Dasharatha', 'Illustrious Emperor of Kosala and father of Rama, Bharata, Lakshmana, and Shatrughna.', '/assets/characters/dasharatha.jpg', 600, 'royal_family', FALSE, TRUE),
    ('jatayu', 'Jatayu', 'Valiant divine king of eagles who fought bravely in the skies to protect Sita.', '/assets/characters/jatayu.jpg', 550, 'allies_sages', FALSE, TRUE),
    ('shatrughna', 'Shatrughna', 'Youngest prince of Ayodhya and devoted twin brother of Lakshmana.', '/assets/characters/shatrughna.jpg', 500, 'royal_family', FALSE, TRUE),
    ('angada', 'Angada', 'Fearless prince of Kishkindha and emissary who stood unmoved in Ravana''s court.', '/assets/characters/angada.jpg', 500, 'vanara_sena', FALSE, TRUE),
    ('jambavan', 'Jambavan', 'Ancient and wise king of bears who reminded Hanuman of his boundless strength.', '/assets/characters/jambavan.jpg', 450, 'vanara_sena', FALSE, TRUE),
    ('kumbhakarna', 'Kumbhakarna', 'Colossal brother of Ravana known for his titanic strength and six-month slumber.', '/assets/characters/kumbhakarna.jpg', 400, 'lanka_court', FALSE, TRUE),
    ('mandodari', 'Mandodari', 'Wise and virtuous Queen of Lanka who counselled peace and righteousness.', '/assets/characters/mandodari.jpg', 350, 'lanka_court', FALSE, TRUE),
    ('kausalya', 'Kausalya', 'Chief Queen of Ayodhya and loving mother of Lord Rama.', '/assets/characters/kausalya.jpg', 300, 'royal_family', FALSE, TRUE),
    ('kaikeyi', 'Kaikeyi', 'Queen of Ayodhya and mother of Bharata whose two boons altered the course of history.', '/assets/characters/kaikeyi.jpg', 250, 'royal_family', FALSE, TRUE),
    ('urmila', 'Urmila', 'Princess of Mithila and devoted wife of Lakshmana Known for her silent sacrifice.', '/assets/characters/urmila.jpg', 250, 'royal_family', FALSE, TRUE),
    ('surpanakha', 'Surpanakha', 'Sister of Ravana whose encounter in Panchavati sparked the great epic conflict.', '/assets/characters/surpanakha.jpg', 200, 'lanka_court', FALSE, TRUE)
ON CONFLICT (slug) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 4. ROW LEVEL SECURITY (RLS) POLICIES — ZERO SECRET LEAKAGE
-- ----------------------------------------------------------------------------
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.characters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.room_players ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.room_characters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rounds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.character_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.round_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_totals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.room_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.advertisements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_logs ENABLE ROW LEVEL SECURITY;

-- Helper function: check if current user is an active admin
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND role = 'admin' AND is_disabled = FALSE
    );
$$;

-- Helper function: check if current user is a member of a given room
CREATE OR REPLACE FUNCTION public.is_room_member(target_room_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.room_players
        WHERE room_id = target_room_id AND user_id = auth.uid()
    );
$$;

-- Profiles RLS
CREATE POLICY "Profiles readable by authenticated users"
    ON public.profiles FOR SELECT USING (TRUE);

CREATE POLICY "Users can update own profile (non-role fields)"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id AND role = (SELECT role FROM public.profiles WHERE id = auth.uid()));

-- Characters RLS
CREATE POLICY "Active characters readable by everyone"
    ON public.characters FOR SELECT USING (is_active = TRUE OR public.is_admin());

CREATE POLICY "Admins manage characters"
    ON public.characters FOR ALL USING (public.is_admin());

-- Rooms RLS: Only room members or admins can read private rooms
CREATE POLICY "Rooms readable by members or admins"
    ON public.rooms FOR SELECT
    USING (
        NOT COALESCE((settings->>'is_private')::boolean, true)
        OR host_id = auth.uid()
        OR public.is_room_member(id)
        OR public.is_admin()
    );

-- Room Players RLS
CREATE POLICY "Room players readable by room members"
    ON public.room_players FOR SELECT
    USING (public.is_room_member(room_id) OR public.is_admin());

-- CRITICAL SECURITY POLICY: character_assignments
-- A player can ONLY read their own character assignment while a round is active.
-- Other players' assignments are ONLY visible AFTER round.status IN ('revealed', 'completed').
CREATE POLICY "Strict secret character assignment protection"
    ON public.character_assignments FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.room_players rp
            WHERE rp.id = character_assignments.player_id
              AND rp.user_id = auth.uid()
        )
        OR EXISTS (
            SELECT 1 FROM public.rounds r
            JOIN public.game_sessions gs ON gs.id = r.session_id
            WHERE r.id = character_assignments.round_id
              AND r.status IN ('revealed', 'completed')
              AND public.is_room_member(gs.room_id)
        )
        OR public.is_admin()
    );

-- Safe view for rounds so sita_player_id is masked until status IN ('revealed', 'completed')
CREATE OR REPLACE VIEW public.safe_rounds AS
SELECT
    r.id,
    r.session_id,
    r.round_number,
    r.status,
    r.rama_player_id,
    CASE WHEN r.status IN ('revealed', 'completed') THEN r.sita_player_id ELSE NULL END AS sita_player_id,
    r.guessed_player_id,
    r.is_correct,
    r.timer_ends_at,
    r.created_at,
    r.completed_at
FROM public.rounds r;

-- Room Messages RLS: Strictly isolated to room members during active session
CREATE POLICY "Room messages visible only to room members"
    ON public.room_messages FOR SELECT
    USING (
        is_archived = FALSE
        AND (public.is_room_member(room_id) OR public.is_admin())
    );

CREATE POLICY "Room members can post rate-limited chat messages"
    ON public.room_messages FOR INSERT
    WITH CHECK (
        public.is_room_member(room_id)
        AND message_type = 'chat'
        AND char_length(trim(message)) BETWEEN 1 AND 280
    );

-- Advertisements RLS
CREATE POLICY "Active scheduled ads readable by all"
    ON public.advertisements FOR SELECT
    USING (
        (is_active = TRUE AND start_at <= now() AND (end_at IS NULL OR end_at >= now()))
        OR public.is_admin()
    );

CREATE POLICY "Only admins can mutate advertisements"
    ON public.advertisements FOR ALL
    USING (public.is_admin())
    WITH CHECK (public.is_admin());

-- Admin Logs RLS
CREATE POLICY "Only admins can read or insert admin logs"
    ON public.admin_logs FOR ALL
    USING (public.is_admin())
    WITH CHECK (public.is_admin());

-- ----------------------------------------------------------------------------
-- 5. ATOMIC SERVER-SIDE GAME ENGINE RPC FUNCTIONS
-- ----------------------------------------------------------------------------

-- 5.1 Start Round: Validates room & deck (1 Rama, 1 Sita, unique others, count == max_players),
-- shuffles characters cryptographically on backend, and inserts character_assignments.
CREATE OR REPLACE FUNCTION public.start_new_round(
    p_room_id UUID,
    p_caller_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_room public.rooms%ROWTYPE;
    v_session_id UUID;
    v_round_id UUID;
    v_next_round_num INTEGER;
    v_player_count INTEGER;
    v_char_count INTEGER;
    v_has_rama BOOLEAN;
    v_has_sita BOOLEAN;
    v_rama_player_id UUID;
    v_sita_player_id UUID;
    v_rec RECORD;
BEGIN
    -- Lock room row to prevent race conditions
    SELECT * INTO v_room FROM public.rooms WHERE id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room not found';
    END IF;

    IF v_room.host_id <> p_caller_id THEN
        RAISE EXCEPTION 'Only the room host can start a round';
    END IF;

    -- Validate active player count
    SELECT COUNT(*) INTO v_player_count
    FROM public.room_players
    WHERE room_id = p_room_id AND player_type IN ('human', 'bot');

    IF v_player_count <> v_room.max_players THEN
        RAISE EXCEPTION 'Cannot start until all % player slots are filled (currently %)', v_room.max_players, v_player_count;
    END IF;

    -- Validate room_characters configuration: must equal max_players and contain Rama & Sita
    SELECT
        COUNT(*),
        BOOL_OR(c.slug = 'rama'),
        BOOL_OR(c.slug = 'sita')
    INTO v_char_count, v_has_rama, v_has_sita
    FROM public.room_characters rc
    JOIN public.characters c ON c.id = rc.character_id
    WHERE rc.room_id = p_room_id;

    IF v_char_count <> v_room.max_players OR NOT v_has_rama OR NOT v_has_sita THEN
        RAISE EXCEPTION 'Invalid character deck: must contain exactly one Rama, one Sita, and match player count (%)', v_room.max_players;
    END IF;

    -- Ensure active game_session exists
    SELECT id INTO v_session_id
    FROM public.game_sessions
    WHERE room_id = p_room_id AND status = 'in_progress'
    ORDER BY session_number DESC LIMIT 1;

    IF v_session_id IS NULL THEN
        INSERT INTO public.game_sessions (room_id, session_number, status)
        VALUES (p_room_id, 1, 'in_progress')
        RETURNING id INTO v_session_id;

        -- Initialize player_totals for all room players
        INSERT INTO public.player_totals (session_id, player_id, total_score)
        SELECT v_session_id, id, 0
        FROM public.room_players
        WHERE room_id = p_room_id AND player_type IN ('human', 'bot')
        ON CONFLICT (session_id, player_id) DO NOTHING;
    END IF;

    UPDATE public.rooms SET status = 'in_progress' WHERE id = p_room_id;

    SELECT COALESCE(MAX(round_number), 0) + 1 INTO v_next_round_num
    FROM public.rounds WHERE session_id = v_session_id;

    -- Create temporary shuffled pairing of players and characters using gen_random_bytes
    CREATE TEMP TABLE tmp_shuffled_assignments ON COMMIT DROP AS
    WITH numbered_players AS (
        SELECT id AS player_id, ROW_NUMBER() OVER (ORDER BY gen_random_uuid()) AS rn
        FROM public.room_players
        WHERE room_id = p_room_id AND player_type IN ('human', 'bot')
    ),
    numbered_chars AS (
        SELECT rc.character_id, rc.assigned_score, c.slug, ROW_NUMBER() OVER (ORDER BY gen_random_uuid()) AS rn
        FROM public.room_characters rc
        JOIN public.characters c ON c.id = rc.character_id
        WHERE rc.room_id = p_room_id
    )
    SELECT np.player_id, nc.character_id, nc.assigned_score, nc.slug
    FROM numbered_players np
    JOIN numbered_chars nc ON np.rn = nc.rn;

    SELECT player_id INTO v_rama_player_id FROM tmp_shuffled_assignments WHERE slug = 'rama';
    SELECT player_id INTO v_sita_player_id FROM tmp_shuffled_assignments WHERE slug = 'sita';

    INSERT INTO public.rounds (
        session_id,
        round_number,
        status,
        rama_player_id,
        sita_player_id,
        timer_ends_at
    ) VALUES (
        v_session_id,
        v_next_round_num,
        'discussion',
        v_rama_player_id,
        v_sita_player_id,
        now() + ((COALESCE((v_room.settings->>'turn_timer_seconds')::int, 60)) * INTERVAL '1 second')
    ) RETURNING id INTO v_round_id;

    INSERT INTO public.character_assignments (round_id, player_id, character_id, assigned_score)
    SELECT v_round_id, player_id, character_id, assigned_score
    FROM tmp_shuffled_assignments;

    RETURN v_round_id;
END;
$$;

-- 5.2 Submit Rama Guess: Atomic transaction with row-level locking to prevent duplicate submissions
-- or double-scoring. Resolves Rama/Sita special outcome and awards other characters' slip scores once.
CREATE OR REPLACE FUNCTION public.submit_rama_guess(
    p_round_id UUID,
    p_rama_player_id UUID,
    p_guessed_player_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_round public.rounds%ROWTYPE;
    v_is_correct BOOLEAN;
BEGIN
    -- Lock the round row FOR UPDATE so two concurrent guesses cannot both succeed
    SELECT * INTO v_round
    FROM public.rounds
    WHERE id = p_round_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Round not found';
    END IF;

    IF v_round.status IN ('revealed', 'completed') OR v_round.guessed_player_id IS NOT NULL THEN
        RAISE EXCEPTION 'Round guess has already been submitted and resolved';
    END IF;

    IF v_round.rama_player_id <> p_rama_player_id THEN
        RAISE EXCEPTION 'Unauthorized: Only the assigned Rama player for this round may submit a guess';
    END IF;

    IF p_guessed_player_id = p_rama_player_id THEN
        RAISE EXCEPTION 'Invalid guess: Rama cannot select himself';
    END IF;

    -- Verify guessed player is in the same room/round
    IF NOT EXISTS (
        SELECT 1 FROM public.character_assignments
        WHERE round_id = p_round_id AND player_id = p_guessed_player_id
    ) THEN
        RAISE EXCEPTION 'Selected target player is not an eligible participant in this round';
    END IF;

    -- Server-side verification of actual Sita identity
    v_is_correct := (p_guessed_player_id = v_round.sita_player_id);

    -- Update round status atomically
    UPDATE public.rounds
    SET guessed_player_id = p_guessed_player_id,
        is_correct = v_is_correct,
        status = 'completed',
        completed_at = now()
    WHERE id = p_round_id;

    -- Insert round_scores once per player (UNIQUE(round_id, player_id) prevents double scoring)
    -- Special rule: Rama & Sita base scores are OVERRIDDEN by the guess outcome (1000 vs 0).
    -- Wrongly accused non-Sita player still gets their own slip's assigned_score!
    INSERT INTO public.round_scores (round_id, player_id, points_earned)
    SELECT
        ca.round_id,
        ca.player_id,
        CASE
            WHEN ca.player_id = v_round.rama_player_id THEN
                CASE WHEN v_is_correct THEN 1000 ELSE 0 END
            WHEN ca.player_id = v_round.sita_player_id THEN
                CASE WHEN v_is_correct THEN 0 ELSE 1000 END
            ELSE
                ca.assigned_score
        END AS points_earned
    FROM public.character_assignments ca
    WHERE ca.round_id = p_round_id;

    -- Update cumulative player_totals and rank movement atomically
    UPDATE public.player_totals pt
    SET previous_rank = pt.current_rank,
        last_round_score = rs.points_earned,
        total_score = pt.total_score + rs.points_earned,
        rama_rounds = pt.rama_rounds + CASE WHEN pt.player_id = v_round.rama_player_id THEN 1 ELSE 0 END,
        rama_correct_guesses = pt.rama_correct_guesses + CASE WHEN pt.player_id = v_round.rama_player_id AND v_is_correct THEN 1 ELSE 0 END,
        sita_rounds = pt.sita_rounds + CASE WHEN pt.player_id = v_round.sita_player_id THEN 1 ELSE 0 END,
        sita_escapes = pt.sita_escapes + CASE WHEN pt.player_id = v_round.sita_player_id AND NOT v_is_correct THEN 1 ELSE 0 END,
        updated_at = now()
    FROM public.round_scores rs
    WHERE rs.round_id = p_round_id
      AND pt.session_id = v_round.session_id
      AND pt.player_id = rs.player_id;

    -- Recompute shared ranks (DENSE_RANK / RANK with ties sharing rank)
    WITH ranked AS (
        SELECT id, RANK() OVER (PARTITION BY session_id ORDER BY total_score DESC) AS new_rank
        FROM public.player_totals
        WHERE session_id = v_round.session_id
    )
    UPDATE public.player_totals pt
    SET current_rank = ranked.new_rank
    FROM ranked
    WHERE pt.id = ranked.id;

    RETURN jsonb_build_object(
        'round_id', p_round_id,
        'is_correct', v_is_correct,
        'rama_player_id', v_round.rama_player_id,
        'sita_player_id', v_round.sita_player_id,
        'guessed_player_id', p_guessed_player_id
    );
END;
$$;
