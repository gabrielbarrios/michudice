-- Patch: corrige "column reference room_id is ambiguous" renombrando los
-- OUT params de create_room/join_room (chocaban con players.room_id).
-- Las funciones afectadas se reescriben completas. start_game queda
-- también con referencias calificadas para evitar la misma trampa.

drop function if exists create_room(text);
drop function if exists join_room(text, text);

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
