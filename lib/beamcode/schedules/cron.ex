defmodule Beamcode.Schedules.Cron do
  @moduledoc "Five-field cron: minute hour day-of-month month day-of-week. Supports * , - and /."

  @ranges [{0, 59}, {0, 23}, {1, 31}, {1, 12}, {0, 7}]

  def parse(expr) when is_binary(expr) do
    fields = String.split(String.trim(expr), ~r/\s+/)

    if length(fields) == 5 do
      fields
      |> Enum.zip(@ranges)
      |> Enum.reduce_while({:ok, []}, fn {field, range}, {:ok, acc} ->
        case parse_field(field, range) do
          {:ok, set} -> {:cont, {:ok, acc ++ [set]}}
          :error -> {:halt, {:error, "invalid field #{inspect(field)}"}}
        end
      end)
      |> case do
        {:ok, [m, h, dom, mon, dow]} ->
          # Sunday is 0 or 7.
          dow = if MapSet.member?(dow, 7), do: MapSet.put(dow, 0), else: dow

          {:ok,
           %{
             minute: m,
             hour: h,
             dom: dom,
             month: mon,
             dow: dow,
             any_dom: Enum.at(fields, 2) == "*",
             any_dow: Enum.at(fields, 4) == "*"
           }}

        error ->
          error
      end
    else
      {:error, "needs five fields"}
    end
  end

  def parse(_), do: {:error, "needs five fields"}

  def valid?(expr), do: match?({:ok, _}, parse(expr))

  defp parse_field(field, {lo, hi}) do
    field
    |> String.split(",")
    |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case parse_part(part, lo, hi) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, MapSet.new(values))}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp parse_part(part, lo, hi) do
    {range, step} =
      case String.split(part, "/") do
        [r] -> {r, "1"}
        [r, s] -> {r, s}
        _ -> {nil, nil}
      end

    with {step_n, ""} when step_n > 0 <- Integer.parse(step || ""),
         {:ok, a, b} <- parse_range(range, lo, hi, step != "1"),
         true <- a >= lo and b <= hi and a <= b do
      {:ok, Enum.take_every(a..b, step_n)}
    else
      _ -> :error
    end
  end

  defp parse_range("*", lo, hi, _stepped?), do: {:ok, lo, hi}

  defp parse_range(range, _lo, hi, stepped?) when is_binary(range) do
    case String.split(range, "-") do
      [a] -> with {a, ""} <- Integer.parse(a), do: {:ok, a, if(stepped?, do: hi, else: a)}
      [a, b] -> with {a, ""} <- Integer.parse(a), {b, ""} <- Integer.parse(b), do: {:ok, a, b}
      _ -> :error
    end
    |> case do
      {:ok, _, _} = ok -> ok
      _ -> :error
    end
  end

  defp parse_range(_, _, _, _), do: :error

  @doc "Does the cron match this NaiveDateTime (minute resolution)?"
  def matches?(%{} = cron, %NaiveDateTime{} = t) do
    dow = Date.day_of_week(t, :sunday) - 1

    dom_ok = MapSet.member?(cron.dom, t.day)
    dow_ok = MapSet.member?(cron.dow, dow)

    # Standard cron: if both day fields are restricted, either may match.
    day_ok =
      cond do
        cron.any_dom and cron.any_dow -> true
        cron.any_dom -> dow_ok
        cron.any_dow -> dom_ok
        true -> dom_ok or dow_ok
      end

    MapSet.member?(cron.minute, t.minute) and MapSet.member?(cron.hour, t.hour) and
      MapSet.member?(cron.month, t.month) and day_ok
  end

  @doc "Next matching minute after `from`, searching up to ~1 year ahead."
  def next(cron, %NaiveDateTime{} = from) do
    start =
      from |> NaiveDateTime.truncate(:second) |> Map.put(:second, 0) |> NaiveDateTime.add(60)

    Stream.iterate(start, &NaiveDateTime.add(&1, 60))
    |> Stream.take(366 * 24 * 60)
    |> Enum.find(&matches?(cron, &1))
  end

  @doc "Short human text for common shapes, else the cron line."
  def describe(expr) do
    case String.split(String.trim(expr || "")) do
      ["*/" <> n, "*", "*", "*", "*"] -> "every #{n} min"
      ["0", "*", "*", "*", "*"] -> "hourly"
      [m, h, "*", "*", "1-5"] -> "weekdays #{hhmm(h, m)}"
      [m, h, "*", "*", "*"] -> "daily #{hhmm(h, m)}"
      [m, h, "*", "*", d] -> "#{day_names(d)} #{hhmm(h, m)}"
      _ -> expr
    end
  end

  defp hhmm(h, m) do
    with {h, ""} <- Integer.parse(h), {m, ""} <- Integer.parse(m) do
      :io_lib.format("~2..0B:~2..0B", [h, m]) |> to_string()
    else
      _ -> "#{h}:#{m}"
    end
  end

  @days ~w(Sun Mon Tue Wed Thu Fri Sat Sun)
  defp day_names(d) do
    d
    |> String.split(",")
    |> Enum.map_join(",", fn x ->
      case Integer.parse(x) do
        {n, ""} when n in 0..7 -> Enum.at(@days, n)
        _ -> x
      end
    end)
  end

  def local_now do
    {{y, mo, d}, {h, mi, s}} = :calendar.local_time()
    NaiveDateTime.new!(y, mo, d, h, mi, s)
  end
end
