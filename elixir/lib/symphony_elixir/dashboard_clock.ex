defmodule SymphonyElixir.DashboardClock do
  @moduledoc """
  Linux `CLOCK_BOOTTIME` adapter for the cross-process Gatekeeper protocol.

  OTP's monotonic clock is deliberately not used here: it has no documented
  common epoch with Python. The small Python bridge invokes the same Linux
  `clock_gettime(CLOCK_BOOTTIME)` syscall as the writer and returns integer
  milliseconds. Failure is explicit and never falls back to wall time.
  """

  @clock_id "linux:CLOCK_BOOTTIME:ms"
  @python_clock "import time; print(time.clock_gettime_ns(time.CLOCK_BOOTTIME)//1000000)"

  @spec boottime_ms() :: {:ok, non_neg_integer()} | {:error, term()}
  def boottime_ms do
    with executable when is_binary(executable) <- System.find_executable("python3"),
         {value, 0} <- System.cmd(executable, ["-c", @python_clock], stderr_to_stdout: true) do
      parse_ms(String.trim(value))
    else
      nil -> {:error, :clock_adapter_unavailable}
      {_output, status} -> {:error, {:clock_adapter_failed, status}}
    end
  rescue
    error -> {:error, {:clock_adapter_error, Exception.message(error)}}
  end

  @spec boot_id() :: {:ok, String.t()} | {:error, :boot_id_unavailable}
  def boot_id do
    case File.read("/proc/sys/kernel/random/boot_id") do
      {:ok, value} ->
        case String.trim(value) do
          "" -> {:error, :boot_id_unavailable}
          boot_id -> {:ok, boot_id}
        end

      _ ->
        {:error, :boot_id_unavailable}
    end
  end

  @spec clock_id() :: String.t()
  def clock_id, do: @clock_id

  @spec comparable?(map(), String.t() | nil) :: boolean()
  def comparable?(%{"clock_id" => @clock_id, "boot_id" => boot_id, "heartbeat_boottime_ms" => value}, boot_id)
      when is_binary(boot_id) and is_integer(value) and value >= 0,
      do: true

  def comparable?(_, _), do: false

  defp parse_ms(value) do
    case Integer.parse(value) do
      {milliseconds, ""} when milliseconds >= 0 -> {:ok, milliseconds}
      _ -> {:error, :invalid_clock_value}
    end
  end
end
