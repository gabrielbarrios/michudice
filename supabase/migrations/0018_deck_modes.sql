-- Modos de mazo de cartas de regla, configurables al crear sala.
--   classic  : max(5, jugadores+1) de cada regla (default).
--   single   : 1 copia de cada tipo.
--   negative : 3 copias de cada regla + 6 de las que restan puntos
--              (subtract, sub_right, sub_left).
--   positive : 3 copias de cada regla + solo 1 de las que restan.
--   pairs    : 2 copias de cada regla.
-- Se persiste en rooms.deck_mode y se aplica en build_rule_deck.

set search_path = public, pg_temp;

-- 1. Columna en rooms ---------------------------------------------------
alter table public.rooms
  add column if not exists deck_mode text not null default 'classic';
alter table public.rooms drop constraint if exists rooms_deck_mode_check;
alter table public.rooms
  add constraint rooms_deck_mode_check
  check (deck_mode in ('classic','single','negative','positive','pairs'));

-- 2. build_rule_deck ahora acepta modo ----------------------------------
drop function if exists public.build_rule_deck(int);
drop function if exists public.build_rule_deck(int, text);
create function public.build_rule_deck(p_player_count int, p_mode text default 'classic')
returns text[]
language plpgsql immutable as $$
declare
  v_kinds text[] := array[
    'subtract','no_cancel','swap',
    'add_right','add_left','sub_right','sub_left',
    'cancel_even','cancel_odd',
    'none',
    'rotate_right','rotate_left'
  ];
  v_subtract_kinds text[] := array['subtract','sub_right','sub_left'];
  v_kind text;
  v_count int;
  v_deck text[] := '{}';
begin
  foreach v_kind in array v_kinds loop
    v_count := case
      when p_mode = 'classic'  then greatest(5, p_player_count + 1)
      when p_mode = 'single'   then 1
      when p_mode = 'negative' then case when v_kind = any(v_subtract_kinds) then 6 else 3 end
      when p_mode = 'positive' then case when v_kind = any(v_subtract_kinds) then 1 else 3 end
      when p_mode = 'pairs'    then 2
      else greatest(5, p_player_count + 1)
    end;
    if v_count > 0 then
      v_deck := v_deck || array(select v_kind from generate_series(1, v_count));
    end if;
  end loop;
  return v_deck;
end $$;

-- 3. create_room acepta deck_mode --------------------------------------
drop function if exists public.create_room(text);
drop function if exists public.create_room(text, text);
create function public.create_room(p_name text, p_deck_mode text default 'classic')
returns table(out_room_id uuid, out_room_code text, out_player_id uuid)
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_room_id uuid;
  v_code text;
  v_player_id uuid;
  v_mode text := coalesce(p_deck_mode, 'classic');
begin
  if v_uid is null then raise exception 'auth required'; end if;
  if v_mode not in ('classic','single','negative','positive','pairs') then
    raise exception 'invalid deck mode';
  end if;
  v_code := public.gen_room_code();
  insert into public.rooms(code, host_id, deck_mode) values (v_code, v_uid, v_mode)
    returning id into v_room_id;
  insert into public.players(room_id, user_id, name, seat)
    values (v_room_id, v_uid, p_name, 0) returning id into v_player_id;
  return query select v_room_id, v_code, v_player_id;
end $$;

-- 4. start_game lee deck_mode de la sala --------------------------------
drop function if exists public.start_game(uuid);
create or replace function public.start_game(p_room_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_first_player uuid;
  v_count int;
  v_deck int[];
  v_per_player int;
  v_player record;
  v_idx int;
  v_hand int[];
  v_rule_deck text[];
  v_rule_idx int;
  v_rule_hand text[];
  v_remaining text[];
begin
  select * into v_room from public.rooms where rooms.id = p_room_id for update;
  if not found then raise exception 'room not found'; end if;
  if v_room.host_id <> v_uid then raise exception 'only host can start'; end if;
  if v_room.status <> 'lobby' then raise exception 'already started'; end if;

  select count(*) into v_count from public.players where players.room_id = p_room_id;
  if v_count < 3 then raise exception 'need at least 3 players'; end if;

  v_deck := public.shuffle_deck(public.build_deck());
  v_per_player := array_length(v_deck, 1) / v_count;
  v_idx := 1;

  v_rule_deck := public.shuffle_text(public.build_rule_deck(v_count, v_room.deck_mode));
  v_rule_idx := 1;

  for v_player in
    select id from public.players where players.room_id = p_room_id order by seat asc
  loop
    v_hand := v_deck[v_idx : v_idx + v_per_player - 1];
    insert into public.player_hands(player_id, hand) values (v_player.id, v_hand)
      on conflict (player_id) do update set hand = excluded.hand;
    update public.players set hand_size = v_per_player where id = v_player.id;
    v_idx := v_idx + v_per_player;

    v_rule_hand := array(
      select v_rule_deck[i]
      from generate_series(v_rule_idx, v_rule_idx + 1) i
      where i <= array_length(v_rule_deck, 1)
    );
    insert into public.player_rule_hands(player_id, hand) values (v_player.id, v_rule_hand)
      on conflict (player_id) do update set hand = excluded.hand;
    update public.players set rule_hand_size = coalesce(array_length(v_rule_hand, 1), 0)
      where id = v_player.id;
    v_rule_idx := v_rule_idx + 2;
  end loop;

  v_remaining := array(
    select v_rule_deck[i]
    from generate_series(v_rule_idx, array_length(v_rule_deck, 1)) i
  );
  update public.rooms
    set rule_deck = coalesce(v_remaining, '{}'),
        rule_discard = '{}'
    where id = p_room_id;

  select players.id into v_first_player from public.players
    where players.room_id = p_room_id
    order by random() limit 1;

  update public.rooms set
    status = 'in_progress',
    current_round = 1,
    current_michudice = v_first_player
  where rooms.id = p_room_id;

  insert into public.rounds(room_id, round_number, michudice_player_id)
    values (p_room_id, 1, v_first_player);
end $$;

-- 5. redeal_rule_hands respeta el deck_mode ----------------------------
create or replace function public.redeal_rule_hands(p_room_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_count int;
  v_rule_deck text[];
  v_rule_idx int;
  v_player record;
  v_rule_hand text[];
  v_remaining text[];
begin
  select * into v_room from public.rooms where rooms.id = p_room_id for update;
  if not found then raise exception 'room not found'; end if;
  if v_room.host_id <> v_uid then raise exception 'only host can redeal'; end if;
  if v_room.status <> 'in_progress' then raise exception 'room not in progress'; end if;

  select count(*) into v_count from public.players where players.room_id = p_room_id;
  if v_count < 3 then raise exception 'need at least 3 players'; end if;

  v_rule_deck := public.shuffle_text(public.build_rule_deck(v_count, v_room.deck_mode));
  v_rule_idx := 1;

  for v_player in
    select id from public.players where players.room_id = p_room_id order by seat asc
  loop
    v_rule_hand := array(
      select v_rule_deck[i]
      from generate_series(v_rule_idx, v_rule_idx + 1) i
      where i <= array_length(v_rule_deck, 1)
    );
    insert into public.player_rule_hands(player_id, hand) values (v_player.id, v_rule_hand)
      on conflict (player_id) do update set hand = excluded.hand;
    update public.players set rule_hand_size = coalesce(array_length(v_rule_hand, 1), 0)
      where id = v_player.id;
    v_rule_idx := v_rule_idx + 2;
  end loop;

  v_remaining := array(
    select v_rule_deck[i]
    from generate_series(v_rule_idx, array_length(v_rule_deck, 1)) i
  );

  update public.rooms
    set rule_deck = coalesce(v_remaining, '{}'),
        rule_discard = '{}'
    where id = p_room_id;

  delete from public.round_rule_picks
    where round_id in (select id from public.rounds where rounds.room_id = p_room_id);
end $$;
