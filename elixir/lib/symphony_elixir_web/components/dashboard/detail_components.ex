defmodule SymphonyElixirWeb.Dashboard.DetailComponents do
  @moduledoc "Pure, escaped presentation components for read-only issue details."

  use Phoenix.Component

  alias SymphonyElixir.DashboardProjection
  alias SymphonyElixirWeb.Dashboard.MergingActionComponents

  attr(:issue, :map, required: true)
  attr(:detail, :any, required: true)
  attr(:detail_status, :any, required: true)
  attr(:runtime, :map, required: true)
  attr(:pr_data, :any, required: true)
  attr(:gatekeeper, :any, required: true)
  attr(:comment_page, :integer, required: true)
  attr(:expanded_pr, :any, required: true)
  attr(:file_detail, :any, required: true)
  attr(:action_scope, :any, default: {:error, :action_unavailable})
  attr(:actions, :map, default: %{})

  @spec issue_detail(map()) :: Phoenix.LiveView.Rendered.t()
  def issue_detail(assigns) do
    assigns =
      assigns
      |> assign(:body, detail_value(assigns.detail, :description, ""))
      |> assign(:gates, DashboardProjection.parse_start_gate_details(detail_value(assigns.detail, :description, nil)))
      |> assign(:comments, detail_value(assigns.detail, :comments, []))
      |> assign(:workpads, detail_value(assigns.detail, :workpads, []))
      |> assign(:dependencies, detail_value(assigns.detail, :dependencies, []))

    ~H"""
    <section id="issue-detail" class="issue-detail">
      <div class="section-header">
        <div>
          <p class="eyebrow">Read-only issue detail</p>
          <h2 class="section-title"><%= value(@issue, :identifier) %> · <%= value(@issue, :title) %></h2>
          <p class="section-copy">Linear detail cache: <%= detail_status(@detail_status) %></p>
        </div>
        <a :if={linear_url(value(@issue, :url))} class="issue-link" href={linear_url(value(@issue, :url))} target="_blank" rel="noopener noreferrer">Open in Linear</a>
      </div>

      <section class="section-card detail-panel">
        <h3 class="section-title">Requirements and acceptance</h3>
        <%= if @detail == nil do %>
          <p class="empty-state">Loading description and complete comment history on demand.</p>
        <% else %>
          <p class="source-status">Description source: Linear issue description. Displayed as plain text.</p>
          <pre class="detail-text"><%= @body %></pre>
          <h4>Codex Workpad candidates</h4>
          <p class="source-status">
            Comment resolution is unknown: this Linear schema does not expose <code>resolved</code>, so no candidate is treated as the sole active workpad.
          </p>
          <%= if @workpads == [] do %>
            <p class="empty-state">No marker candidate found in the complete returned comments; active/resolved status remains unknown.</p>
          <% else %>
            <p :if={length(@workpads) > 1} class="error-copy">Ambiguous: multiple marker candidates are retained in stable newest-first order.</p>
            <article :for={workpad <- @workpads} class="detail-item">
              <p><strong>Candidate</strong> · updated <%= value(workpad, :updated_at) %> · resolution unknown</p>
              <a :if={linear_url(value(workpad, :url))} class="issue-link" href={linear_url(value(workpad, :url))} target="_blank" rel="noopener noreferrer">Open source comment</a>
              <pre class="detail-text"><%= value(workpad, :body) %></pre>
            </article>
          <% end %>
          <h4>Comments</h4>
          <p class="source-status">Complete pagination is required before comments are published. Page <%= @comment_page %>.</p>
          <article :for={comment <- comment_page(@comments, @comment_page)} class="detail-item">
            <p>Created <%= value(comment, :created_at) %> · updated <%= value(comment, :updated_at) %></p>
            <a :if={linear_url(value(comment, :url))} class="issue-link" href={linear_url(value(comment, :url))} target="_blank" rel="noopener noreferrer">Open source comment</a>
            <pre class="detail-text"><%= value(comment, :body) %></pre>
          </article>
          <div class="detail-actions">
            <button :if={@comment_page > 1} type="button" class="subtle-button" phx-click="comments-page" phx-value-page={@comment_page - 1}>Previous comments</button>
            <button :if={length(@comments) > @comment_page * 10} type="button" class="subtle-button" phx-click="comments-page" phx-value-page={@comment_page + 1}>Next comments</button>
          </div>
        <% end %>
      </section>

      <section class="section-card detail-panel">
        <h3 class="section-title">Dependencies and missing information</h3>
        <p class="source-status">Start Gate is parsed only from the level-two <code>Start Gate</code> description section. Checkbox state never replaces dependency state.</p>
        <h4>Human gates</h4>
        <p :for={gate <- @gates.human}><%= if gate.checked?, do: "[x]", else: "[ ]" %> human: <%= gate.text %></p>
        <h4>Dependency gates</h4>
        <p :for={gate <- @gates.dependencies}>
          <%= if gate.checked?, do: "[x]", else: "[ ]" %> dep:<%= gate.identifier %> <%= gate.text %> · actual state: <%= dependency_state(@dependencies, gate.identifier) %>
        </p>
        <p :for={raw <- @gates.unknown} class="source-status">Unknown Start Gate format (kept verbatim): <%= raw %></p>
        <h4>Upstream dependencies</h4>
        <p :if={@detail != nil and @dependencies == []} class="empty-state">No upstream blocker relation in the complete returned relation pages.</p>
        <p :for={dependency <- @dependencies}>
          <a :if={linear_url(value(dependency, :url))} class="issue-link" href={linear_url(value(dependency, :url))} target="_blank" rel="noopener noreferrer"><%= value(dependency, :identifier) %></a>
          <%= value(dependency, :title) %> · actual state: <%= get_in(dependency, [:state, "name"]) || "unknown" %>
        </p>
      </section>

      <section class="section-card detail-panel">
        <h3 class="section-title">Runtime</h3>
        <p>Current runtime state: <strong><%= value(@issue, :runtime_state) %></strong>. It is independent from Linear state.</p>
        <p :if={@runtime == %{}}>No runtime session data is available for this issue.</p>
        <pre :if={@runtime != %{}} class="detail-text"><%= inspect(@runtime, pretty: true, limit: 20) %></pre>
        <p class="source-status"><%= gatekeeper_health(@gatekeeper) %></p>
      </section>

      <section class="section-card detail-panel">
        <h3 class="section-title">Merging</h3>
        <MergingActionComponents.action_control issue={@issue} action_scope={@action_scope} actions={@actions} gatekeeper={@gatekeeper} />
      </section>

      <section class="section-card detail-panel">
        <h3 class="section-title">PRs and changes</h3>
        <%= if is_map(@pr_data) and is_list(@pr_data[:prs]) do %>
          <article :for={pr <- @pr_data.prs} class="detail-item">
            <p>PR #<%= pr.number %> · <%= pr.state %> · head <code><%= get_in(pr, [:head, :sha]) || "unknown" %></code></p>
            <a :if={github_url(pr.url)} class="issue-link" href={github_url(pr.url)} target="_blank" rel="noopener noreferrer">Open on GitHub</a>
            <%= if pr.scope == :valid and is_binary(get_in(pr, [:head, :sha])) do %>
              <button type="button" class="subtle-button" phx-click="load-pr-files" phx-value-repository={pr.repository} phx-value-number={pr.number} phx-value-head={pr.head.sha} phx-value-page="1">Load files and bounded diff</button>
            <% else %>
              <p class="source-status">Files are unknown because this PR is outside the verified scope.</p>
            <% end %>
          </article>
        <% else %>
          <p class="empty-state">PR summary is unavailable or has no verified association.</p>
        <% end %>
        <.file_page file_detail={@file_detail} expanded_pr={@expanded_pr} />
      </section>
    </section>
    """
  end

  attr(:file_detail, :any, required: true)
  attr(:expanded_pr, :any, required: true)

  defp file_page(assigns) do
    ~H"""
    <%= if @expanded_pr != nil and @file_detail == nil do %>
      <p class="empty-state">Loading this independent file page.</p>
    <% end %>
    <%= if is_map(@file_detail) do %>
      <p class="source-status">Files page <%= @file_detail.page %> · head SHA <code><%= @file_detail.head_sha %></code>. Text diff limits: <%= @file_detail.budgets.files %> files, <%= @file_detail.budgets.lines %> lines, <%= @file_detail.budgets.bytes %> bytes.</p>
      <p :if={@file_detail.truncated?} class="error-copy">Diff is truncated at a safety budget or page boundary; use the GitHub control above for complete content.</p>
      <article :for={file <- @file_detail.files} class="detail-item">
        <p><strong><%= file.filename %></strong> · <%= file.status %> · +<%= file.additions || "?" %> / -<%= file.deletions || "?" %></p>
        <%= if file.patch_status == :text do %>
          <pre class="detail-text"><%= file.patch %></pre>
        <% else %>
          <p class="source-status">Binary, large, or patch-unavailable file: metadata only; no complete diff is claimed.</p>
        <% end %>
      </article>
      <div class="detail-actions">
        <button :if={@file_detail.page > 1} type="button" class="subtle-button" phx-click="load-pr-files" phx-value-repository={@file_detail.repository} phx-value-number={@file_detail.number} phx-value-head={@file_detail.head_sha} phx-value-page={@file_detail.page - 1}>Previous files</button>
        <button :if={@file_detail.has_next?} type="button" class="subtle-button" phx-click="load-pr-files" phx-value-repository={@file_detail.repository} phx-value-number={@file_detail.number} phx-value-head={@file_detail.head_sha} phx-value-page={@file_detail.page + 1}>Next files</button>
      </div>
    <% end %>
    """
  end

  defp detail_value(detail, key, default) when is_map(detail), do: Map.get(detail, key, default)
  defp detail_value(_, _, default), do: default
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key)) || "unknown"
  defp comment_page(comments, page), do: comments |> Enum.drop((page - 1) * 10) |> Enum.take(10)
  defp dependency_state(dependencies, identifier), do: Enum.find_value(dependencies, "unknown", fn dep -> if dep.identifier == identifier, do: get_in(dep, [:state, "name"]) || "unknown" end)

  defp linear_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when host in ["linear.app", "www.linear.app"] -> url
      _ -> nil
    end
  end

  defp linear_url(_), do: nil

  defp github_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "github.com"} -> url
      _ -> nil
    end
  end

  defp github_url(_), do: nil

  defp detail_status(nil), do: "empty · unknown · idle"
  defp detail_status(status), do: "#{status.availability} · #{status.freshness} · #{status.refresh}" <> if(status.last_error, do: " · last read error recorded", else: "")

  defp gatekeeper_health(%{data: %{health: %{heartbeat: heartbeat, scan: scan, heartbeat_age_ms: age}}, status: status}) do
    "Gatekeeper observation cache: #{status.availability} · #{status.freshness}; process heartbeat #{heartbeat} (BOOTTIME age #{age}ms); scan #{scan}."
  end

  defp gatekeeper_health(%{status: status}) do
    "Gatekeeper observation: #{status.availability} · #{status.freshness}; no comparable process or scan health."
  end

  defp gatekeeper_health(_), do: "Gatekeeper observation is unknown; no comparable read-only heartbeat snapshot is available."
end
