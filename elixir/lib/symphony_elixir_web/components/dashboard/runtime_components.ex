defmodule SymphonyElixirWeb.Dashboard.RuntimeComponents do
  @moduledoc "Stateless presentation components for existing runtime data."

  use Phoenix.Component

  attr(:payload, :map, required: true)
  attr(:now, DateTime, required: true)

  @spec overview(map()) :: Phoenix.LiveView.Rendered.t()
  def overview(assigns) do
    ~H"""
    <section class="metric-grid" id="runtime-overview">
      <article class="metric-card"><p class="metric-label">Running</p><p class="metric-value numeric"><%= @payload.counts.running %></p><p class="metric-detail">Active issue sessions in the current runtime.</p></article>
      <article class="metric-card"><p class="metric-label">Retrying</p><p class="metric-value numeric"><%= @payload.counts.retrying %></p><p class="metric-detail">Issues waiting for the next retry window.</p></article>
      <article class="metric-card"><p class="metric-label">Blocked</p><p class="metric-value numeric"><%= @payload.counts.blocked %></p><p class="metric-detail">Issues paused for operator input or approval.</p></article>
      <article class="metric-card"><p class="metric-label">Total tokens</p><p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p><p class="metric-detail numeric">In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %></p></article>
      <article class="metric-card"><p class="metric-label">Runtime</p><p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p><p class="metric-detail">Total Codex runtime across completed and active sessions.</p></article>
    </section>
    """
  end

  attr(:rate_limits, :any, required: true)

  @spec rate_limits(map()) :: Phoenix.LiveView.Rendered.t()
  def rate_limits(assigns) do
    ~H"""
    <section class="section-card" id="runtime-rate-limits">
      <div class="section-header"><div><h2 class="section-title">Rate limits</h2><p class="section-copy">Latest upstream rate-limit snapshot, when available.</p></div></div>
      <pre class="code-panel"><%= pretty_value(@rate_limits) %></pre>
    </section>
    """
  end

  attr(:payload, :map, required: true)
  attr(:now, DateTime, required: true)

  @spec running_sessions(map()) :: Phoenix.LiveView.Rendered.t()
  def running_sessions(assigns) do
    ~H"""
    <section class="section-card" id="runtime-running-sessions">
      <div class="section-header">
        <div>
          <h2 class="section-title">Running sessions</h2>
          <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
        </div>
      </div>

      <%= if @payload.running == [] do %>
        <p class="empty-state">No active sessions.</p>
      <% else %>
        <div class="table-wrap">
          <table class="data-table data-table-running">
            <colgroup>
              <col style="width: 12rem;" />
              <col style="width: 8rem;" />
              <col style="width: 7.5rem;" />
              <col style="width: 8.5rem;" />
              <col />
              <col style="width: 10rem;" />
            </colgroup>
            <thead>
              <tr><th>Issue</th><th>State</th><th>Session</th><th>Runtime / turns</th><th>Codex update</th><th>Tokens</th></tr>
            </thead>
            <tbody>
              <tr :for={entry <- @payload.running}>
                <td><div class="issue-stack"><.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} /><a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a></div></td>
                <td><span class={state_badge_class(entry.state)}><%= entry.state %></span></td>
                <td><.copy_session_id session_id={entry.session_id} /></td>
                <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                <td><.last_update entry={entry} /></td>
                <td><div class="token-stack numeric"><span>Total: <%= format_int(entry.tokens.total_tokens) %></span><span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span></div></td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </section>
    """
  end

  attr(:payload, :map, required: true)

  @spec blocked_sessions(map()) :: Phoenix.LiveView.Rendered.t()
  def blocked_sessions(assigns) do
    ~H"""
    <section class="section-card" id="runtime-blocked-sessions">
      <div class="section-header"><div><h2 class="section-title">Blocked sessions</h2><p class="section-copy">Issues paused because Codex requested operator input or approval.</p></div></div>
      <%= if @payload.blocked == [] do %>
        <p class="empty-state">No blocked sessions.</p>
      <% else %>
        <div class="table-wrap">
          <table class="data-table" style="min-width: 760px;">
            <thead><tr><th>Issue</th><th>State</th><th>Session</th><th>Blocked at</th><th>Last update</th><th>Error</th></tr></thead>
            <tbody>
              <tr :for={entry <- @payload.blocked}>
                <td><div class="issue-stack"><.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} /><a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a></div></td>
                <td><span class={state_badge_class(entry.state || "Blocked")}><%= entry.state || "Blocked" %></span></td>
                <td><.copy_session_id session_id={entry.session_id} /></td>
                <td class="mono"><%= entry.blocked_at || "n/a" %></td>
                <td><.last_update entry={entry} /></td>
                <td><%= entry.error || "n/a" %></td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </section>
    """
  end

  attr(:payload, :map, required: true)

  @spec retry_queue(map()) :: Phoenix.LiveView.Rendered.t()
  def retry_queue(assigns) do
    ~H"""
    <section class="section-card" id="runtime-retry-queue">
      <div class="section-header"><div><h2 class="section-title">Retry queue</h2><p class="section-copy">Issues waiting for the next retry window.</p></div></div>
      <%= if @payload.retrying == [] do %>
        <p class="empty-state">No issues are currently backing off.</p>
      <% else %>
        <div class="table-wrap">
          <table class="data-table" style="min-width: 680px;">
            <thead><tr><th>Issue</th><th>Attempt</th><th>Due at</th><th>Error</th></tr></thead>
            <tbody>
              <tr :for={entry <- @payload.retrying}>
                <td><div class="issue-stack"><.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} /><a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a></div></td>
                <td><%= entry.attempt %></td>
                <td class="mono"><%= entry.due_at || "n/a" %></td>
                <td><%= entry.error || "n/a" %></td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </section>
    """
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a class="issue-id issue-id-link" href={@href} target="_blank" rel="noopener noreferrer" aria-label={"Open #{@identifier} in the issue tracker"}><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  attr(:session_id, :string, default: nil)

  defp copy_session_id(assigns) do
    ~H"""
    <%= if @session_id do %>
      <button type="button" class="subtle-button" data-label="Copy ID" data-copy={@session_id} onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);">Copy ID</button>
    <% else %>
      <span class="muted">n/a</span>
    <% end %>
    """
  end

  attr(:entry, :map, required: true)

  defp last_update(assigns) do
    ~H"""
    <div class="detail-stack">
      <span class="event-text" title={@entry.last_message || to_string(@entry.last_event || "n/a")}><%= @entry.last_message || to_string(@entry.last_event || "n/a") %></span>
      <span class="muted event-meta"><%= @entry.last_event || "n/a" %><%= if @entry.last_event_at do %> · <span class="mono numeric"><%= @entry.last_event_at %></span><% end %></span>
    </div>
    """
  end

  defp total_runtime_seconds(payload, now) do
    (payload.codex_totals.seconds_running || 0) +
      Enum.reduce(payload.running, 0, fn entry, total -> total + runtime_seconds(entry.started_at, now) end)
  end

  defp runtime_seconds(%DateTime{} = started_at, now), do: DateTime.diff(now, started_at, :second)

  defp runtime_seconds(started_at, now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _} -> runtime_seconds(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds(_, _), do: 0
  defp format_runtime_seconds(seconds), do: "#{div(max(trunc(seconds), 0), 60)}m #{rem(max(trunc(seconds), 0), 60)}s"
  defp format_int(value) when is_integer(value), do: value |> Integer.to_string() |> String.reverse() |> String.replace(~r/.{3}(?=.)/, "\\0,") |> String.reverse()
  defp format_int(_), do: "n/a"
  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0,
    do: "#{format_runtime_seconds(runtime_seconds(started_at, now))} / #{turn_count}"

  defp format_runtime_and_turns(started_at, _turn_count, now), do: format_runtime_seconds(runtime_seconds(started_at, now))

  defp external_issue_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" -> url
      _ -> nil
    end
  end

  defp external_issue_url(_), do: nil

  defp state_badge_class(state) do
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "state-badge state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "state-badge state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "state-badge state-badge-warning"
      true -> "state-badge"
    end
  end
end
