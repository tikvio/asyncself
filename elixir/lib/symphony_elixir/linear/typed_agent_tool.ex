defmodule SymphonyElixir.Linear.TypedAgentTool do
  @moduledoc "Fixed, issue-scoped Linear operations exposed to Codex."

  alias SymphonyElixir.DeliveryGate
  alias SymphonyElixir.Linear.Client

  @issue_fields "id identifier title description state { name } url labels { nodes { name } }"

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      spec("linear_get_issue", "Read the current Linear issue.", %{}),
      spec("linear_get_issue_context", "Read the current issue, workpad comments, workflow states, and dependency fields in one request.", %{}),
      spec("linear_get_comments", "Read the current issue workpad comments.", %{}),
      spec("linear_get_states", "List the current issue team's workflow states.", %{}),
      spec("linear_update_issue_state", "Move the current issue to a named state.", %{"state" => string_field()}, ["state"]),
      spec("linear_update_issue_description", "Replace the current issue description.", %{"description" => string_field()}, ["description"]),
      spec("linear_add_comment", "Add a comment to the current issue.", %{"body" => string_field()}, ["body"]),
      spec("linear_update_comment", "Edit an existing comment on the current issue.", %{"comment_id" => string_field(), "body" => string_field()}, ["comment_id", "body"])
    ]
  end

  @spec execute(String.t(), term(), keyword()) :: map()
  def execute(tool, arguments, opts) when is_map(arguments) do
    case bound_issue_id(opts) do
      {:ok, issue_id} -> execute_bound(operation(tool, arguments, issue_id), opts)
      {:error, reason} -> error_response(reason)
    end
  end

  def execute(_tool, _arguments, _opts), do: response(%{"errors" => [%{"message" => "Expected an argument object"}]})

  defp execute_bound({:ok, query, variables}, opts) do
    case graphql(query, variables, opts) do
      {:ok, result} -> response(result)
      {:error, reason} -> error_response(reason)
    end
  end

  defp execute_bound({:resolve_state, id, state}, opts), do: update_state(id, state, opts)
  defp execute_bound({:update_comment, id, comment_id, body}, opts), do: update_comment(id, comment_id, body, opts)
  defp execute_bound({:error, reason}, _opts), do: error_response(reason)

  defp error_response(reason), do: response(%{"errors" => [%{"message" => inspect(reason)}]})

  defp spec(name, description, properties, required \\ []) do
    %{"name" => name, "description" => description, "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => properties, "required" => required}}
  end

  defp string_field, do: %{"type" => "string", "minLength" => 1}

  defp bound_issue_id(opts) do
    case Keyword.get(opts, :issue) do
      %{id: id} when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :missing_bound_issue}
    end
  end

  defp operation("linear_get_issue", _args, id) do
    {:ok, "query($id: String!) { issue(id: $id) { #{@issue_fields} } }", %{"id" => id}}
  end

  defp operation("linear_get_issue_context", _args, id) do
    {:ok,
     "query($id: String!) { issue(id: $id) { #{@issue_fields} comments(first: 100) { nodes { id body resolvedAt } } team { states { nodes { id name type } } } inverseRelations(first: 100) { nodes { type issue { id identifier state { name } } } } } }",
     %{"id" => id}}
  end

  defp operation("linear_get_comments", _args, id) do
    {:ok, "query($id: String!) { issue(id: $id) { id comments(first: 100) { nodes { id body resolvedAt } } } }", %{"id" => id}}
  end

  defp operation("linear_get_states", _args, id) do
    {:ok, "query($id: String!) { issue(id: $id) { id team { states { nodes { id name type } } } } }", %{"id" => id}}
  end

  defp operation("linear_update_issue_description", %{"description" => value}, id)
       when is_binary(value) and byte_size(value) > 0 do
    {:ok, "mutation($id: String!, $description: String!) { issueUpdate(id: $id, input: {description: $description}) { success issue { id description } } }", %{"id" => id, "description" => value}}
  end

  defp operation("linear_add_comment", %{"body" => value}, id)
       when is_binary(value) and byte_size(value) > 0 do
    {:ok, "mutation($issueId: String!, $body: String!) { commentCreate(input: {issueId: $issueId, body: $body}) { success comment { id body } } }", %{"issueId" => id, "body" => value}}
  end

  defp operation("linear_update_issue_state", %{"state" => state}, id)
       when is_binary(state) and byte_size(state) > 0 do
    {:resolve_state, id, state}
  end

  defp operation("linear_update_comment", %{"comment_id" => comment_id, "body" => body}, id)
       when is_binary(comment_id) and byte_size(comment_id) > 0 and is_binary(body) and byte_size(body) > 0 do
    {:update_comment, id, comment_id, body}
  end

  defp operation(_tool, _args, _id), do: {:error, :invalid_tool_or_arguments}

  defp graphql(query, variables, opts) do
    client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    client.(query, variables, Keyword.take(opts, [:tracker_settings]))
  end

  defp update_state(id, state_name, opts) do
    case maybe_validate_review_state(state_name, opts) do
      :ok ->
        update_state_after_gate(id, state_name, opts)

      {:error, {:in_review_delivery_gate, reason}} ->
        response(%{"errors" => [%{"message" => "In Review blocked by delivery gate: #{inspect(reason)}"}]})
    end
  end

  defp maybe_validate_review_state("In Review", opts) do
    case DeliveryGate.validate_in_review_for_host(Keyword.get(opts, :issue, %{}), opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:in_review_delivery_gate, reason}}
    end
  end

  defp maybe_validate_review_state(_state_name, _opts), do: :ok

  defp update_state_after_gate(id, state_name, opts) do
    query = "query($id: String!) { issue(id: $id) { id team { states { nodes { id name } } } } }"

    with {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => nodes}}}}}} <-
           graphql(query, %{"id" => id}, opts),
         %{"id" => state_id} <- Enum.find(nodes, &(&1["name"] == state_name)),
         {:ok, result} <-
           graphql(
             "mutation($id: String!, $stateId: String!) { issueUpdate(id: $id, input: {stateId: $stateId}) { success issue { id state { name } } } }",
             %{"id" => id, "stateId" => state_id},
             opts
           ) do
      response(result)
    else
      nil -> response(%{"errors" => [%{"message" => "Unknown state name"}]})
      {:error, reason} -> response(%{"errors" => [%{"message" => inspect(reason)}]})
      _ -> response(%{"errors" => [%{"message" => "Could not read issue team states"}]})
    end
  end

  defp update_comment(issue_id, comment_id, body, opts) do
    query = "query($id: String!) { issue(id: $id) { id comments(first: 100) { nodes { id } } } }"

    with {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => nodes}}}}} <-
           graphql(query, %{"id" => issue_id}, opts),
         true <- Enum.any?(nodes, &(&1["id"] == comment_id)),
         {:ok, result} <-
           graphql(
             "mutation($id: String!, $body: String!) { commentUpdate(id: $id, input: {body: $body}) { success comment { id body } } }",
             %{"id" => comment_id, "body" => body},
             opts
           ) do
      response(result)
    else
      false -> response(%{"errors" => [%{"message" => "Comment does not belong to current issue or is beyond first 100 comments"}]})
      {:error, reason} -> response(%{"errors" => [%{"message" => inspect(reason)}]})
      _ -> response(%{"errors" => [%{"message" => "Could not verify comment ownership"}]})
    end
  end

  defp response(result) do
    success =
      not (is_list(result["errors"]) and result["errors"] != []) and
        not Enum.any?(Map.get(result, "data", %{}), fn {_key, value} -> is_map(value) and value["success"] == false end)

    output = Jason.encode!(result)
    %{"success" => success, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end
end
