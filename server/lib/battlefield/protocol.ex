defmodule Battlefield.Protocol do
  @moduledoc """
  Binary frame, little-endian:

    header:  tick u32 | n_agents u16 | n_events u16
    agent:   id u16 | flags u8 | hp u8 | x i16 | z i16 | heading i16   (10 B)
    event:   type u8 | a u16 | x1 i16 | z1 i16 | x2 i16 | z2 i16 | aux u8  (12 B)

  flags: bit0 team, bits1-2 kind, bits3-5 state.
  Positions are fixed-point 1/64 m. Heading is rad * 10430 (32768/pi).
  Event types: 0 shot, 1 grenade/shell throw (aux = flight*20),
  2 explosion (aux = radius*10), 3 death (a = id, aux = team).
  """
  import Bitwise

  @max_events 400

  def encode(tick, agents, events) do
    events = Enum.take(events, @max_events)
    abin = for {_id, a} <- agents, into: <<>>, do: agent_bin(a)
    ebin = for e <- events, into: <<>>, do: event_bin(e)

    <<tick::32-little, map_size(agents)::16-little, length(events)::16-little>> <>
      abin <> ebin
  end

  defp agent_bin(a) do
    flags = a.team ||| a.kind <<< 1 ||| a.state <<< 3

    <<a.id::16-little, flags::8, clamp(a.hp, 0, 255)::8, fp(a.x)::16-little-signed,
      fp(a.z)::16-little-signed, hfp(a.heading)::16-little-signed>>
  end

  defp event_bin({:shot, x1, z1, x2, z2}) do
    <<0, 0::16, fp(x1)::16-little-signed, fp(z1)::16-little-signed, fp(x2)::16-little-signed,
      fp(z2)::16-little-signed, 0>>
  end

  defp event_bin({:grenade, x1, z1, x2, z2, flight}) do
    <<1, 0::16, fp(x1)::16-little-signed, fp(z1)::16-little-signed, fp(x2)::16-little-signed,
      fp(z2)::16-little-signed, clamp(round(flight * 20), 1, 255)>>
  end

  defp event_bin({:boom, x, z, r}) do
    <<2, 0::16, fp(x)::16-little-signed, fp(z)::16-little-signed, 0::16, 0::16,
      clamp(round(r * 10), 1, 255)>>
  end

  defp event_bin({:death, id, team, x, z}) do
    <<3, id::16-little, fp(x)::16-little-signed, fp(z)::16-little-signed, 0::16, 0::16, team>>
  end

  defp fp(v), do: clamp(round(v * 64), -32000, 32000)

  defp hfp(h) do
    tau = 2 * :math.pi()
    h = :math.fmod(h, tau)
    h = if h > :math.pi(), do: h - tau, else: h
    h = if h < -:math.pi(), do: h + tau, else: h
    clamp(round(h * 10430), -32760, 32760)
  end

  defp clamp(v, a, b), do: v |> max(a) |> min(b)
end
