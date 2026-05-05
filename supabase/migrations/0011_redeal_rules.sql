-- Función auxiliar: el host puede (re)repartir cartas de regla a una sala
-- in_progress que se quedó sin ellas (p. ej. porque la partida se inició
-- antes de aplicar 0009, o el mazo y discard quedaron vacíos).

set search_path = public, pg_temp;

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

  v_rule_deck := public.shuffle_text(public.build_rule_deck(v_count));
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

  -- Borrar el rule_pick de la ronda actual si existía con cartas viejas
  delete from public.round_rule_picks
    where round_id in (select id from public.rounds where rounds.room_id = p_room_id);
end $$;
