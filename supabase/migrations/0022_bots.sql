-- Soporte para bots: jugadores controlados por el servidor que llenan la mesa
-- cuando no hay suficientes humanos. Diseño:
--  * players.is_bot = true; players.user_id se vuelve nullable para que un bot
--    no necesite cuenta en auth.users.
--  * Las RPCs human (submit_pick, submit_rule_pick) siguen validando auth.uid()
--    como siempre. Para bots existen RPCs paralelas (bot_submit_pick,
--    bot_submit_rule_pick) que aceptan p_player_id y validan is_bot = true.
--    Se invocan solo desde server actions con SERVICE_ROLE_KEY.
--  * add_bot inserta un player con is_bot=true; el server action que la llama
--    se encarga de verificar que el caller sea el host humano.

set search_path = public, pg_temp;

-- 1. Schema --------------------------------------------------------------
alter table public.players alter column user_id drop not null;
alter table public.players add column if not exists is_bot boolean not null default false;

-- 2. add_bot(p_room_id, p_name) -----------------------------------------
-- Inserta un player con is_bot = true, seat consecutivo. Solo permite la
-- inserción en estado 'lobby' y respeta max_players.
create or replace function public.add_bot(p_room_id uuid, p_name text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_room public.rooms%rowtype;
  v_count int;
  v_seat int;
  v_id uuid;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'invalid bot name';
  end if;

  select * into v_room from public.rooms where rooms.id = p_room_id for update;
  if not found then raise exception 'room not found'; end if;
  if v_room.status <> 'lobby' then raise exception 'cannot add bots after start'; end if;

  select count(*) into v_count from public.players where room_id = p_room_id;
  if v_count >= v_room.max_players then raise exception 'room full'; end if;
  v_seat := v_count;

  insert into public.players(room_id, user_id, name, seat, is_bot)
    values (p_room_id, null, p_name, v_seat, true)
    returning id into v_id;

  return v_id;
end $$;

-- 3. bot_submit_pick(p_player_id, p_round_id, p_card_value) -------------
-- Espejo de submit_pick (migración 0004) pero sin auth.uid(): valida que
-- players.is_bot = true y que el player pertenece a la room del round.
create or replace function public.bot_submit_pick(
  p_player_id uuid,
  p_round_id uuid,
  p_card_value int
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_round public.rounds%rowtype;
  v_player public.players%rowtype;
  v_hand int[];
  v_existing_pick int;
  v_pos int;
begin
  if p_card_value < 3 or p_card_value > 9 then raise exception 'invalid card'; end if;
  select * into v_round from public.rounds where rounds.id = p_round_id;
  if not found then raise exception 'round not found'; end if;
  if v_round.status <> 'picking' then raise exception 'round closed'; end if;

  select * into v_player from public.players where id = p_player_id;
  if not found then raise exception 'player not found'; end if;
  if not v_player.is_bot then raise exception 'not a bot'; end if;
  if v_player.room_id <> v_round.room_id then raise exception 'bot not in room'; end if;

  select hand into v_hand from public.player_hands where player_id = p_player_id for update;
  if v_hand is null then raise exception 'no hand for bot'; end if;

  select card_value into v_existing_pick from public.round_picks
    where round_id = p_round_id and player_id = p_player_id;
  if found then
    v_hand := array_append(v_hand, v_existing_pick);
  end if;

  v_pos := array_position(v_hand, p_card_value);
  if v_pos is null then raise exception 'card not in hand'; end if;
  v_hand := v_hand[1:v_pos-1] || v_hand[v_pos+1:array_length(v_hand,1)];

  update public.player_hands set hand = v_hand where player_id = p_player_id;
  update public.players set hand_size = coalesce(array_length(v_hand,1), 0)
    where id = p_player_id;

  insert into public.round_picks(round_id, player_id, card_value)
    values (p_round_id, p_player_id, p_card_value)
    on conflict (round_id, player_id)
      do update set card_value = excluded.card_value, picked_at = now();
end $$;

-- 4. bot_submit_rule_pick(p_player_id, p_round_id, p_rule_kind) ---------
-- Espejo de submit_rule_pick (última versión en 0021) pero sin auth.uid().
-- Valida is_bot = true Y player_id = michudice_player_id. Acepta todas las
-- reglas del CHECK actual. Cuando se agrega un nuevo rule_kind, este bloque
-- también debe actualizarse (ver CLAUDE.md "Cómo agregar una nueva carta
-- de regla").
create or replace function public.bot_submit_rule_pick(
  p_player_id uuid,
  p_round_id uuid,
  p_rule_kind text
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_round public.rounds%rowtype;
  v_player public.players%rowtype;
  v_hand text[];
  v_existing text;
  v_pos int;
begin
  if p_rule_kind not in (
    'subtract','no_cancel','swap',
    'add_right','add_left','sub_right','sub_left',
    'cancel_even','cancel_odd',
    'none',
    'rotate_right','rotate_left',
    'double_low',
    'cancel_random'
  ) then
    raise exception 'invalid rule';
  end if;

  select * into v_round from public.rounds where rounds.id = p_round_id;
  if not found then raise exception 'round not found'; end if;
  if v_round.status <> 'picking' then raise exception 'round closed'; end if;

  select * into v_player from public.players where id = p_player_id;
  if not found then raise exception 'player not found'; end if;
  if not v_player.is_bot then raise exception 'not a bot'; end if;
  if v_player.room_id <> v_round.room_id then raise exception 'bot not in room'; end if;
  if p_player_id <> v_round.michudice_player_id then
    raise exception 'only michudice can pick rule';
  end if;

  select hand into v_hand from public.player_rule_hands where player_id = p_player_id for update;
  if v_hand is null then raise exception 'no rule hand'; end if;

  select rule_kind into v_existing from public.round_rule_picks where round_id = p_round_id;
  if found then
    v_hand := array_append(v_hand, v_existing);
  end if;

  v_pos := array_position(v_hand, p_rule_kind);
  if v_pos is null then raise exception 'rule not in hand'; end if;
  v_hand := v_hand[1:v_pos-1] || v_hand[v_pos+1:array_length(v_hand,1)];

  update public.player_rule_hands set hand = v_hand where player_id = p_player_id;
  update public.players set rule_hand_size = coalesce(array_length(v_hand,1), 0)
    where id = p_player_id;

  insert into public.round_rule_picks(round_id, player_id, rule_kind)
    values (p_round_id, p_player_id, p_rule_kind)
    on conflict (round_id) do update
      set player_id = excluded.player_id,
          rule_kind = excluded.rule_kind,
          picked_at = now();
end $$;
