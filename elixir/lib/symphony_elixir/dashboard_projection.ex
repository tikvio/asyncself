defmodule SymphonyElixir.DashboardProjection do
  @moduledoc """
  Pure, conservative projections used by the read-only dashboard.

  `:unknown` is intentional: it prevents a missing page, stale snapshot, or
  incomplete PR response from being rendered as a negative business fact.
  """

  @type verdict :: %{value: true | false | :unknown, reason: String.t()}

  @spec terminal_state?(String.t() | nil) :: boolean() | :unknown
  def terminal_state?(type) when type in ["completed", "canceled"], do: true
  def terminal_state?(type) when is_binary(type), do: false
  def terminal_state?(_), do: :unknown

  @spec runtime_state(String.t(), map() | :unavailable | :unknown) :: String.t()
  def runtime_state(issue_id, %{running: running, retrying: retrying, blocked: blocked}) do
    cond do
      contains_issue?(running, issue_id) -> "running"
      contains_issue?(retrying, issue_id) -> "retrying"
      contains_issue?(blocked, issue_id) -> "blocked"
      true -> "idle"
    end
  end

  def runtime_state(_issue_id, :unavailable), do: "unavailable"
  def runtime_state(_issue_id, _snapshot), do: "unknown"

  @spec attach_runtime([map()], map()) :: [map()]
  def attach_runtime(issues, %{error: _}) when is_list(issues) do
    Enum.map(issues, &Map.put(&1, :runtime_state, "unavailable"))
  end

  def attach_runtime(issues, %{running: running, retrying: retrying, blocked: blocked}) when is_list(issues) do
    runtime = %{running: running, retrying: retrying, blocked: blocked}
    Enum.map(issues, &Map.put(&1, :runtime_state, runtime_state(Map.get(&1, :id), runtime)))
  end

  def attach_runtime(issues, _payload) when is_list(issues), do: Enum.map(issues, &Map.put(&1, :runtime_state, "unknown"))

  @spec review_attention(map()) :: verdict()
  def review_attention(%{complete?: false}), do: unknown("PR review data is incomplete")

  def review_attention(%{changes_requested?: true}),
    do: %{value: true, reason: "current changes requested review"}

  def review_attention(%{unresolved_threads: count}) when is_integer(count) and count > 0,
    do: %{value: true, reason: "unresolved review threads"}

  def review_attention(%{unresolved_threads: count}) when is_integer(count) and count >= 0,
    do: %{value: false, reason: "no current review feedback"}

  def review_attention(_), do: unknown("PR review data is unavailable")

  @spec review_waiting(map()) :: verdict()
  def review_waiting(%{complete?: false}), do: unknown("PR checks or review data is incomplete")
  def review_waiting(%{draft?: true}), do: %{value: false, reason: "PR is draft"}
  def review_waiting(%{checks: :pending}), do: %{value: false, reason: "required checks are pending"}
  def review_waiting(%{checks: :failed}), do: %{value: false, reason: "required checks failed"}
  def review_waiting(%{checks: :unknown}), do: unknown("required checks are unknown")
  def review_waiting(%{changes_requested?: true}), do: %{value: false, reason: "review changes requested"}

  def review_waiting(%{unresolved_threads: count}) when is_integer(count) and count > 0,
    do: %{value: false, reason: "review threads unresolved"}

  def review_waiting(%{checks: :passed, unresolved_threads: 0}), do: %{value: true, reason: "awaiting human review"}
  def review_waiting(_), do: unknown("PR review inputs are unavailable")

  @doc "Derives the A3 review states across all verified, in-scope PRs."
  @spec pr_verdicts(map() | nil) ::
          %{review_attention: verdict(), review_waiting: verdict(), delivery_exception: verdict()}
  def pr_verdicts(%{complete?: false}), do: unknown_pr_verdicts("PR data is incomplete")

  def pr_verdicts(%{prs: prs, complete?: true}) when is_list(prs) do
    valid = Enum.filter(prs, &(Map.get(&1, :scope) == :valid))

    cond do
      Enum.any?(prs, &scope_warning?/1) ->
        verdicts = unknown_pr_verdicts("PR scope is not verified")
        %{verdicts | delivery_exception: %{value: true, reason: "PR repository or base is outside scope"}}

      valid == [] ->
        %{
          review_attention: %{value: false, reason: "no verified open PR review feedback"},
          review_waiting: %{value: false, reason: "no verified open non-draft PR"},
          delivery_exception: %{value: false, reason: "no verified PR delivery exception"}
        }

      true ->
        %{
          review_attention: attention_for(valid),
          review_waiting: waiting_for(valid),
          delivery_exception: exception_for(valid)
        }
    end
  end

  def pr_verdicts(_), do: unknown_pr_verdicts("PR data is unavailable")

  @spec parse_start_gate(String.t() | nil) :: %{human: [String.t()], dependencies: [String.t()], unknown: [String.t()]}
  def parse_start_gate(description) when is_binary(description) do
    details = parse_start_gate_details(description)
    %{human: Enum.map(details.human, & &1.text), dependencies: Enum.map(details.dependencies, & &1.identifier), unknown: details.unknown}
  end

  def parse_start_gate(_), do: %{human: [], dependencies: [], unknown: []}

  @spec parse_start_gate_details(String.t() | nil) :: %{human: [map()], dependencies: [map()], unknown: [String.t()]}
  def parse_start_gate_details(description) when is_binary(description) do
    description
    |> String.split(~r/\r?\n/)
    |> start_gate_lines()
    |> Enum.reduce(%{human: [], dependencies: [], unknown: []}, fn line, acc ->
      case Regex.run(~r/^\s*-\s*\[([ xX])\]\s*human:\s*(.+)$/, line) do
        [_, checked, text] -> Map.update!(acc, :human, &[%{checked?: String.downcase(checked) == "x", text: String.trim(text), raw: line} | &1])
        _ -> parse_dependency_gate_detail(line, acc)
      end
    end)
    |> Map.new(fn {key, items} -> {key, Enum.reverse(items)} end)
  end

  def parse_start_gate_details(_), do: %{human: [], dependencies: [], unknown: []}

  defp parse_dependency_gate_detail(line, acc) do
    case Regex.run(~r/^\s*-\s*\[([ xX])\]\s*dep:([^\s]+)\s*(.*)$/, line) do
      [_, checked, identifier, text] ->
        Map.update!(acc, :dependencies, &[%{checked?: String.downcase(checked) == "x", identifier: identifier, text: String.trim(text), raw: line} | &1])

      _ ->
        if Regex.match?(~r/^\s*(?:-\s*)?(?:\[[ xX]\]\s*)?(?:human:|dep:)|^\s*-\s*\[[ xX]\]/, line),
          do: Map.update!(acc, :unknown, &[String.trim(line) | &1]),
          else: acc
    end
  end

  defp start_gate_lines(lines) do
    case Enum.split_while(lines, &(not Regex.match?(~r/^##\s+Start Gate\s*$/i, &1))) do
      {_before, []} -> []
      {_before, [_heading | rest]} -> Enum.take_while(rest, &(not String.starts_with?(&1, "## ")))
    end
  end

  defp contains_issue?(entries, issue_id) when is_list(entries), do: Enum.any?(entries, &(Map.get(&1, :issue_id) == issue_id || Map.get(&1, "issue_id") == issue_id))
  defp contains_issue?(_, _), do: false
  defp unknown(reason), do: %{value: :unknown, reason: reason}

  defp attention_for(prs) do
    if Enum.any?(prs, &open_changes_requested?/1), do: %{value: true, reason: "current changes requested review"}, else: thread_attention(prs)
  end

  defp thread_attention(prs) do
    threads = Enum.map(prs, &get_in(&1, [:threads, :unresolved]))

    if Enum.any?(threads, &(&1 == :unknown)),
      do: unknown("review thread data is unavailable"),
      else: if(Enum.any?(threads, &(is_integer(&1) and &1 > 0)), do: %{value: true, reason: "unresolved review threads"}, else: %{value: false, reason: "no current review feedback"})
  end

  defp waiting_for(prs) do
    open = Enum.filter(prs, &(Map.get(&1, :state) == :open and not Map.get(&1, :draft?, false)))

    case waiting_blocker(open) do
      :none -> %{value: true, reason: "awaiting human review"}
      {false, reason} -> %{value: false, reason: reason}
      {:unknown, reason} -> unknown(reason)
    end
  end

  defp exception_for(prs) do
    cond do
      Enum.any?(prs, &(Map.get(&1, :scope) != :valid)) -> %{value: true, reason: "PR repository or base is outside scope"}
      Enum.any?(prs, &(Map.get(&1, :state) == :closed)) -> %{value: true, reason: "closed PR was not merged"}
      Enum.any?(prs, &(check_state(&1) == :failed)) -> %{value: true, reason: "required check failed"}
      Enum.any?(prs, &(check_state(&1) == :unknown)) -> unknown("required rules or checks are unknown")
      true -> %{value: false, reason: "no verified PR delivery exception"}
    end
  end

  defp open_changes_requested?(pr), do: Map.get(pr, :state) == :open and get_in(pr, [:reviews, :decision]) == :changes_requested
  defp check_state(%{checks: %{state: state}}), do: state
  defp check_state(%{checks: state}), do: state
  defp check_state(_), do: nil
  defp waiting_blocker([]), do: {false, "no verified open non-draft PR"}

  defp waiting_blocker(open) do
    cond do
      Enum.any?(open, &(check_state(&1) in [:pending, :failed])) -> {false, "required checks are pending or failed"}
      Enum.any?(open, &(check_state(&1) in [:unknown, nil])) -> {:unknown, "required rules or checks are unknown"}
      Enum.any?(open, &open_changes_requested?/1) -> {false, "review changes requested"}
      Enum.any?(open, &(get_in(&1, [:threads, :unresolved]) == :unknown)) -> {:unknown, "review thread data is unavailable"}
      Enum.any?(open, &(is_integer(get_in(&1, [:threads, :unresolved])) and get_in(&1, [:threads, :unresolved]) > 0)) -> {false, "review threads unresolved"}
      Enum.any?(open, &(check_state(&1) in [:passed, :none])) -> :none
      true -> {:unknown, "PR review inputs are unavailable"}
    end
  end

  defp scope_warning?(pr), do: Map.get(pr, :scope) != :valid
  defp unknown_pr_verdicts(reason), do: %{review_attention: unknown(reason), review_waiting: unknown(reason), delivery_exception: unknown(reason)}
end
