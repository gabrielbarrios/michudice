-- start_game: el primer Michudice se elige al azar (antes era siempre el host).
-- Mantiene el reparto de cartas numéricas y de regla a TODOS los jugadores.

set search_path = public, pg_temp;

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

  -- mazo numérico
  v_deck := public.shuffle_deck(public.build_deck());
  v_per_player := array_length(v_deck, 1) / v_count;
  v_idx := 1;

  -- mazo de reglas
  v_rule_deck := public.shuffle_text(public.build_rule_deck(v_count));
  v_rule_idx := 1;

  -- repartir a TODOS los jugadores (no solo el host)
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

  -- Michudice inicial ALEATORIO (no necesariamente el host)
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
