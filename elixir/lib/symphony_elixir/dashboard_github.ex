defmodule SymphonyElixir.DashboardGitHub do
  @moduledoc "Read-only GitHub adapter for the dashboard."

  alias SymphonyElixir.DashboardConfig

  @type association ::
          {:ok, %{repository: String.t(), number: pos_integer(), url: String.t()}}
          | {:error, :invalid_pr_url | :scope_mismatch}
  @type request_fun :: (String.t(), String.t(), map(), term() -> {:ok, term()} | {:error, term()})
  @files_per_page 20
  @max_diff_lines 500
  @max_diff_bytes 262_144

  @spec validate_pr_url(String.t() | nil, String.t(), String.t()) :: association()
  def validate_pr_url(url, repository, target_branch)
      when is_binary(url) and is_binary(repository) and is_binary(target_branch) do
    with %URI{scheme: "https", host: "github.com", path: path} <- URI.parse(String.trim(url)),
         [_, owner, repo, number] <- Regex.run(~r|^/([^/]+)/([^/]+)/pull/(\d+)/?$|, path || ""),
         true <- String.downcase(owner <> "/" <> repo) == String.downcase(repository),
         {number, ""} <- Integer.parse(number),
         true <- number > 0,
         true <- String.trim(target_branch) != "" do
      {:ok, %{repository: String.downcase(repository), number: number, url: "https://github.com/#{owner}/#{repo}/pull/#{number}"}}
    else
      false -> {:error, :scope_mismatch}
      _ -> {:error, :invalid_pr_url}
    end
  end

  def validate_pr_url(_, _, _), do: {:error, :invalid_pr_url}

  @doc "Returns validated explicit PR URLs from Linear attachments, description text, and comments."
  @spec association_candidates(map(), String.t(), String.t()) :: %{valid: [map()], invalid: [atom()]}
  def association_candidates(issue, repository, target_branch) when is_map(issue) do
    urls =
      attachment_urls(issue) ++
        explicit_pr_urls(Map.get(issue, :description) || Map.get(issue, "description") || "") ++
        comment_urls(issue)

    candidates =
      Enum.reduce(Enum.uniq(urls), %{valid: [], invalid: []}, fn url, acc ->
        case validate_pr_url(url, repository, target_branch) do
          {:ok, candidate} -> %{acc | valid: [candidate | Map.fetch!(acc, :valid)]}
          {:error, reason} -> %{acc | invalid: [reason | Map.fetch!(acc, :invalid)]}
        end
      end)

    %{
      candidates
      | valid: Map.fetch!(candidates, :valid) |> Enum.uniq_by(fn pr -> {pr.repository, pr.number} end) |> Enum.reverse(),
        invalid: Enum.uniq(Map.fetch!(candidates, :invalid))
    }
  end

  @spec fetch_project_summaries([map()]) :: {:ok, map()} | {:error, term()}
  def fetch_project_summaries(issues) when is_list(issues) do
    with {:ok, config} <- DashboardConfig.snapshot() do
      fetch_project_summaries_for_test(issues, config, &github_request/4)
    end
  end

  @doc "Reads one independent page of PR file metadata and bounded text patches."
  @spec fetch_pr_files(map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def fetch_pr_files(%{repository: repository, number: number, head: %{sha: head_sha}} = pr, page)
      when is_binary(repository) and is_integer(number) and number > 0 and is_binary(head_sha) and page > 0 do
    fetch_pr_files_for_test(pr, page, &github_request/4)
  end

  def fetch_pr_files(_, _), do: {:error, :github_pr_file_scope_missing}

  @doc false
  @spec fetch_pr_files_for_test(map(), pos_integer(), request_fun()) ::
          {:ok, map()} | {:error, term()}
  def fetch_pr_files_for_test(%{repository: repository, number: number, head: %{sha: head_sha}}, page, request_fun)
      when is_binary(repository) and is_integer(number) and number > 0 and
             is_binary(head_sha) and page > 0 and is_function(request_fun, 4) do
    path = "/repos/#{repository}/pulls/#{number}/files"

    with {:ok, payload} <- request_fun.("GET", path, %{"per_page" => @files_per_page, "page" => page}, nil),
         {:ok, files, has_next?} <- decode_file_page(payload),
         bounded <- bounded_diff(files, @files_per_page, @max_diff_lines, @max_diff_bytes) do
      {:ok,
       %{
         repository: repository,
         number: number,
         head_sha: head_sha,
         page: page,
         files: bounded.files,
         has_next?: has_next?,
         truncated?: bounded.truncated?,
         budgets: %{files: @files_per_page, lines: @max_diff_lines, bytes: @max_diff_bytes}
       }}
    end
  end

  @doc false
  @spec fetch_project_summaries_for_test([map()], DashboardConfig.snapshot(), request_fun()) ::
          {:ok, map()} | {:error, term()}
  def fetch_project_summaries_for_test(issues, config, request_fun)
      when is_list(issues) and is_map(config) and is_function(request_fun, 4) do
    Enum.reduce_while(issues, {:ok, %{}}, fn issue, {:ok, acc} ->
      case fetch_issue_summary_for_test(issue, config, request_fun) do
        {:ok, summary} -> {:cont, {:ok, Map.put(acc, issue_id(issue), summary)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  @spec fetch_issue_summary_for_test(map(), DashboardConfig.snapshot(), request_fun()) ::
          {:ok, map()} | {:error, term()}
  def fetch_issue_summary_for_test(issue, config, request_fun)
      when is_map(issue) and is_map(config) and is_function(request_fun, 4) do
    candidates =
      association_candidates(issue, config.repository, config.target_branch)

    results = Enum.map(candidates.valid, &fetch_pr(&1, config, request_fun))

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        prs = Enum.map(results, fn {:ok, pr} -> pr end)
        {:ok, %{prs: prs, association: association_state(prs, candidates.invalid), complete?: true}}
    end
  end

  @spec bounded_diff([map()], non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          %{files: [map()], truncated?: boolean()}
  def bounded_diff(files, max_files \\ 20, max_lines \\ 500, max_bytes \\ 262_144) when is_list(files) do
    {selected, _lines, _bytes, exhausted} =
      Enum.reduce_while(files, {[], 0, 0, false}, fn file, {acc, lines, bytes, _} ->
        patch = Map.get(file, :patch) || Map.get(file, "patch") || ""
        patch_lines = patch |> String.split("\n") |> length()
        patch_bytes = byte_size(patch)

        if length(acc) >= max_files or lines + patch_lines > max_lines or bytes + patch_bytes > max_bytes do
          {:halt, {acc, lines, bytes, true}}
        else
          {:cont, {[file | acc], lines + patch_lines, bytes + patch_bytes, false}}
        end
      end)

    selected = Enum.reverse(selected)

    %{
      files: selected,
      truncated?:
        exhausted or length(selected) < length(files) or
          budget_reached?(selected, max_files, max_lines, max_bytes)
    }
  end

  defp fetch_pr(candidate, config, request_fun) do
    with {:ok, payload} <- request_fun.("GET", "/repos/#{candidate.repository}/pulls/#{candidate.number}", %{}, nil),
         {:ok, pr} <- normalize_pr(payload, candidate, config),
         {:ok, rules} <- required_rules(pr, config, request_fun),
         {:ok, checks} <- checks_for_head(pr, rules, config, request_fun),
         {:ok, reviews} <- paged_reviews(pr, config, request_fun),
         {:ok, threads} <- paged_threads(pr, config, request_fun) do
      {:ok, Map.merge(pr, %{required_rules: rules, checks: checks, reviews: reviews, threads: threads})}
    end
  end

  defp normalize_pr(payload, candidate, config) when is_map(payload) do
    base = Map.get(payload, "base") || %{}
    head = Map.get(payload, "head") || %{}
    repo = get_in(payload, ["base", "repo", "full_name"]) || candidate.repository

    cond do
      String.downcase(to_string(repo)) != candidate.repository ->
        {:ok, scope_warning(candidate, :repository_mismatch)}

      Map.get(base, "ref") != config.target_branch ->
        {:ok, scope_warning(candidate, :base_mismatch)}

      not valid_sha?(Map.get(head, "sha")) ->
        {:error, :github_pr_missing_head_sha}

      true ->
        {:ok,
         %{
           repository: candidate.repository,
           number: candidate.number,
           url: Map.get(payload, "html_url") || candidate.url,
           state: normalize_state(Map.get(payload, "state"), Map.get(payload, "merged")),
           draft?: Map.get(payload, "draft") == true,
           base: %{ref: Map.get(base, "ref"), sha: Map.get(base, "sha")},
           head: %{ref: Map.get(head, "ref"), sha: Map.get(head, "sha")},
           scope: :valid
         }}
    end
  end

  defp normalize_pr(_, _, _), do: {:error, :github_pr_payload}

  defp scope_warning(candidate, reason),
    do: %{
      repository: candidate.repository,
      number: candidate.number,
      url: candidate.url,
      state: :unknown,
      draft?: false,
      scope: {:warning, reason},
      checks: :unknown,
      reviews: %{decision: :unknown, complete?: false},
      threads: %{unresolved: :unknown, complete?: false}
    }

  # Query failure is unknown.  It is never interpreted as "no required checks".
  defp required_rules(%{scope: {:warning, _}}, _config, _request_fun), do: {:ok, %{known?: false, names: []}}

  defp required_rules(pr, config, request_fun) do
    path = "/repos/#{config.repository}/branches/#{URI.encode(pr.base.ref)}/protection/required_status_checks"

    case request_fun.("GET", path, %{}, nil) do
      {:ok, %{"contexts" => contexts}} when is_list(contexts) ->
        {:ok, %{known?: true, names: Enum.filter(contexts, &is_binary/1)}}

      {:ok, %{"checks" => checks}} when is_list(checks) ->
        names = checks |> Enum.map(&(Map.get(&1, "context") || Map.get(&1, "name"))) |> Enum.filter(&is_binary/1)
        {:ok, %{known?: true, names: names}}

      {:ok, %{known?: known?, names: names}} when is_boolean(known?) and is_list(names) ->
        {:ok, %{known?: known?, names: names}}

      {:ok, _} ->
        {:ok, %{known?: false, names: []}}

      {:error, reason} ->
        {:error, {:required_rules_unavailable, reason}}
    end
  end

  defp checks_for_head(%{scope: {:warning, _}}, _rules, _config, _request_fun), do: {:ok, :unknown}
  defp checks_for_head(_pr, %{known?: false}, _config, _request_fun), do: {:ok, :unknown}

  defp checks_for_head(pr, rules, config, request_fun) do
    sha = pr.head.sha

    with {:ok, runs} <- request_fun.("GET", "/repos/#{config.repository}/commits/#{sha}/check-runs", %{"per_page" => 100}, nil),
         {:ok, statuses} <- request_fun.("GET", "/repos/#{config.repository}/commits/#{sha}/status", %{}, nil) do
      {:ok, summarize_checks(Map.get(runs, "check_runs", []) ++ Map.get(statuses, "statuses", []), rules.names, sha)}
    end
  end

  defp summarize_checks(_items, [], sha), do: %{state: :none, head_sha: sha, required: []}

  defp summarize_checks(items, names, sha) do
    selected = Enum.filter(items, fn item -> (Map.get(item, "name") || Map.get(item, "context")) in names end)

    state =
      cond do
        length(selected) < length(names) -> :pending
        Enum.any?(selected, &failed_check?/1) -> :failed
        Enum.any?(selected, &pending_check?/1) -> :pending
        true -> :passed
      end

    %{state: state, head_sha: sha, required: names}
  end

  defp paged_reviews(%{scope: {:warning, _}}, _config, _request_fun), do: {:ok, %{decision: :unknown, complete?: false}}

  defp paged_reviews(pr, config, request_fun) do
    with {:ok, reviews} <- rest_pages("/repos/#{config.repository}/pulls/#{pr.number}/reviews", request_fun), do: {:ok, review_summary(reviews, pr.head.sha)}
  end

  defp paged_threads(%{scope: {:warning, _}}, _config, _request_fun), do: {:ok, %{unresolved: :unknown, complete?: false}}

  defp paged_threads(pr, config, request_fun) do
    query = %{query: review_threads_query(), variables: %{owner: owner(config.repository), repo: repo(config.repository), number: pr.number, after: nil}}
    do_thread_pages(query, request_fun, [], [])
  end

  defp do_thread_pages(query, request_fun, acc, seen) do
    with {:ok, payload} <- request_fun.("POST", "/graphql", %{}, query), {:ok, nodes, page} <- decode_threads(payload) do
      case next_cursor(page, seen) do
        :done ->
          {:ok, %{unresolved: Enum.count(acc ++ nodes, &(Map.get(&1, "isResolved") == false)), complete?: true}}

        {:next, cursor} ->
          next_query = put_in(query, [:variables, :after], cursor)
          do_thread_pages(next_query, request_fun, acc ++ nodes, [cursor | seen])

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp rest_pages(path, request_fun), do: rest_pages(path, request_fun, 1, [])

  defp rest_pages(path, request_fun, page, acc) when page <= 20 do
    case request_fun.("GET", path, %{"per_page" => 100, "page" => page}, nil) do
      {:ok, payload} when is_list(payload) ->
        if length(payload) < 100,
          do: {:ok, acc ++ payload},
          else: rest_pages(path, request_fun, page + 1, acc ++ payload)

      {:ok, _} ->
        {:error, :github_reviews_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rest_pages(_, _, _, _), do: {:error, :github_page_limit}

  defp review_summary(reviews, head_sha) do
    latest =
      reviews
      |> Enum.filter(&(Map.get(&1, "state") in ["APPROVED", "CHANGES_REQUESTED"]))
      |> Enum.reject(&Map.get(&1, "dismissed_at"))
      |> Enum.group_by(&(get_in(&1, ["user", "id"]) || get_in(&1, ["user", "login"])))
      |> Map.values()
      |> Enum.map(&Enum.max_by(&1, fn r -> {Map.get(r, "submitted_at") || "", Map.get(r, "id") || 0} end))

    %{decision: if(Enum.any?(latest, &(Map.get(&1, "state") == "CHANGES_REQUESTED")), do: :changes_requested, else: :none), complete?: true, head_sha: head_sha, fallback?: true, reviews: latest}
  end

  defp association_state([], []), do: :none
  defp association_state([], invalid), do: {:scope_warning, invalid}
  defp association_state(_prs, []), do: :verified
  defp association_state(_prs, invalid), do: {:verified_with_warnings, invalid}
  defp attachment_urls(issue), do: issue |> Map.get(:attachments, Map.get(issue, "attachments", [])) |> List.wrap() |> Enum.map(&(Map.get(&1, :url) || Map.get(&1, "url"))) |> Enum.filter(&is_binary/1)
  defp comment_urls(issue), do: issue |> Map.get(:comments, Map.get(issue, "comments", [])) |> List.wrap() |> Enum.flat_map(&explicit_pr_urls(Map.get(&1, :body) || Map.get(&1, "body") || ""))
  defp explicit_pr_urls(text), do: Regex.scan(~r|https://github\.com/[^\s)>]+/[^\s)>]+/pull/\d+/?|, text) |> List.flatten()
  defp issue_id(issue), do: Map.get(issue, :id) || Map.get(issue, "id")
  defp decode_file_page(files) when is_list(files), do: {:ok, Enum.map(files, &normalize_file/1), length(files) == @files_per_page}
  defp decode_file_page(%{"files" => files, "has_next" => has_next}) when is_list(files) and is_boolean(has_next), do: {:ok, Enum.map(files, &normalize_file/1), has_next}
  defp decode_file_page(_), do: {:error, :github_pr_files_payload}

  defp normalize_file(file) when is_map(file), do: file |> file_values() |> Map.put(:patch_status, patch_status(file_value(file, "patch")))

  defp normalize_file(_), do: %{filename: "unknown", status: "unknown", patch: nil, patch_status: :unavailable}

  defp file_values(file) do
    patch = file_value(file, "patch")

    %{
      filename: file_value(file, "filename") || "unknown",
      status: file_value(file, "status") || "unknown",
      additions: file_value(file, "additions"),
      deletions: file_value(file, "deletions"),
      changes: file_value(file, "changes"),
      patch: patch
    }
  end

  defp file_value(file, "filename"), do: Map.get(file, "filename") || Map.get(file, :filename)
  defp file_value(file, "status"), do: Map.get(file, "status") || Map.get(file, :status)
  defp file_value(file, "additions"), do: Map.get(file, "additions") || Map.get(file, :additions)
  defp file_value(file, "deletions"), do: Map.get(file, "deletions") || Map.get(file, :deletions)
  defp file_value(file, "changes"), do: Map.get(file, "changes") || Map.get(file, :changes)
  defp file_value(file, "patch"), do: Map.get(file, "patch") || Map.get(file, :patch)
  defp patch_status(patch) when is_binary(patch), do: :text
  defp patch_status(_), do: :unavailable

  defp budget_reached?(files, max_files, max_lines, max_bytes) do
    patches = Enum.map(files, &(Map.get(&1, :patch) || ""))

    length(files) >= max_files or
      Enum.reduce(patches, 0, fn patch, acc -> acc + length(String.split(patch, "\n")) end) >= max_lines or
      Enum.reduce(patches, 0, fn patch, acc -> acc + byte_size(patch) end) >= max_bytes
  end

  defp valid_sha?(sha), do: is_binary(sha) and String.trim(sha) != ""
  defp normalize_state("open", _), do: :open
  defp normalize_state("closed", true), do: :merged
  defp normalize_state("closed", _), do: :closed
  defp normalize_state(_, _), do: :unknown
  defp failed_check?(item), do: Map.get(item, "conclusion") not in [nil, "success", "neutral", "skipped"] or Map.get(item, "state") in ["failure", "error"]
  defp pending_check?(item), do: Map.get(item, "status") not in [nil, "completed"] or Map.get(item, "state") in ["pending", "expected"]
  defp owner(repository), do: repository |> String.split("/", parts: 2) |> hd()
  defp repo(repository), do: repository |> String.split("/", parts: 2) |> List.last()

  defp review_threads_query,
    do:
      "query($owner:String!,$repo:String!,$number:Int!,$after:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100,after:$after){nodes{isResolved} pageInfo{hasNextPage endCursor}}}}}"

  defp decode_threads(%{"data" => %{"repository" => %{"pullRequest" => %{"reviewThreads" => %{"nodes" => nodes, "pageInfo" => page}}}}}) when is_list(nodes), do: {:ok, nodes, page}
  defp decode_threads(_), do: {:error, :github_threads_payload}
  defp next_cursor(%{"hasNextPage" => false}, _), do: :done

  defp next_cursor(%{"hasNextPage" => true, "endCursor" => cursor}, seen) when is_binary(cursor),
    do: if(cursor in seen, do: {:error, :github_missing_or_repeated_cursor}, else: {:next, cursor})

  defp next_cursor(%{"hasNextPage" => true}, _), do: {:error, :github_missing_or_repeated_cursor}
  defp next_cursor(_, _), do: {:error, :github_threads_page_info}

  defp github_request(method, path, params, body) do
    token = System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")

    if is_binary(token) and token != "" do
      opts = [
        method: String.downcase(method) |> String.to_atom(),
        url: "https://api.github.com" <> path,
        params: params,
        headers: [{"authorization", "Bearer " <> token}, {"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}]
      ]

      opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

      case Req.request(opts) do
        {:ok, response} when response.status in 200..299 -> {:ok, response.body}
        {:ok, response} -> {:error, {:github_api_status, response.status}}
        {:error, reason} -> {:error, {:github_api_request, reason}}
      end
    else
      {:error, :missing_github_token}
    end
  end
end
