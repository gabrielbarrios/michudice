-- Patch: relajar SELECT de rooms/players/rounds para autenticados.
-- El secreto que protege la sala es el código (random 6 chars), expuesto
-- vía la URL solo a quien lo recibe. Las cartas (información sensible)
-- siguen protegidas por la policy de round_picks.

drop policy if exists rooms_select on rooms;
create policy rooms_select on rooms for select to authenticated using (true);

drop policy if exists players_select on players;
create policy players_select on players for select to authenticated using (true);

drop policy if exists rounds_select on rounds;
create policy rounds_select on rounds for select to authenticated using (true);
