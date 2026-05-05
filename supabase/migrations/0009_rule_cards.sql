-- Cartas de reglas especiales para el Michudice.
-- Mazo nuevo: 'subtract' (puntos se restan) y 'no_cancel' (iguales no se cancelan).
-- Cada jugador empieza con 2 cartas de regla; el Michudice juega 1 cada ronda
-- y se le repone otra del mazo central tras el reveal.

set search_path = public, pg_temp;

-- player_rule_hands -------------------------------------------------------
create table if not exists public.player_rule_hands (
  player_id uuid primary key references public.players(id) on delete cascade,
  hand text[] not null default '{}'
);

alter table public.player_rule_hands enable row level security;
drop policy if exists player_rule_hands_select_own on public.player_rule_hands;
create policy player_rule_hands_select_own on public.player_rule_hands
  for select to authenticated using (
    exists (
      select 1 from public.players p
      where p.id = player_rule_hands.player_id and p.user_id = auth.uid()
    )
  );

do $$ begin
  alter publication supabase_realtime add table public.player_rule_hands;
exception when duplicate_object then null; end $$;
alter table public.player_rule_hands replica identity full;

-- round_rule_picks --------------------------------------------------------
create table if not exists public.round_rule_picks (
  round_id uuid primary key references public.rounds(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  rule_kind text not null check (rule_kind in ('subtract','no_cancel')),
  picked_at timestamptz not null default now()
);

alter table public.round_rule_picks enable row level security;
drop policy if exists round_rule_picks_select on public.round_rule_picks;
create policy round_rule_picks_select on public.round_rule_picks for select to authenticated using (
  exists (
    select 1 from public.rounds r
    join public.players p on p.room_id = r.room_id
    where r.id = round_rule_picks.round_id
      and p.user_id = auth.uid()
      and (
        r.status in ('revealed','scored')
        or round_rule_picks.player_id = p.id
      )
  )
);

do $$ begin
  alter publication supabase_realtime add table public.round_rule_picks;
exception when duplicate_object then null; end $$;
alter table public.round_rule_picks replica identity full;

-- columnas auxiliares -----------------------------------------------------
alter table public.rooms   add column if not exists rule_deck text[] not null default '{}';
alter table public.players add column if not exists rule_hand_size int not null default 0;
alter table public.rounds  add column if not exists rule_played text;

-- helpers -----------------------------------------------------------------
create or replace function public.build_rule_deck(p_player_count int) returns text[]
language sql immutable as $$
  with n as (select greatest(5, p_player_count + 1) as v)
  select array_agg(card) from (
    select 'subtract'::text as card from n, generate_series(1, n.v)
    union all
    select 'no_cancel' from n, generate_series(1, n.v)
  ) t;
$$;

create or replace function public.shuffle_text(p_arr text[]) returns text[]
language sql volatile as $$
  select array_agg(v order by r) from (
    select v, random() as r from unnest(p_arr) v
  ) s;
$$;

-- score_picks con soporte para reglas -------------------------------------
drop function if exists public.score_picks(jsonb);
drop function if exists public.score_picks(jsonb, text);
create or replace function public.score_picks(p_picks jsonb, p_rule text default null)
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
  v_n int; v_i int; v_j int; v_idx int;
  v_run_cards int[];
  v_run_sum int;
  v_lowest_card int;
  v_lowest_owner uuid;
  v_pick record;
  v_no_cancel boolean := (p_rule = 'no_cancel');
  v_sign int := case when p_rule = 'subtract' then -1 else 1 end;
begin
  for v_value in 3..9 loop
    select count(*) into v_count
      from jsonb_array_elements(p_picks) e
      where (e->>'card_value')::int = v_value;
    if v_count = 1 then
      v_unique_values := array_append(v_unique_values, v_value);
    elsif v_count > 1 then
      if v_no_cancel then
        v_unique_values := array_append(v_unique_values, v_value);
      else
        v_canceled := array_append(v_canceled, v_value);
      end if;
    end if;
  end loop;

  for v_pick in
    select (e->>'player_id')::uuid as player_id, (e->>'card_value')::int as card_value
      from jsonb_array_elements(p_picks) e
  loop
    if v_no_cancel or (v_pick.card_value = any(v_unique_values)) then
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
        'sum', v_run_sum * v_sign,
        'winner_id', v_lowest_owner
      );
      v_i := v_j + 1;
    else
      v_i := v_i + 1;
    end if;
  end loop;

  for v_pick in
    select (e->>'player_id')::uuid as player_id, (e->>'card_value')::int as card_value
      from jsonb_array_elements(v_unique_picks) e
  loop
    v_deltas := v_deltas || jsonb_build_object(
      'player_id', v_pick.player_id, 'points', v_pick.card_value * v_sign, 'reason', 'unique'
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
    'deltas', v_deltas,
    'rule', coalesce(p_rule, 'normal')
  );
end $$;

-- start_game con reparto de reglas ----------------------------------------
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

  v_rule_deck := public.shuffle_text(public.build_rule_deck(v_count));
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
  update public.rooms set rule_deck = coalesce(v_remaining, '{}') where id = p_room_id;

  select players.id into v_first_player from public.players
    where players.room_id = p_room_id order by players.seat asc limit 1;

  update public.rooms set
    status = 'in_progress',
    current_round = 1,
    current_michudice = v_first_player
  where rooms.id = p_room_id;

  insert into public.rounds(room_id, round_number, michudice_player_id)
    values (p_room_id, 1, v_first_player);
end $$;

-- submit_rule_pick --------------------------------------------------------
create or replace function public.submit_rule_pick(p_round_id uuid, p_rule_kind text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
  v_round public.rounds%rowtype;
  v_player_id uuid;
  v_hand text[];
  v_existing text;
  v_pos int;
begin
  if p_rule_kind not in ('subtract','no_cancel') then raise exception 'invalid rule'; end if;
  select * into v_round from public.rounds where rounds.id = p_round_id;
  if not found then raise exception 'round not found'; end if;
  if v_round.status <> 'picking' then raise exception 'round closed'; end if;

  select p.id into v_player_id from public.players p
    where p.room_id = v_round.room_id and p.user_id = v_uid;
  if v_player_id is null then raise exception 'not in room'; end if;
  if v_player_id <> v_round.michudice_player_id then
    raise exception 'only michudice can pick rule';
  end if;

  select hand into v_hand from public.player_rule_hands where player_id = v_player_id for update;
  if v_hand is null then raise exception 'no rule hand'; end if;

  select rule_kind into v_existing from public.round_rule_picks where round_id = p_round_id;
  if found then
    v_hand := array_append(v_hand, v_existing);
  end if;

  v_pos := array_position(v_hand, p_rule_kind);
  if v_pos is null then raise exception 'rule not in hand'; end if;
  v_hand := v_hand[1:v_pos-1] || v_hand[v_pos+1:array_length(v_hand,1)];

  update public.player_rule_hands set hand = v_hand where player_id = v_player_id;
  update public.players set rule_hand_size = coalesce(array_length(v_hand,1), 0)
    where id = v_player_id;

  insert into public.round_rule_picks(round_id, player_id, rule_kind)
    values (p_round_id, v_player_id, p_rule_kind)
    on conflict (round_id) do update
      set player_id = excluded.player_id,
          rule_kind = excluded.rule_kind,
          picked_at = now();
end $$;

-- reveal_round con reglas + reposición ------------------------------------
drop function if exists public.reveal_round(uuid);
create or replace function public.reveal_round(p_round_id uuid)
returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_round public.rounds%rowtype;
  v_room public.rooms%rowtype;
  v_player_count int;
  v_pick_count int;
  v_picks jsonb;
  v_rule text;
  v_result jsonb;
  v_deltas jsonb;
  v_delta record;
  v_michudice_hand text[];
  v_room_deck text[];
  v_drawn text;
  v_remaining text[];
begin
  select * into v_round from public.rounds where rounds.id = p_round_id for update;
  if not found then raise exception 'round not found'; end if;
  if v_round.status <> 'picking' then return false; end if;

  select * into v_room from public.rooms where rooms.id = v_round.room_id for update;

  select count(*) into v_player_count from public.players where players.room_id = v_room.id;
  select count(*) into v_pick_count from public.round_picks where round_id = p_round_id;
  if v_pick_count < v_player_count then return false; end if;

  select rule_kind into v_rule from public.round_rule_picks where round_id = p_round_id;
  if v_rule is null then return false; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'player_id', player_id, 'card_value', card_value
  )), '[]'::jsonb) into v_picks
  from public.round_picks where round_id = p_round_id;

  v_result := public.score_picks(v_picks, v_rule);
  v_deltas := v_result -> 'deltas';

  update public.rounds set status = 'revealed', revealed_at = now(), rule_played = v_rule
    where id = p_round_id;

  for v_delta in
    select * from jsonb_to_recordset(v_deltas) as x(player_id uuid, points int)
  loop
    update public.players set score = score + v_delta.points where id = v_delta.player_id;
  end loop;

  update public.players set michudice_count = michudice_count + 1
    where id = v_round.michudice_player_id;

  insert into public.round_results(round_id, payload) values (p_round_id, v_result);
  update public.rounds set status = 'scored', scored_at = now() where id = p_round_id;

  -- Reponer carta de regla al Michudice
  select hand into v_michudice_hand from public.player_rule_hands
    where player_id = v_round.michudice_player_id for update;
  v_room_deck := v_room.rule_deck;

  if coalesce(array_length(v_room_deck, 1), 0) > 0 then
    v_drawn := v_room_deck[1];
    v_michudice_hand := array_append(v_michudice_hand, v_drawn);
    v_remaining := array(
      select v_room_deck[i]
      from generate_series(2, array_length(v_room_deck, 1)) i
    );
    update public.rooms set rule_deck = coalesce(v_remaining, '{}') where id = v_room.id;
    update public.player_rule_hands set hand = v_michudice_hand
      where player_id = v_round.michudice_player_id;
    update public.players set rule_hand_size = coalesce(array_length(v_michudice_hand, 1), 0)
      where id = v_round.michudice_player_id;
  end if;

  return true;
end $$;
