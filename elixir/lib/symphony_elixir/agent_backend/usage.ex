defmodule SymphonyElixir.AgentBackend.Usage do
  @moduledoc "Typed usage values; unknown is never represented as zero."

  @type kind :: :billable_tokens | :context_usage | :unknown
  @type t :: %__MODULE__{
          backend: atom(),
          kind: kind(),
          value: non_neg_integer() | nil,
          unit: atom(),
          source: String.t()
        }
  defstruct [:backend, :kind, :value, :unit, :source]

  @spec unknown(atom(), String.t()) :: t()
  def unknown(backend, source), do: %__MODULE__{backend: backend, kind: :unknown, value: nil, unit: :none, source: source}

  @spec billable_tokens(atom(), non_neg_integer(), String.t()) :: t()
  def billable_tokens(backend, value, source) when is_integer(value) and value >= 0,
    do: %__MODULE__{backend: backend, kind: :billable_tokens, value: value, unit: :tokens, source: source}

  @spec comparable?(t()) :: boolean()
  def comparable?(%__MODULE__{kind: :billable_tokens, value: value}) when is_integer(value), do: true
  def comparable?(_), do: false
end
