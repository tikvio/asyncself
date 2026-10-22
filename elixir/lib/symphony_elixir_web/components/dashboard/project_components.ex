defmodule SymphonyElixirWeb.Dashboard.ProjectComponents do
  @moduledoc "Stateless project-aggregation presentation components."

  use Phoenix.Component

  alias SymphonyElixir.DashboardProjection
  alias SymphonyElixirWeb.Dashboard.MergingActionComponents

  attr(:snapshot, :map, required: true)
  attr(:config, :any, required: true)
  attr(:filters, :map, required: true)
  attr(:action_scope, :any, default: {:error, :action_unavailable})
  attr(:actions, :map, default: %{})
  attr(:gatekeeper, :any, default: nil)

  @spec projects_section(map()) :: Phoenix.LiveView.Rendered.t()
  def projects_section(assigns) do
    linear = get_in(assigns.snapshot, [:sources, :linear])
    assigns = assign(assigns, :linear, linear)

    ~H"""
    <section id="project-aggregation" class="section-card project-aggregation">
      <div class="section-header">
        <div>
          <h2 class="section-title">Project issues</h2>
          <p class="section-copy">Read-only Linear, GitHub, runtime, and Gatekeeper summaries. <%= scope_label(@config) %></p>
        </div>
        <button type="button" class="subtle-button" phx-click="dashboard-refresh">Refresh project data</button>
      </div>
      <%= if @linear == nil do %>
        <p class="empty-state">Project aggregation is disabled or has not completed its first read.</p>
      <% else %>
        <p class="source-status">
          Linear: <%= @linear.status.availability %> · <%= @linear.status.freshness %> · <%= @linear.status.refresh %>
          <%= if @linear.status.last_error do %> · last read error recorded<% end %>
        </p>
        <%= if is_list(@linear.data) and @linear.data != [] do %>
          <form id="project-filter-form" phx-change="project-filter" class="project-filters">
            <label>Search <input type="search" name="q" value={@filters.q} placeholder="ID or title" /></label>
            <label>State
              <select name="state">
                <option value="all" selected={@filters.state == "all"}>All states</option>
                <option :for={state <- issue_states(@linear.data)} value={state} selected={@filters.state == state}><%= state %></option>
              </select>
            </label>
          </form>
          <div class="table-wrap">
            <table class="data-table">
              <thead><tr><th>Issue</th><th>Linear state</th><th>Runtime</th><th>PR / review</th><th>Updated</th><th>Action</th></tr></thead>
              <tbody>
            <tr :for={issue <- Enum.filter(@linear.data, &(default_scope?(&1) and matches_filters?(&1, @filters)))}>
                  <td><a class="issue-id issue-id-link" href={issue_detail_url(issue, @filters)}><%= value(issue, :identifier) %></a><br/><span><%= value(issue, :title) %></span><br/><a :if={safe_url(Map.get(issue, :url) || Map.get(issue, "url"))} class="issue-link" href={safe_url(Map.get(issue, :url) || Map.get(issue, "url"))} target="_blank" rel="noopener noreferrer">Linear</a></td>
                  <td><%= value(issue, :state_name) %></td>
                  <td><%= value(issue, :runtime_state) %></td>
                  <td><%= pr_summary(issue) %></td>
                  <td class="mono"><%= value(issue, :updated_at) %></td>
                  <td><MergingActionComponents.action_control issue={issue} action_scope={@action_scope} actions={@actions} gatekeeper={@gatekeeper} /></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% else %>
          <p class="empty-state">No project issues in the successful snapshot.</p>
        <% end %>
      <% end %>
      <div class="source-status" :for={source <- [:github, :gatekeeper]}>
        <%= source %>: <%= source_status(@snapshot, source) %>
      </div>
      <p class="source-status"><%= gatekeeper_health(@snapshot) %></p>
    </section>
    """
  end

  defp scope_label({:ok, config}), do: "#{config.profile} · #{config.project_slug} · #{config.repository} → #{config.target_branch}"
  defp scope_label({:error, _}), do: "Scope configuration unavailable; aggregation remains disabled."

  defp default_scope?(issue), do: Map.get(issue, :default_scope?, Map.get(issue, "default_scope?", true))

  defp issue_states(issues), do: issues |> Enum.map(&value(&1, :state_name)) |> Enum.uniq() |> Enum.sort()

  defp matches_filters?(issue, %{q: q, state: state}) do
    haystack = "#{value(issue, :identifier)} #{value(issue, :title)}" |> String.downcase()
    (q == "" or String.contains?(haystack, String.downcase(q))) and (state == "all" or value(issue, :state_name) == state)
  end

  defp issue_detail_url(issue, filters) do
    "/issues/" <> URI.encode(value(issue, :identifier)) <> "?" <> URI.encode_query(%{"q" => filters.q, "state" => filters.state})
  end

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || "unknown"
  end

  defp safe_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: "https", host: host} when host in ["linear.app", "www.linear.app"] -> url
      _ -> nil
    end
  end

  defp safe_url(_), do: nil

  defp source_status(snapshot, source) do
    case get_in(snapshot, [:sources, source, :status]) do
      nil -> "unknown"
      status -> "#{status.availability} · #{status.freshness} · #{status.refresh}"
    end
  end

  defp gatekeeper_health(snapshot) do
    case get_in(snapshot, [:sources, :gatekeeper, :data, :health]) do
      %{heartbeat: heartbeat, scan: scan, heartbeat_age_ms: age} ->
        "Gatekeeper process heartbeat: #{heartbeat} (BOOTTIME age #{age}ms); scan: #{scan}."

      _ ->
        "Gatekeeper process and scan health are unknown until a comparable observation snapshot is readable."
    end
  end

  defp pr_summary(issue) do
    case Map.get(issue, :pr_data) do
      %{association: :none} ->
        "no verified PR association"

      %{association: {:scope_warning, _}} ->
        "PR scope warning"

      %{prs: prs} = summary when is_list(prs) ->
        verdicts = DashboardProjection.pr_verdicts(summary)
        "#{length(prs)} PR(s) · review #{verdicts.review_attention.value} · checks #{check_label(prs)}"

      _ ->
        "unknown"
    end
  end

  defp check_label(prs) do
    prs
    |> Enum.map(&(get_in(&1, [:checks, :state]) || Map.get(&1, :checks)))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.join(", ")
  end
end
