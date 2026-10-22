defmodule SymphonyElixirWeb.Dashboard.MergingActionComponents do
  @moduledoc "Shared list/detail presentation for the Linear-only Merging action."

  use Phoenix.Component

  attr(:issue, :map, required: true)
  attr(:action_scope, :any, required: true)
  attr(:actions, :map, required: true)
  attr(:gatekeeper, :any, default: nil)

  @spec action_control(map()) :: Phoenix.LiveView.Rendered.t()
  def action_control(assigns) do
    presentation = presentation(assigns.issue, assigns.action_scope, assigns.actions, assigns.gatekeeper)
    assigns = assign(assigns, :presentation, presentation)

    ~H"""
    <div class="merging-action" data-issue-id={issue_id(@issue)}>
      <%= case @presentation.kind do %>
        <% :needs_info -> %>
          <a class="merging-button needs-info-link" href={@presentation.url} target="_blank" rel="noopener noreferrer">Open in Linear</a>
          <p class="source-status">Provide the requested information in Linear. This dashboard remains read-only.</p>
        <% :ready -> %>
          <button type="button" class="merging-button" phx-click="merging-open" phx-value-issue-id={issue_id(@issue)}>Merging</button>
          <p class="source-status">Only updates Linear status; Gatekeeper handles the next step.</p>
        <% :submitting -> %>
          <button type="button" class="merging-button" disabled>Submitting…</button>
          <p class="source-status">Linear transition is in progress. Do not retry.</p>
        <% :waiting -> %>
          <p class="merging-status waiting-gatekeeper">Waiting Gatekeeper</p>
          <p class="source-status">Linear is Merging. This does not mean the PR has merged.</p>
        <% :attention -> %>
          <p class="merging-status action-failed">Gatekeeper needs attention</p>
          <p class="source-status">Linear is Merging, but Gatekeeper health is unavailable or overdue. This does not mean the PR has merged.</p>
        <% :conflict -> %>
          <p class="merging-status action-conflict">State changed externally</p>
          <p class="source-status">Refresh the issue; the dashboard did not overwrite the newer Linear state.</p>
        <% :failed -> %>
          <p class="merging-status action-failed">Merging submission failed</p>
          <p class="source-status">No PR merge is claimed. Read Linear and retry only after resolving the cause.</p>
        <% :completed -> %>
          <p class="merging-status action-completed">PR merged</p>
          <p class="source-status">Shown from the refreshed read model, not from the Linear transition alone.</p>
        <% :disabled -> %>
          <button type="button" class="merging-button" disabled>Merging</button>
          <p class="source-status"><%= @presentation.message %></p>
      <% end %>
    </div>
    """
  end

  attr(:confirmation, :map, default: nil)
  attr(:gatekeeper, :any, default: nil)

  @spec confirmation_dialog(map()) :: Phoenix.LiveView.Rendered.t()
  def confirmation_dialog(assigns) do
    ~H"""
    <%= if @confirmation do %>
      <section id="merging-confirmation" class="merging-confirmation" role="dialog" aria-modal="true" aria-labelledby="merging-confirmation-title">
        <h2 id="merging-confirmation-title" class="section-title">Move <%= issue_value(@confirmation.issue, :identifier) %> to Merging?</h2>
        <p>Only updates Linear status; Gatekeeper handles the next step.</p>
        <p>Current Linear state: <strong><%= issue_value(@confirmation.issue, :state_name) %></strong>.</p>
        <p><%= context_label(@confirmation.issue) %></p>
        <p :if={@confirmation.phase == :submitting} class="source-status">Submitting to Linear and reading the actual state back…</p>
        <p :if={@confirmation.phase == :waiting and gatekeeper_needs_attention?(@gatekeeper)} class="merging-status action-failed">Gatekeeper needs attention. Linear Merging is not PR merged.</p>
        <p :if={@confirmation.phase == :waiting and not gatekeeper_needs_attention?(@gatekeeper)} class="merging-status waiting-gatekeeper">Waiting Gatekeeper. Linear Merging is not PR merged.</p>
        <p :if={@confirmation.phase == :conflict} class="merging-status action-conflict">The issue changed externally. The dashboard made no overwrite.</p>
        <p :if={@confirmation.phase == :failed} class="merging-status action-failed">Submission could not be confirmed. No PR merge is claimed.</p>
        <div class="detail-actions">
          <button :if={@confirmation.phase == :ready} type="button" class="merging-button" phx-click="merging-submit">Confirm Merging</button>
          <button :if={@confirmation.phase != :submitting} type="button" class="subtle-button" phx-click="merging-close">Close</button>
        </div>
      </section>
    <% end %>
    """
  end

  defp presentation(issue, action_scope, actions, gatekeeper) do
    action = Map.get(actions, issue_id(issue))
    state_name = issue_value(issue, :state_name)

    cond do
      pr_merged?(issue) ->
        %{kind: :completed}

      state_name == "Needs Info" ->
        needs_info_presentation(issue)

      true ->
        case action_presentation(action, state_name, gatekeeper) do
          nil -> ready_or_disabled(state_name, action_scope)
          presentation -> presentation
        end
    end
  end

  defp needs_info_presentation(issue) do
    case linear_issue_url(issue) do
      nil -> %{kind: :disabled, message: "Linear issue link is unavailable."}
      url -> %{kind: :needs_info, url: url}
    end
  end

  defp action_presentation(%{status: :submitting}, _state_name, _gatekeeper), do: %{kind: :submitting}
  defp action_presentation(%{status: :conflict}, _state_name, _gatekeeper), do: %{kind: :conflict}
  defp action_presentation(%{status: :failed}, _state_name, _gatekeeper), do: %{kind: :failed}

  defp action_presentation(action, state_name, gatekeeper)
       when state_name == "Merging" or (is_map(action) and action.status == :waiting_gatekeeper) do
    if gatekeeper_needs_attention?(gatekeeper), do: %{kind: :attention}, else: %{kind: :waiting}
  end

  defp action_presentation(_, _, _), do: nil

  defp ready_or_disabled("In Review", action_scope) do
    if action_enabled?(action_scope), do: %{kind: :ready}, else: %{kind: :disabled, message: "Linear actions are disabled by dashboard configuration."}
  end

  defp ready_or_disabled(_, _), do: %{kind: :disabled, message: "Available only while the verified Linear state is In Review."}

  defp action_enabled?({:ok, %{enabled?: true}}), do: true
  defp action_enabled?(_), do: false

  defp gatekeeper_needs_attention?(%{status: %{availability: availability}}) when availability in [:empty, :unavailable], do: true
  defp gatekeeper_needs_attention?(%{data: %{health: %{heartbeat: heartbeat, scan: scan}}}) when heartbeat in [:suspected_offline, :invalid] or scan in [:overdue, :failed], do: true
  defp gatekeeper_needs_attention?(_), do: false

  defp pr_merged?(issue) do
    pr_data = Map.get(issue, :pr_data) || %{}

    pr_data
    |> Map.get(:prs, [])
    |> Enum.any?(&(Map.get(&1, :state) == :merged))
  end

  defp linear_issue_url(issue) do
    case issue_value(issue, :url) |> to_string() |> String.trim() |> URI.parse() do
      %URI{scheme: "https", host: host} = uri when host in ["linear.app", "www.linear.app"] -> URI.to_string(uri)
      _ -> nil
    end
  end

  defp context_label(issue) do
    case Map.get(issue, :pr_data) || %{} do
      %{prs: [pr | _]} -> "Associated PR ##{Map.get(pr, :number, "unknown")} is shown for context; it will not be merged by this page."
      _ -> "No verified PR is required for this Linear-only submission; Gatekeeper remains the sole merge executor."
    end
  end

  defp issue_id(issue), do: issue_value(issue, :id)
  defp issue_value(issue, key), do: Map.get(issue, key) || Map.get(issue, Atom.to_string(key)) || "unknown"
end
