defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{
    DashboardConfig,
    DashboardGitHub,
    DashboardLinear,
    DashboardLinearAction,
    DashboardProjection,
    DashboardStore
  }

  alias SymphonyElixirWeb.Dashboard.{
    DetailComponents,
    MergingActionComponents,
    ProjectComponents,
    RuntimeComponents
  }

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    payload = load_payload()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:project_snapshot, project_snapshot(payload))
      |> assign(:dashboard_config, DashboardConfig.snapshot())
      |> assign(:action_scope, DashboardConfig.action_scope())
      |> assign(:merging_actions, %{})
      |> assign(:merging_confirmation, nil)
      |> assign(:filters, %{q: "", state: "all"})
      |> assign(:detail_issue, nil)
      |> assign(:detail_entry, nil)
      |> assign(:comment_page, 1)
      |> assign(:expanded_pr, nil)
      |> assign(:file_detail, nil)
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      :ok = DashboardStore.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters_from_params(params)

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:comment_page, page_from_params(params))
      |> assign_route(params)
      |> refresh_detail_assigns()

    if connected?(socket), do: request_linear_detail(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    payload = load_payload()

    {:noreply,
     socket
     |> assign(:payload, payload)
     |> assign(:project_snapshot, project_snapshot(payload))
     |> assign(:dashboard_config, DashboardConfig.snapshot())
     |> assign(:action_scope, DashboardConfig.action_scope())
     |> refresh_detail_assigns()
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("project-filter", params, socket) do
    filters = filters_from_params(params)
    {:noreply, push_patch(socket, to: list_url(filters))}
  end

  def handle_event("dashboard-refresh", _params, socket) do
    _ = DashboardStore.manual_refresh()
    {:noreply, socket}
  end

  def handle_event("merging-open", %{"issue-id" => issue_id}, socket) do
    case find_issue(socket.assigns.project_snapshot, issue_id) do
      %{state_name: "In Review", id: id} = issue ->
        confirmation = %{issue: issue, observed_state_id: issue_state_id(issue), phase: :ready, action_id: id}
        {:noreply, assign(socket, :merging_confirmation, confirmation)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("merging-submit", _params, %{assigns: %{merging_confirmation: %{issue: issue, observed_state_id: observed_state_id} = confirmation}} = socket) do
    submitting = %{confirmation | phase: :submitting}
    socket = assign(socket, :merging_confirmation, submitting)

    case action_submitter().(issue.id, observed_state_id) do
      {:ok, action} ->
        {:noreply,
         socket
         |> put_action(issue.id, action)
         |> assign(:merging_confirmation, %{submitting | phase: :waiting})
         |> request_fresh_project_read()}

      {:conflict, result} ->
        action = Map.get(result, :action, %{status: :conflict, outcome: :observed_state_changed})

        {:noreply,
         socket
         |> put_action(issue.id, action)
         |> assign(:merging_confirmation, %{submitting | phase: :conflict})
         |> request_fresh_project_read()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_action(issue.id, %{status: :failed, outcome: reason})
         |> assign(:merging_confirmation, %{submitting | phase: :failed})}
    end
  end

  def handle_event("merging-submit", _params, socket), do: {:noreply, socket}
  def handle_event("merging-close", _params, socket), do: {:noreply, assign(socket, :merging_confirmation, nil)}

  def handle_event("comments-page", %{"page" => raw_page}, socket) do
    page = raw_page |> parse_positive_int() |> max(1)
    {:noreply, assign(socket, :comment_page, page)}
  end

  def handle_event("load-pr-files", params, socket) do
    case verified_pr(socket.assigns.detail_issue, params) do
      {:ok, pr, page} ->
        key = {:github_files, pr.repository, pr.number, pr.head.sha, page}
        _ = DashboardStore.request_detail(key, fn -> DashboardGitHub.fetch_pr_files(pr, page) end)

        {:noreply,
         socket
         |> assign(:expanded_pr, key)
         |> assign(:file_detail, DashboardStore.detail_snapshot(key))
         |> refresh_detail_assigns()}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def terminate(_reason, _socket) do
    DashboardStore.unsubscribe()
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              AsyncSelf
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for your background coding workers.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <RuntimeComponents.overview payload={@payload} now={@now} />

        <RuntimeComponents.rate_limits rate_limits={@payload.rate_limits} />

        <RuntimeComponents.running_sessions payload={@payload} now={@now} />
        <RuntimeComponents.blocked_sessions payload={@payload} />
        <RuntimeComponents.retry_queue payload={@payload} />
      <% end %>

      <%= if @live_action == :detail do %>
        <p><.link class="issue-link" navigate={list_url(@filters)}>Back to project issues</.link></p>
        <%= if @detail_issue do %>
          <DetailComponents.issue_detail
            issue={@detail_issue}
            detail={detail_data(@detail_entry)}
            detail_status={detail_status(@detail_entry)}
            runtime={runtime_for_issue(@payload, @detail_issue.id)}
            pr_data={Map.get(@detail_issue, :pr_data)}
            gatekeeper={get_in(@project_snapshot, [:sources, :gatekeeper])}
            comment_page={@comment_page}
            expanded_pr={@expanded_pr}
            file_detail={detail_data(@file_detail)}
            action_scope={@action_scope}
            actions={@merging_actions}
          />
        <% else %>
          <section class="section-card"><p class="empty-state">Issue detail is unavailable in the current project cache. Return to the list or wait for its next successful refresh.</p></section>
        <% end %>
      <% else %>
        <ProjectComponents.projects_section snapshot={@project_snapshot} config={@dashboard_config} filters={@filters} action_scope={@action_scope} actions={@merging_actions} gatekeeper={get_in(@project_snapshot, [:sources, :gatekeeper])} />
      <% end %>
      <MergingActionComponents.confirmation_dialog confirmation={@merging_confirmation} gatekeeper={get_in(@project_snapshot, [:sources, :gatekeeper])} />
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp project_snapshot(payload) do
    snapshot = DashboardStore.snapshot()

    update_in(snapshot, [:sources, :linear], fn
      %{data: issues} = linear when is_list(issues) ->
        github = get_in(snapshot, [:sources, :github, :data]) || %{}

        issues =
          issues
          |> DashboardProjection.attach_runtime(payload)
          |> Enum.map(fn issue -> Map.put(issue, :pr_data, Map.get(github, Map.get(issue, :id))) end)

        %{linear | data: issues}

      other ->
        other
    end)
  end

  defp assign_route(socket, %{"identifier" => identifier}) do
    issue =
      socket.assigns.project_snapshot
      |> get_in([:sources, :linear, :data])
      |> List.wrap()
      |> Enum.find(&(Map.get(&1, :identifier) == identifier))

    socket
    |> assign(:detail_issue, issue)
    |> assign(:expanded_pr, nil)
    |> assign(:file_detail, nil)
  end

  defp assign_route(socket, _params), do: assign(socket, :detail_issue, nil)

  defp refresh_detail_assigns(%{assigns: %{detail_issue: %{id: id}}} = socket) do
    detail_entry = DashboardStore.detail_snapshot({:linear_issue, id})

    file_entry =
      if socket.assigns.expanded_pr,
        do: DashboardStore.detail_snapshot(socket.assigns.expanded_pr),
        else: nil

    socket |> assign(:detail_entry, detail_entry) |> assign(:file_detail, file_entry)
  end

  defp refresh_detail_assigns(socket), do: socket

  defp request_linear_detail(%{assigns: %{detail_issue: issue}} = socket) when is_map(issue) do
    _ = DashboardStore.request_detail({:linear_issue, issue.id}, fn -> DashboardLinear.fetch_issue_detail(issue) end)
    socket
  end

  defp request_linear_detail(socket), do: socket

  defp request_fresh_project_read(socket) do
    _ = DashboardStore.manual_refresh()
    socket
  end

  defp put_action(socket, issue_id, action), do: update(socket, :merging_actions, &Map.put(&1, issue_id, action))

  defp find_issue(snapshot, issue_id) do
    snapshot
    |> get_in([:sources, :linear, :data])
    |> List.wrap()
    |> Enum.find(&(Map.get(&1, :id) == issue_id))
  end

  defp issue_state_id(issue), do: Map.get(issue, :state_id) || Map.get(issue, "state_id")
  defp action_submitter, do: Endpoint.config(:linear_action_submitter) || (&DashboardLinearAction.submit/2)

  defp detail_data(%{data: data}), do: data
  defp detail_data(_), do: nil
  defp detail_status(%{status: status}), do: status
  defp detail_status(_), do: nil

  defp filters_from_params(params) do
    %{q: params |> Map.get("q", "") |> to_string() |> String.slice(0, 200), state: params |> Map.get("state", "all") |> to_string()}
  end

  defp page_from_params(params), do: params |> Map.get("comments_page", "1") |> parse_positive_int() |> max(1)
  defp parse_positive_int(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> 1
    end
  end

  defp parse_positive_int(_), do: 1
  defp list_url(filters), do: "/?" <> URI.encode_query(%{"q" => filters.q, "state" => filters.state})

  defp runtime_for_issue(payload, issue_id) do
    [:running, :retrying, :blocked]
    |> Enum.reduce(%{}, fn state, acc ->
      entries = payload |> Map.get(state, []) |> Enum.filter(&(Map.get(&1, :issue_id) == issue_id))
      if entries == [], do: acc, else: Map.put(acc, state, entries)
    end)
  end

  defp verified_pr(%{pr_data: %{prs: prs}}, %{"repository" => repository, "number" => number, "head" => head, "page" => page}) when is_list(prs) do
    with {number, ""} <- Integer.parse(number),
         page <- parse_positive_int(page),
         pr when not is_nil(pr) <- Enum.find(prs, &(Map.get(&1, :scope) == :valid and &1.repository == repository and &1.number == number and get_in(&1, [:head, :sha]) == head)) do
      {:ok, pr, page}
    else
      _ -> :error
    end
  end

  defp verified_pr(_, _), do: :error

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
