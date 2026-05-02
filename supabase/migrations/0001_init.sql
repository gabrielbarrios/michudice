-- Michudice schema
-- Anti-cheat strategy:
--   * Card picks live in `round_picks` and are NEVER selectable while round.status='picking'
--     (RLS forbids SELECT until status='revealed'). Players insert their own pick only.
--   * Scoring runs server-side via the `reveal_round` SQL function with SECURITY DEFINER.
--   * Joining/creating rooms goes through SECURITY DEFINER functions to validate state.

create extension if not exists "pgcrypto";

-- Enums --------------------------------------------------------------------
do $$ begin
  create type room_status as enum ('lobby', 'in_progress', 'finished');
exception when duplicate_object then null; end $$;

do $$ begin
  create type round_status as enum ('picking', 'revealed', 'scored');
exception when duplicate_object then null; end $$;

-- Tables -------------------------------------------------------------------
create table if not exists rooms (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  status room_status not null default 'lobby',
  host_id uuid not null references auth.users(id) on delete cascade,
  max_players int not null default 9 check (max_players between 3 and 9),
  michudice_target int not null default 2,            -- veces que cada jugador debe ser michudice
  current_round int not null default 0,
  current_michudice uuid,                              -- players.id
  created_at timestamptz not null default now(),
  finished_at timestamptz
);

create index if not exists rooms_status_idx on rooms(status);

create table if not exists players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  seat int not null,                                   -- 0..max_players-1, define orden de rotación
  score int not null default 0,
  michudice_count int not null default 0,
  joined_at timestamptz not null default now(),
  unique (room_id, user_id),
  unique (room_id, seat)
);

create index if not exists players_room_idx on players(room_id);

create table if not exists rounds (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references rooms(id) on delete cascade,
  round_number int not null,
  michudice_player_id uuid not null references players(id),
  status round_status not null default 'picking',
  revealed_at timestamptz,
  scored_at timestamptz,
  unique (room_id, round_number)
);

create index if not exists rounds_room_idx on rounds(room_id);

create table if not exists round_picks (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references rounds(id) on delete cascade,
  player_id uuid not null references players(id) on delete cascade,
  card_value int not null check (card_value between 3 and 9),
  picked_at timestamptz not null default now(),
  unique (round_id, player_id)
);

create index if not exists round_picks_round_idx on round_picks(round_id);

create table if not exists round_results (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references rounds(id) on delete cascade unique,
  payload jsonb not null,                              -- detalle: cancelaciones, escaleras, deltas
  created_at timestamptz not null default now()
);

-- Helpers ------------------------------------------------------------------
create or replace function gen_room_code() returns text
language plpgsql as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  candidate text;
begin
  loop
    candidate := '';
    for i in 1..6 loop
      candidate := candidate || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from rooms where code = candidate);
  end loop;
  return candidate;
end $$;

-- Mutations (SECURITY DEFINER) --------------------------------------------
create or replace function create_room(p_name text)
returns table(out_room_id uuid, out_room_code text, out_player_id uuid)
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_room_id uuid;
  v_code text;
  v_player_id uuid;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  v_code := gen_room_code();
  insert into rooms(code, host_id) values (v_code, v_uid) returning id into v_room_id;
  insert into players(room_id, user_id, name, seat)
    values (v_room_id, v_uid, p_name, 0) returning id into v_player_id;
  return query select v_room_id, v_code, v_player_id;
end $$;

create or replace function join_room(p_code text, p_name text)
returns table(out_room_id uuid, out_player_id uuid)
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_room rooms%rowtype;
  v_seat int;
  v_player_id uuid;
  v_count int;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  select * into v_room from rooms where rooms.code = upper(p_code);
  if not found then raise exception 'room not found'; end if;
  if v_room.status <> 'lobby' then raise exception 'room not joinable'; end if;

  -- ya estoy dentro?
  select players.id into v_player_id
    from players
    where players.room_id = v_room.id and players.user_id = v_uid;
  if found then return query select v_room.id, v_player_id; return; end if;

  select count(*) into v_count from players where players.room_id = v_room.id;
  if v_count >= v_room.max_players then raise exception 'room full'; end if;

  v_seat := v_count;
  insert into players(room_id, user_id, name, seat)
    values (v_room.id, v_uid, p_name, v_seat) returning id into v_player_id;
  return query select v_room.id, v_player_id;
end $$;

create or replace function start_game(p_room_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_room rooms%rowtype;
  v_first_player uuid;
  v_count int;
begin
  select * into v_room from rooms where rooms.id = p_room_id for update;
  if not found then raise exception 'room not found'; end if;
  if v_room.host_id <> v_uid then raise exception 'only host can start'; end if;
  if v_room.status <> 'lobby' then raise exception 'already started'; end if;

  select count(*) into v_count from players where players.room_id = p_room_id;
  if v_count < 3 then raise exception 'need at least 3 players'; end if;

  select players.id into v_first_player from players
    where players.room_id = p_room_id order by players.seat asc limit 1;

  update rooms set
    status = 'in_progress',
    current_round = 1,
    current_michudice = v_first_player
  where rooms.id = p_room_id;

  insert into rounds(room_id, round_number, michudice_player_id)
    values (p_room_id, 1, v_first_player);
end $$;

create or replace function submit_pick(p_round_id uuid, p_card_value int)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_round rounds%rowtype;
  v_player_id uuid;
begin
  if p_card_value < 3 or p_card_value > 9 then raise exception 'invalid card'; end if;
  select * into v_round from rounds where id = p_round_id;
  if not found then raise exception 'round not found'; end if;
  if v_round.status <> 'picking' then raise exception 'round closed'; end if;

  select p.id into v_player_id from players p
    where p.room_id = v_round.room_id and p.user_id = v_uid;
  if v_player_id is null then raise exception 'not in room'; end if;

  insert into round_picks as rp (round_id, player_id, card_value)
    values (p_round_id, v_player_id, p_card_value)
    on conflict (round_id, player_id)
      do update set card_value = excluded.card_value, picked_at = now();
end $$;

-- Reveal & score: server-side, anti-cheat core.
-- Returns true si la ronda se acaba de revelar (todos eligieron).
create or replace function reveal_round(p_round_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_round rounds%rowtype;
  v_room rooms%rowtype;
  v_player_count int;
  v_pick_count int;
  v_picks jsonb;
  v_result jsonb;
  v_deltas jsonb;
  v_delta record;
  v_next_round int;
  v_next_michudice uuid;
  v_seat_count int;
  v_michudice_seat int;
  v_finished boolean := false;
begin
  select * into v_round from rounds where id = p_round_id for update;
  if not found then raise exception 'round not found'; end if;
  if v_round.status <> 'picking' then return false; end if;

  select * into v_room from rooms where id = v_round.room_id for update;

  select count(*) into v_player_count from players where room_id = v_room.id;
  select count(*) into v_pick_count from round_picks where round_id = p_round_id;
  if v_pick_count < v_player_count then return false; end if;

  -- Recolectar picks (player_id, card_value)
  select coalesce(jsonb_agg(jsonb_build_object(
    'player_id', player_id,
    'card_value', card_value
  )), '[]'::jsonb) into v_picks
  from round_picks where round_id = p_round_id;

  -- Calcular puntaje en SQL (mismo algoritmo que lib/game.ts)
  v_result := score_picks(v_picks);
  v_deltas := v_result -> 'deltas';

  update rounds set status = 'revealed', revealed_at = now() where id = p_round_id;

  -- Aplicar deltas a players
  for v_delta in select * from jsonb_to_recordset(v_deltas)
                 as x(player_id uuid, points int)
  loop
    update players set score = score + v_delta.points where id = v_delta.player_id;
  end loop;

  -- Incrementar contador de michudice
  update players set michudice_count = michudice_count + 1
    where id = v_round.michudice_player_id;

  insert into round_results(round_id, payload) values (p_round_id, v_result);
  update rounds set status = 'scored', scored_at = now() where id = p_round_id;

  -- Avanzar ronda o terminar partida
  select count(*) into v_seat_count from players where room_id = v_room.id;
  select seat into v_michudice_seat from players where id = v_round.michudice_player_id;

  -- Si todos llegaron al target, fin
  if not exists (
    select 1 from players where room_id = v_room.id and michudice_count < v_room.michudice_target
  ) then
    update rooms set status = 'finished', finished_at = now(), current_michudice = null
      where id = v_room.id;
    return true;
  end if;

  -- Buscar siguiente jugador (rotación por seat) que aún no llegue al target
  select id into v_next_michudice from players
    where room_id = v_room.id and michudice_count < v_room.michudice_target
      and seat > v_michudice_seat
    order by seat asc limit 1;
  if v_next_michudice is null then
    select id into v_next_michudice from players
      where room_id = v_room.id and michudice_count < v_room.michudice_target
      order by seat asc limit 1;
  end if;

  v_next_round := v_room.current_round + 1;
  update rooms set current_round = v_next_round, current_michudice = v_next_michudice
    where id = v_room.id;
  insert into rounds(room_id, round_number, michudice_player_id)
    values (v_room.id, v_next_round, v_next_michudice);

  return true;
end $$;

-- Scoring puro (espejo de lib/game.ts). Importante: NO usar slicing
-- v_unique_values[i:j] porque Postgres preserva la cota inferior y
-- v_run[1] devolvería NULL → bug donde nadie quedaba marcado en escalera
-- y todos sumaban. Construimos el run con array_append explícito.
create or replace function score_picks(p_picks jsonb)
returns jsonb
language plpgsql immutable as $$
declare
  v_canceled int[] := '{}';
  v_unique_values int[] := '{}';
  v_unique_picks jsonb := '[]'::jsonb;
  v_ladders jsonb := '[]'::jsonb;
  v_deltas jsonb := '[]'::jsonb;
  v_value int;
  v_count int;
  v_n int;
  v_i int;
  v_j int;
  v_idx int;
  v_run_cards int[];
  v_run_sum int;
  v_lowest_card int;
  v_lowest_owner uuid;
  v_pick record;
begin
  for v_value in 3..9 loop
    select count(*) into v_count
      from jsonb_array_elements(p_picks) e
      where (e->>'card_value')::int = v_value;
    if v_count = 1 then
      v_unique_values := array_append(v_unique_values, v_value);
    elsif v_count > 1 then
      v_canceled := array_append(v_canceled, v_value);
    end if;
  end loop;

  for v_pick in
    select (e->>'player_id')::uuid as player_id, (e->>'card_value')::int as card_value
      from jsonb_array_elements(p_picks) e
  loop
    if v_pick.card_value = any(v_unique_values) then
      v_unique_picks := v_unique_picks || jsonb_build_object(
        'player_id', v_pick.player_id, 'card_value', v_pick.card_value
      );
    end if;
  end loop;

  v_n := coalesce(array_length(v_unique_values, 1), 0);
  v_i := 1;
  while v_i <= v_n loop
    v_j := v_i;
    while v_j < v_n and v_unique_values[v_j + 1] = v_unique_values[v_j] + 1 loop
      v_j := v_j + 1;
    end loop;

    if (v_j - v_i + 1) >= 3 then
      v_run_cards := '{}';
      for v_idx in v_i..v_j loop
        v_run_cards := array_append(v_run_cards, v_unique_values[v_idx]);
      end loop;

      v_run_sum := (select sum(x) from unnest(v_run_cards) x);
      v_lowest_card := v_run_cards[1];

      select (e->>'player_id')::uuid into v_lowest_owner
        from jsonb_array_elements(v_unique_picks) e
        where (e->>'card_value')::int = v_lowest_card limit 1;

      v_ladders := v_ladders || jsonb_build_object(
        'cards', to_jsonb(v_run_cards),
        'sum', v_run_sum,
        'winner_id', v_lowest_owner
      );

      v_i := v_j + 1;
    else
      v_i := v_i + 1;
    end if;
  end loop;

  -- Cada carta única suma SIEMPRE para su dueño; bono de escalera adicional
  -- para el dueño de la carta más baja.
  for v_pick in
    select (e->>'player_id')::uuid as player_id, (e->>'card_value')::int as card_value
      from jsonb_array_elements(v_unique_picks) e
  loop
    v_deltas := v_deltas || jsonb_build_object(
      'player_id', v_pick.player_id, 'points', v_pick.card_value, 'reason', 'unique'
    );
  end loop;
  for v_pick in
    select (e->>'winner_id')::uuid as player_id, (e->>'sum')::int as points
      from jsonb_array_elements(v_ladders) e
  loop
    if v_pick.player_id is not null then
      v_deltas := v_deltas || jsonb_build_object(
        'player_id', v_pick.player_id, 'points', v_pick.points, 'reason', 'ladder'
      );
    end if;
  end loop;

  return jsonb_build_object(
    'canceled', to_jsonb(v_canceled),
    'unique_picks', v_unique_picks,
    'ladders', v_ladders,
    'deltas', v_deltas
  );
end $$;

-- Row Level Security -------------------------------------------------------
alter table rooms enable row level security;
alter table players enable row level security;
alter table rounds enable row level security;
alter table round_picks enable row level security;
alter table round_results enable row level security;

-- Rooms: el código es el "secreto" que da acceso a la sala (URL).
-- Cualquier usuario autenticado puede leer; sin código, no llega aquí.
drop policy if exists rooms_select on rooms;
create policy rooms_select on rooms for select to authenticated using (true);

-- Players: legibles para autenticados (necesario para mostrar el lobby
-- antes de unirse, y para que las suscripciones realtime no se bloqueen
-- por la subconsulta recursiva).
drop policy if exists players_select on players;
create policy players_select on players for select to authenticated using (true);

-- Rounds: legibles para autenticados (la información sensible son los picks)
drop policy if exists rounds_select on rounds;
create policy rounds_select on rounds for select to authenticated using (true);

-- Round picks: solo veo mi propio pick mientras la ronda está 'picking'.
-- Cuando pasa a 'revealed' o 'scored', todos los miembros pueden verlos.
drop policy if exists round_picks_select on round_picks;
create policy round_picks_select on round_picks for select to authenticated using (
  exists (
    select 1 from rounds r
    join players p on p.room_id = r.room_id
    where r.id = round_picks.round_id
      and p.user_id = auth.uid()
      and (
        r.status in ('revealed','scored')
        or round_picks.player_id = p.id
      )
  )
);

-- Round results: visibles a miembros una vez existen
drop policy if exists round_results_select on round_results;
create policy round_results_select on round_results for select to authenticated using (
  exists (
    select 1 from rounds r
    join players p on p.room_id = r.room_id
    where r.id = round_results.round_id and p.user_id = auth.uid()
  )
);

-- Inserts/updates: forzados a través de funciones SECURITY DEFINER, no hay
-- policies de INSERT/UPDATE para usuarios anónimos/autenticados directos.
-- Realtime ----------------------------------------------------------------
-- Habilitar replicación para tablas relevantes
alter publication supabase_realtime add table rooms;
alter publication supabase_realtime add table players;
alter publication supabase_realtime add table rounds;
alter publication supabase_realtime add table round_picks;
alter publication supabase_realtime add table round_results;
