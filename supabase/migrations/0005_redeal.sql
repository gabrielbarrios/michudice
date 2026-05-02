-- Función auxiliar: el host puede repartir/re-repartir cartas en cualquier
-- sala in_progress que se quedó sin manos (p. ej. porque se inició antes de
-- aplicar la migración del mazo).

create or replace function redeal_hands(p_room_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_room rooms%rowtype;
  v_count int;
  v_deck int[];
  v_per_player int;
  v_player record;
  v_idx int;
  v_hand int[];
begin
  select * into v_room from rooms where rooms.id = p_room_id for update;
  if not found then raise exception 'room not found'; end if;
  if v_room.host_id <> v_uid then raise exception 'only host can redeal'; end if;
  if v_room.status <> 'in_progress' then raise exception 'room not in progress'; end if;

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

  -- Borrar picks que pudieran haber quedado de la ronda actual
  delete from round_picks
    where round_id in (select id from rounds where rounds.room_id = p_room_id);
end $$;
