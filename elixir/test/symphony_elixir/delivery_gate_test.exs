defmodule SymphonyElixir.DeliveryGateTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.DeliveryGate

  test "accepts open and merged changes, but rejects closed unmerged changes" do
    assert DeliveryGate.eligible_change?(%{"state" => "opened"})
    assert DeliveryGate.eligible_change?(%{"state" => "merged"})
    assert DeliveryGate.eligible_change?(%{"state" => "closed", "merged_at" => "2026-09-29T00:00:00Z"})
    refute DeliveryGate.eligible_change?(%{"state" => "closed", "merged_at" => nil})
    refute DeliveryGate.eligible_change?(%{"state" => "closed"})
  end

  test "routes GitLab and GitHub checks through the selected host" do
    previous_host = System.get_env("SYMPHONY_CODE_HOST")
    on_exit(fn -> restore_env("SYMPHONY_CODE_HOST", previous_host) end)

    for host <- ["gitlab", "github"] do
      System.put_env("SYMPHONY_CODE_HOST", host)
      assert :ok = DeliveryGate.validate_in_review_for_host(%{}, delivery_gate: fn _ -> :ok end)

      assert {:error, :blocked} =
               DeliveryGate.validate_in_review_for_host(%{},
                 delivery_gate: fn _ -> {:error, :blocked} end
               )
    end
  end

  test "rejects unsupported hosts and invalid checker responses" do
    previous_host = System.get_env("SYMPHONY_CODE_HOST")
    on_exit(fn -> restore_env("SYMPHONY_CODE_HOST", previous_host) end)

    System.put_env("SYMPHONY_CODE_HOST", "other")
    assert {:error, {:unsupported_code_host, "other"}} = DeliveryGate.validate_in_review_for_host(%{})

    assert {:error, :invalid_delivery_gate_result} =
             DeliveryGate.validate_in_review(%{}, delivery_gate: fn _ -> :unexpected end)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
