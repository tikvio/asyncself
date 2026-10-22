defmodule SymphonyElixir.DashboardGatekeeper do
  @moduledoc """
  Strict, read-only reader for the Gatekeeper observation snapshot.

  Health is calculated only from the shared Linux BOOTTIME clock. UTC fields,
  PID existence, file mtime, and BEAM's own monotonic clock never participate.
  """

  alias SymphonyElixir.DashboardClock

  @heartbeat_ttl_ms 60_000
  # Python/BEAM scheduling and integer-ms truncation can put a reader just
  # before a fresh write. This is a precision tolerance, not the TTL.
  @future_tolerance_ms 1_000
  @required_fields [
    {"pid", :positive_integer},
    {"instance_id", :nonempty_string},
    {"boot_id", :nonempty_string},
    {"clock_id", :string},
    {"sequence", :nonnegative_integer},
    {"heartbeat_boottime_ms", :nonnegative_integer},
    {"heartbeat_at", :string},
    {"last_scan_at", :nullable_string},
    {"last_scan_success_boottime_ms", :nullable_nonnegative_integer},
    {"scan_interval_seconds", :positive_number},
    {"last_result", :map},
    {"last_error", :nullable_string}
  ]

  @type read_error ::
          :missing_snapshot
          | :invalid_snapshot
          | :unsupported_schema
          | :scope_mismatch
          | :clock_unavailable
          | :incompatible_snapshot
          | :future_heartbeat
          | :sequence_regression

  @spec read(Path.t(), String.t(), String.t(), map() | nil) :: {:ok, map()} | {:error, read_error()}
  def read(path, profile, project, previous \\ nil) do
    with {:ok, raw} <- read_file(path),
         {:ok, value} <- decode(raw),
         :ok <- validate_schema(value),
         :ok <- validate_scope(value, profile, project),
         {:ok, boot_id} <- DashboardClock.boot_id(),
         {:ok, now} <- DashboardClock.boottime_ms() do
      validate(value, profile, project, boot_id, now, previous)
    else
      {:error, :boot_id_unavailable} -> {:error, :clock_unavailable}
      {:error, {:clock_adapter_failed, _}} -> {:error, :clock_unavailable}
      {:error, {:clock_adapter_error, _}} -> {:error, :clock_unavailable}
      {:error, :clock_adapter_unavailable} -> {:error, :clock_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec heartbeat_ttl_ms() :: pos_integer()
  def heartbeat_ttl_ms, do: @heartbeat_ttl_ms

  @spec future_tolerance_ms() :: pos_integer()
  def future_tolerance_ms, do: @future_tolerance_ms

  @doc "Validates a decoded snapshot against an explicitly supplied BOOTTIME sample."
  @spec validate(map(), String.t(), String.t(), String.t() | nil, non_neg_integer(), map() | nil) ::
          {:ok, map()} | {:error, read_error()}
  def validate(value, profile, project, boot_id, now, previous \\ nil) do
    with :ok <- validate_schema(value),
         :ok <- validate_scope(value, profile, project),
         :ok <- validate_clock(value, boot_id),
         :ok <- validate_not_future(value, now),
         :ok <- validate_sequence(value, previous) do
      {:ok, Map.put(value, :health, health(value, now))}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, :enoent} -> {:error, :missing_snapshot}
      {:error, _} -> {:error, :invalid_snapshot}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_snapshot}
    end
  end

  defp validate_schema(%{"schema_version" => 1} = value) do
    if valid_schema_fields?(value), do: :ok, else: {:error, :invalid_snapshot}
  end

  defp validate_schema(%{"schema_version" => schema}) when is_integer(schema), do: {:error, :unsupported_schema}
  defp validate_schema(_), do: {:error, :invalid_snapshot}

  defp valid_schema_fields?(value) do
    Enum.all?(@required_fields, fn {field, type} -> valid_field?(Map.get(value, field), type) end)
  end

  defp valid_field?(value, :positive_integer), do: is_integer(value) and value > 0
  defp valid_field?(value, :nonnegative_integer), do: is_integer(value) and value >= 0
  defp valid_field?(value, :nullable_nonnegative_integer), do: is_nil(value) or valid_field?(value, :nonnegative_integer)
  defp valid_field?(value, :positive_number), do: is_number(value) and value > 0
  defp valid_field?(value, :string), do: is_binary(value)
  defp valid_field?(value, :nonempty_string), do: is_binary(value) and byte_size(value) > 0
  defp valid_field?(value, :nullable_string), do: is_nil(value) or is_binary(value)
  defp valid_field?(value, :map), do: is_map(value)

  defp validate_scope(%{"profile" => profile, "project" => project}, profile, project), do: :ok
  defp validate_scope(_, _, _), do: {:error, :scope_mismatch}

  defp validate_clock(value, boot_id) do
    if DashboardClock.comparable?(value, boot_id), do: :ok, else: {:error, :incompatible_snapshot}
  end

  defp validate_not_future(%{"heartbeat_boottime_ms" => heartbeat} = value, now) do
    success = value["last_scan_success_boottime_ms"]

    if heartbeat <= now + @future_tolerance_ms and (is_nil(success) or success <= now + @future_tolerance_ms) do
      :ok
    else
      {:error, :future_heartbeat}
    end
  end

  defp validate_sequence(value, previous) when is_map(previous) do
    if value["instance_id"] == previous["instance_id"] and
         is_integer(previous["sequence"]) and value["sequence"] < previous["sequence"] do
      {:error, :sequence_regression}
    else
      :ok
    end
  end

  defp validate_sequence(_value, _previous), do: :ok

  defp health(value, now) do
    heartbeat_age = max(now - value["heartbeat_boottime_ms"], 0)
    interval_ms = trunc(value["scan_interval_seconds"] * 1_000)
    scan_limit_ms = max(interval_ms * 3, 120_000)

    %{
      heartbeat: if(heartbeat_age <= @heartbeat_ttl_ms, do: :fresh, else: :suspected_offline),
      heartbeat_age_ms: heartbeat_age,
      scan: scan_health(value["last_scan_success_boottime_ms"], now, scan_limit_ms),
      scan_limit_ms: scan_limit_ms
    }
  end

  defp scan_health(nil, _now, _limit), do: :unknown
  defp scan_health(success, now, limit) when now - success > limit, do: :overdue
  defp scan_health(_success, _now, _limit), do: :fresh
end
