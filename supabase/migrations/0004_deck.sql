-- Variante con mazo: 9×9 + 8×8 + 7×7 + 6×6 + 5×5 + 4×4 + 3×3 = 42 cartas.
-- Al iniciar la partida se baraja y se reparten floor(42/N) cartas a cada jugador.
-- Cada ronda los jugadores eligen una carta de su mano; al jugarla, se quita.
-- La partida termina cuando alguien se queda sin cartas (o todos llegaron al
-- target de michudice, lo que ocurra primero).
--
-- ANTI-CHEAT: la mano vive en player_hands con RLS estricta (solo el dueño
-- puede leerla). En players queda hand_size para que el resto vea cuántas
-- cartas le quedan a cada quien sin saber cuáles son.

-- player_hands --------------------------------------------------------------
create table if not exists player_hands (
  player_id uuid primary key references players(id) on delete cascade,
  hand int[] not null default '{}'
);

alter table player_hands enable row level security;

drop policy if exists player_hands_select_own on player_hands;
create policy player_hands_select_own on player_hands
  for select to authenticated using (
    exists (
      select 1 from players p
      where p.id = player_hands.player_id and p.user_id = auth.uid()
    )
  );

alter publication supabase_realtime add table player_hands;

-- Replicate full row para que RLS pueda evaluar updates en realtime
alter table player_hands replica identity full;

-- players: agregar contador público de cartas en mano ----------------------
alter table players
  add column if not exists hand_size int not null default 0;

-- Helpers ------------------------------------------------------------------
create or replace function build_deck() returns int[]
language sql immutable as $$
  select array_agg(v) from (
    select v from generate_series(3,9) g
    cross join lateral generate_series(1, g) i
    cross join lateral (select g as v) s
  ) t;
$$;

create or replace function shuffle_deck(p_deck int[]) returns int[]
language sql volatile as $$
  select array_agg(v order by r) from (
    select v, random() as r from unnest(p_deck) v
  ) s;
$$;

-- start_game con repartición ----------------------------------------------
drop function if exists start_game(uuid);
create or replace function start_game(p_room_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_room rooms%rowtype;
  v_first_player uuid;
  v_count int;
  v_deck int[];
  v_per_player int;
  v_player record;
  v_idx int;
  v_hand int[];
begin
  select * into v_room from rooms where rooms.id = p_room_id for update;
  if not found then raise exception 'room not found'; end if;
  if v_room.host_id <> v_uid then raise exception 'only host can start'; end if;
  if v_room.status <> 'lobby' then raise exception 'already started'; end if;

  select count(*) into v_count from players where players.room_id = p_room_id;
  if v_count < 3 then raise exception 'need at least 3 players'; end if;

  v_deck := shuffle_deck(build_deck());
  v_per_player := array_length(v_deck, 1) / v_count;

  v_idx := 1;
  for v_player in
    select id from players where players.room_id = p_room_id order by seat asc
  loop
    v_hand := v_deck[v_idx : v_idx + v_per_player - 1];
    insert into player_hands(player_id, hand) values (v_player.id, v_hand)
      on conflict (player_id) do update set hand = excluded.hand;
    update players set hand_size = v_per_player where id = v_player.id;
    v_idx := v_idx + v_per_player;
  end loop;

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

-- submit_pick valida la mano y la actualiza --------------------------------
drop function if exists submit_pick(uuid, int);
create or replace function submit_pick(p_round_id uuid, p_card_value int)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_round rounds%rowtype;
  v_player_id uuid;
  v_hand int[];
  v_existing_pick int;
  v_pos int;
begin
  if p_card_value < 3 or p_card_value > 9 then raise exception 'invalid card'; end if;
  select * into v_round from rounds where rounds.id = p_round_id;
  if not found then raise exception 'round not found'; end if;
  if v_round.status <> 'picking' then raise exception 'round closed'; end if;

  select p.id into v_player_id from players p
    where p.room_id = v_round.room_id and p.user_id = v_uid;
  if v_player_id is null then raise exception 'not in room'; end if;

  select hand into v_hand from player_hands where player_id = v_player_id for update;
  if v_hand is null then raise exception 'no hand for player'; end if;

  -- Si ya había un pick previo, devolverlo a la mano (permitir cambio antes del reveal)
  select card_value into v_existing_pick from round_picks
    where round_id = p_round_id and player_id = v_player_id;
  if found then
    v_hand := array_append(v_hand, v_existing_pick);
  end if;

  v_pos := array_position(v_hand, p_card_value);
  if v_pos is null then raise exception 'card not in hand'; end if;
  v_hand := v_hand[1:v_pos-1] || v_hand[v_pos+1:array_length(v_hand,1)];

  update player_hands set hand = v_hand where player_id = v_player_id;
  update players set hand_size = coalesce(array_length(v_hand,1), 0)
    where id = v_player_id;

  insert into round_picks(round_id, player_id, card_value)
    values (p_round_id, v_player_id, p_card_value)
    on conflict (round_id, player_id)
      do update set card_value = excluded.card_value, picked_at = now();
end $$;

-- reveal_round termina el juego cuando las manos se vacían -----------------
drop function if exists reveal_round(uuid);
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
  v_michudice_seat int;
  v_any_empty boolean;
begin
  select * into v_round from rounds where rounds.id = p_round_id for update;
  if not found then raise exception 'round not found'; end if;
  if v_round.status <> 'picking' then return false; end if;

  select * into v_room from rooms where rooms.id = v_round.room_id for update;

  select count(*) into v_player_count from players where players.room_id = v_room.id;
  select count(*) into v_pick_count from round_picks where round_id = p_round_id;
  if v_pick_count < v_player_count then return false; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'player_id', player_id,
    'card_value', card_value
  )), '[]'::jsonb) into v_picks
  from round_picks where round_id = p_round_id;

  v_result := score_picks(v_picks);
  v_deltas := v_result -> 'deltas';

  update rounds set status = 'revealed', revealed_at = now() where id = p_round_id;

  for v_delta in select * from jsonb_to_recordset(v_deltas)
                 as x(player_id uuid, points int)
  loop
    update players set score = score + v_delta.points where id = v_delta.player_id;
  end loop;

  update players set michudice_count = michudice_count + 1
    where id = v_round.michudice_player_id;

  insert into round_results(round_id, payload) values (p_round_id, v_result);
  update rounds set status = 'scored', scored_at = now() where id = p_round_id;

  -- Fin: alguien se quedó sin cartas, o todos llegaron al target de michudice
  select exists(
    select 1 from players where players.room_id = v_room.id and hand_size = 0
  ) into v_any_empty;

  if v_any_empty
    or not exists (
      select 1 from players where players.room_id = v_room.id and michudice_count < v_room.michudice_target
    )
  then
    update rooms set status = 'finished', finished_at = now(), current_michudice = null
      where id = v_room.id;
    return true;
  end if;

  select seat into v_michudice_seat from players where id = v_round.michudice_player_id;
  select id into v_next_michudice from players
    where players.room_id = v_room.id and michudice_count < v_room.michudice_target
      and seat > v_michudice_seat
    order by seat asc limit 1;
  if v_next_michudice is null then
    select id into v_next_michudice from players
      where players.room_id = v_room.id and michudice_count < v_room.michudice_target
      order by seat asc limit 1;
  end if;

  v_next_round := v_room.current_round + 1;
  update rooms set current_round = v_next_round, current_michudice = v_next_michudice
    where id = v_room.id;
  insert into rounds(room_id, round_number, michudice_player_id)
    values (v_room.id, v_next_round, v_next_michudice);

  return true;
end $$;
