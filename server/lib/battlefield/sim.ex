defmodule Battlefield.Sim do
  @moduledoc """
  Authoritative battle simulation. Fixed 20 Hz tick, flat agent map,
  no per-agent processes. Broadcasts one binary frame per tick to all
  WebSocket clients via Registry dispatch.

  Agent states: 0 = moving, 1 = firing, 2 = throwing, 3 = dead.
  Kinds: 0 = infantry, 1 = tank.
  """
  use GenServer

  @tick_ms 50
  @dt 0.05

  @field_x 118.0
  @field_z 76.0

  @inf_per_team 250
  @tanks_per_team 2
  @respawn_min 2.0
  @respawn_spread 6.0

  @inf_speed 6.0
  @inf_range 26.0
  @inf_hp 3

  @tank_speed 2.5
  @tank_range 45.0
  @tank_hp 24

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    agents =
      for team <- [0, 1], i <- 1..(@inf_per_team + @tanks_per_team), reduce: %{} do
        acc ->
          kind = if i <= @tanks_per_team, do: 1, else: 0
          id = team * 1000 + i
          Map.put(acc, id, spawn_agent(id, team, kind))
      end

    schedule()
    {:ok, %{tick: 0, agents: agents, grenades: [], events: []}}
  end

  defp schedule, do: Process.send_after(self(), :tick, @tick_ms)

  defp spawn_agent(id, team, kind) do
    x =
      if team == 0,
        do: -@field_x + :rand.uniform() * 48.0,
        else: @field_x - :rand.uniform() * 48.0

    z = (:rand.uniform() - 0.5) * 2.0 * (@field_z - 8.0)

    %{
      id: id,
      team: team,
      kind: kind,
      state: 0,
      hp: if(kind == 1, do: @tank_hp, else: @inf_hp),
      x: x,
      z: z,
      heading: if(team == 0, do: 0.0, else: :math.pi()),
      cd: :rand.uniform(),
      gcd: 3.0 + :rand.uniform() * 6.0,
      dead_t: 0.0,
      respawn_at: @respawn_min + :rand.uniform() * @respawn_spread,
      target: nil,
      off_x: (:rand.uniform() - 0.5) * 10.0,
      off_z: (:rand.uniform() - 0.5) * 10.0
    }
  end

  @impl true
  def handle_info(:tick, s) do
    s =
      s
      |> step_grenades()
      |> step_agents()
      |> retarget()
      |> respawn()

    frame = Battlefield.Protocol.encode(s.tick, s.agents, Enum.reverse(s.events))

    Registry.dispatch(Battlefield.Clients, :ws, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:frame, frame})
    end)

    schedule()
    {:noreply, %{s | tick: s.tick + 1, events: []}}
  end

  # ---------------------------------------------------------------- grenades

  defp step_grenades(s) do
    moved = Enum.map(s.grenades, fn g -> %{g | t: g.t + @dt} end)
    {done, live} = Enum.split_with(moved, &(&1.t >= &1.flight))

    Enum.reduce(done, %{s | grenades: live}, fn g, acc ->
      explode(acc, g.tx, g.tz, g.r, g.dmg, g.team)
    end)
  end

  defp explode(s, x, z, r, dmg, team) do
    {agents, events} =
      Enum.reduce(s.agents, {s.agents, s.events}, fn {id, a}, {ags, ev} ->
        if a.team != team and a.state != 3 and dist(a.x, a.z, x, z) < r do
          a2 = damage(a, dmg)

          ev2 =
            if a2.state == 3 and a.state != 3,
              do: [{:death, a2.id, a2.team, a2.x, a2.z} | ev],
              else: ev

          {Map.put(ags, id, a2), ev2}
        else
          {ags, ev}
        end
      end)

    %{s | agents: agents, events: [{:boom, x, z, r} | events]}
  end

  defp damage(a, dmg) do
    hp = a.hp - dmg
    if hp <= 0, do: %{a | hp: 0, state: 3, dead_t: 0.0}, else: %{a | hp: hp}
  end

  # ------------------------------------------------------------------ agents

  defp step_agents(s) do
    Enum.reduce(Map.keys(s.agents), s, fn id, acc ->
      a = acc.agents[id]

      if a.state == 3 do
        %{acc | agents: Map.put(acc.agents, id, %{a | dead_t: a.dead_t + @dt})}
      else
        step_alive(acc, a)
      end
    end)
  end

  defp step_alive(s, a) do
    tgt =
      case s.agents[a.target] do
        %{state: 3} -> nil
        t -> t
      end

    if tgt == nil do
      # No live target: march toward the enemy side.
      dir = if a.team == 0, do: 0.0, else: :math.pi()
      a = move(a, dir)
      %{s | agents: Map.put(s.agents, a.id, %{a | state: 0})}
    else
      d = dist(a.x, a.z, tgt.x, tgt.z)
      range = if a.kind == 1, do: @tank_range, else: @inf_range

      if d > range do
        dir = :math.atan2(tgt.z + a.off_z - a.z, tgt.x + a.off_x - a.x)
        a = move(a, dir)
        a = %{a | state: 0, cd: max(a.cd - @dt, 0.0), gcd: a.gcd - @dt}
        %{s | agents: Map.put(s.agents, a.id, a)}
      else
        engage(s, a, tgt, d)
      end
    end
  end

  defp move(a, dir) do
    dir = dir + (:rand.uniform() - 0.5) * 0.3
    sp = if a.kind == 1, do: @tank_speed, else: @inf_speed
    x = clamp(a.x + :math.cos(dir) * sp * @dt, -@field_x, @field_x)
    z = clamp(a.z + :math.sin(dir) * sp * @dt, -@field_z, @field_z)
    %{a | x: x, z: z, heading: dir}
  end

  defp engage(s, a, tgt, d) do
    a = %{
      a
      | heading: :math.atan2(tgt.z - a.z, tgt.x - a.x),
        cd: a.cd - @dt,
        gcd: a.gcd - @dt
    }

    if a.kind == 0 and a.gcd <= 0.0 and d > 10.0 and d < 24.0 do
      if cluster_size(s.agents, tgt, a.team) >= 3 do
        throw_grenade(s, a, tgt, d)
      else
        engage2(s, %{a | gcd: 1.5}, tgt, d)
      end
    else
      engage2(s, a, tgt, d)
    end
  end

  defp engage2(s, a, tgt, d) do
    if a.cd <= 0.0 do
      fire(s, a, tgt, d)
    else
      %{s | agents: Map.put(s.agents, a.id, %{a | state: 1})}
    end
  end

  defp throw_grenade(s, a, tgt, d) do
    flight = 0.9 + d / 40.0

    g = %{tx: tgt.x, tz: tgt.z, t: 0.0, flight: flight, r: 6.5, dmg: 3, team: a.team}
    a = %{a | gcd: 12.0 + :rand.uniform() * 8.0, state: 2}

    %{
      s
      | agents: Map.put(s.agents, a.id, a),
        grenades: [g | s.grenades],
        events: [{:grenade, a.x, a.z, tgt.x, tgt.z, flight} | s.events]
    }
  end

  defp fire(s, a, tgt, d) do
    if a.kind == 1 do
      # Tank shell: ballistic AoE projectile.
      flight = 0.4 + d / 90.0
      tx = tgt.x + (:rand.uniform() - 0.5) * 4.0
      tz = tgt.z + (:rand.uniform() - 0.5) * 4.0
      g = %{tx: tx, tz: tz, t: 0.0, flight: flight, r: 8.0, dmg: 4, team: a.team}
      a2 = %{a | cd: 3.5 + :rand.uniform(), state: 1}

      %{
        s
        | agents: Map.put(s.agents, a.id, a2),
          grenades: [g | s.grenades],
          events: [{:grenade, a.x, a.z, tx, tz, flight} | s.events]
      }
    else
      # Rifle shot with distance-based hit probability.
      p = max(0.1, 0.55 - d / 55.0)

      {agents, events} =
        if :rand.uniform() < p do
          t2 = damage(tgt, 1)
          ev = [{:shot, a.x, a.z, tgt.x, tgt.z} | s.events]

          ev =
            if t2.state == 3,
              do: [{:death, t2.id, t2.team, t2.x, t2.z} | ev],
              else: ev

          {Map.put(s.agents, tgt.id, t2), ev}
        else
          mx = tgt.x + (:rand.uniform() - 0.5) * 3.0
          mz = tgt.z + (:rand.uniform() - 0.5) * 3.0
          {s.agents, [{:shot, a.x, a.z, mx, mz} | s.events]}
        end

      a2 = %{a | cd: 1.0 + :rand.uniform() * 0.9, state: 1}
      %{s | agents: Map.put(agents, a.id, a2), events: events}
    end
  end

  defp cluster_size(agents, tgt, my_team) do
    Enum.count(agents, fn {_, b} ->
      b.team != my_team and b.state != 3 and dist(b.x, b.z, tgt.x, tgt.z) < 6.0
    end)
  end

  # -------------------------------------------------------- targets, respawn

  defp retarget(s) do
    Enum.reduce(Map.keys(s.agents), s, fn id, acc ->
      a = acc.agents[id]

      if a.state != 3 and rem(id + acc.tick, 12) == 0 do
        %{acc | agents: Map.put(acc.agents, id, %{a | target: nearest_enemy(acc.agents, a)})}
      else
        acc
      end
    end)
  end

  defp nearest_enemy(agents, a) do
    candidates =
      for {id, b} <- agents, b.team != a.team, b.state != 3 do
        # Randomized weighting spreads fire across the front line.
        {id, dist2(a.x, a.z, b.x, b.z) * (0.8 + :rand.uniform() * 0.4)}
      end

    case candidates do
      [] -> nil
      list -> list |> Enum.min_by(&elem(&1, 1)) |> elem(0)
    end
  end

  defp respawn(s) do
    Enum.reduce(Map.keys(s.agents), s, fn id, acc ->
      a = acc.agents[id]

      if a.state == 3 and a.dead_t >= a.respawn_at do
        %{acc | agents: Map.put(acc.agents, id, spawn_agent(id, a.team, a.kind))}
      else
        acc
      end
    end)
  end

  # ------------------------------------------------------------------- utils

  defp dist(x1, z1, x2, z2), do: :math.sqrt(dist2(x1, z1, x2, z2))
  defp dist2(x1, z1, x2, z2), do: (x1 - x2) * (x1 - x2) + (z1 - z2) * (z1 - z2)
  defp clamp(v, a, b), do: v |> max(a) |> min(b)
end
