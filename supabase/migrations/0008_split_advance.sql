-- Separa "revelar" de "avanzar":
--   * reveal_round: aplica puntajes, registra resultado, deja la ronda en 'scored'.
--   * advance_round: el cliente lo dispara tras la animación de 5s para crear
--     la siguiente ronda (o terminar la partida).
-- Ambas son idempotentes y seguras frente a llamadas concurrentes.

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
begin
  select * into v_round from rounds where rounds.id = p_round_id for update;
  if not found then raise exception 'round not found'; end if;
  if v_round.status <> 'picking' then return false; end if;

  select * into v_room from rooms where rooms.id = v_round.room_id for update;

  select count(*) into v_player_count from players where players.room_id = v_room.id;
  select count(*) into v_pick_count from round_picks where round_id = p_round_id;
  if v_pick_count < v_player_count then return false; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'player_id', player_id, 'card_value', card_value
  )), '[]'::jsonb) into v_picks
  from round_picks where round_id = p_round_id;

  v_result := score_picks(v_picks);
  v_deltas := v_result -> 'deltas';

  update rounds set status = 'revealed', revealed_at = now() where id = p_round_id;

  for v_delta in
    select * from jsonb_to_recordset(v_deltas) as x(player_id uuid, points int)
  loop
    update players set score = score + v_delta.points where id = v_delta.player_id;
  end loop;

  update players set michudice_count = michudice_count + 1
    where id = v_round.michudice_player_id;

  insert into round_results(round_id, payload) values (p_round_id, v_result);
  update rounds set status = 'scored', scored_at = now() where id = p_round_id;

  return true;
end $$;

create or replace function advance_round(p_round_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_round rounds%rowtype;
  v_room rooms%rowtype;
  v_michudice_seat int;
  v_next_michudice uuid;
  v_next_round int;
  v_any_empty boolean;
  v_existing int;
begin
  select * into v_round from rounds where rounds.id = p_round_id for update;
  if not found then return false; end if;
  if v_round.status <> 'scored' then return false; end if;

  select * into v_room from rooms where rooms.id = v_round.room_id for update;
  if v_room.status = 'finished' then return false; end if;
  -- Ya alguien avanzó esta ronda
  if v_room.current_round > v_round.round_number then return false; end if;

  -- ¿Termina la partida?
  select exists(
    select 1 from players where players.room_id = v_room.id and hand_size = 0
  ) into v_any_empty;

  if v_any_empty
    or not exists (
      select 1 from players
      where players.room_id = v_room.id and michudice_count < v_room.michudice_target
    )
  then
    update rooms
      set status = 'finished', finished_at = now(), current_michudice = null
      where id = v_room.id;
    return true;
  end if;

  -- Siguiente Michudice por rotación
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

  v_next_round := v_round.round_number + 1;

  -- Idempotente: si otra llamada concurrente ya creó la siguiente ronda, salimos
  select count(*) into v_existing from rounds
    where rounds.room_id = v_room.id and rounds.round_number = v_next_round;
  if v_existing > 0 then return false; end if;

  update rooms set current_round = v_next_round, current_michudice = v_next_michudice
    where id = v_room.id;
  insert into rounds(room_id, round_number, michudice_player_id)
    values (v_room.id, v_next_round, v_next_michudice)
    on conflict (room_id, round_number) do nothing;

  return true;
end $$;
