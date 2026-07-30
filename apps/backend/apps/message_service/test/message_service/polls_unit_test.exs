defmodule MessageService.PollsUnitTest do
  @moduledoc """
  Docker-free poll logic: normalize_definition (every specific validation code; server-generated stable
  option ids; client extras discarded), build_aggregate (counts exact, voter_ids capped, total_voters
  distinct across multi-choice votes), and zero_aggregate. The full create/vote/history path on real SQL
  is MessageService.PollsTest.
  """
  use ExUnit.Case, async: true

  alias MessageService.Polls

  @valid %{"question" => "Lunch where?", "options" => [%{"text" => "Sushi"}, %{"text" => "Pizza"}]}

  test "a valid poll normalizes: server-generated stable ids o1..oN, trimmed text, extras discarded" do
    raw =
      @valid
      |> Map.put("allows_multiple", true)
      |> Map.put("options", [
        %{"text" => "  Sushi ", "id" => "client-spoofed", "evil" => true},
        %{"text" => "Pizza"},
        "Tacos"
      ])
      |> Map.put("extraneous", "dropped")

    assert {:ok, definition} = Polls.normalize_definition(raw)

    assert definition == %{
             "question" => "Lunch where?",
             "allows_multiple" => true,
             "options" => [
               %{"id" => "o1", "text" => "Sushi"},
               %{"id" => "o2", "text" => "Pizza"},
               %{"id" => "o3", "text" => "Tacos"}
             ]
           }
  end

  test "each validation failure has its SPECIFIC code" do
    assert {:error, :poll_invalid_question} = Polls.normalize_definition(Map.delete(@valid, "question"))
    assert {:error, :poll_invalid_question} = Polls.normalize_definition(%{@valid | "question" => "  "})

    assert {:error, :poll_invalid_question} =
             Polls.normalize_definition(%{@valid | "question" => String.duplicate("q", 301)})

    assert {:error, :poll_too_few_options} = Polls.normalize_definition(%{@valid | "options" => [%{"text" => "One"}]})
    assert {:error, :poll_too_few_options} = Polls.normalize_definition(Map.delete(@valid, "options"))

    thirteen = Enum.map(1..13, &%{"text" => "Option #{&1}"})
    assert {:error, :poll_too_many_options} = Polls.normalize_definition(%{@valid | "options" => thirteen})

    assert {:error, :poll_invalid_option} =
             Polls.normalize_definition(%{@valid | "options" => [%{"text" => "Ok"}, %{"text" => ""}]})

    assert {:error, :poll_invalid_option} =
             Polls.normalize_definition(%{
               @valid
               | "options" => [%{"text" => "Ok"}, %{"text" => String.duplicate("x", 101)}]
             })

    # Duplicate TEXT (case-insensitive, trimmed) — ids can't collide (server-generated).
    assert {:error, :poll_duplicate_option} =
             Polls.normalize_definition(%{@valid | "options" => [%{"text" => "Sushi"}, %{"text" => " sushi "}]})
  end

  test "build_aggregate: exact counts, capped voter_ids, distinct total_voters; nil cap = uncapped" do
    definition = %{
      "question" => "Q",
      "allows_multiple" => true,
      "options" => [%{"id" => "o1", "text" => "A"}, %{"id" => "o2", "text" => "B"}]
    }

    # 25 voters on o1; 3 of them ALSO voted o2 (multi) — total_voters must stay 25 (distinct users).
    voters = Enum.map(1..25, &"u#{&1}")
    votes = Enum.map(voters, &{"o1", &1}) ++ (voters |> Enum.take(3) |> Enum.map(&{"o2", &1}))

    aggregate = Polls.build_aggregate(definition, votes)
    [o1, o2] = aggregate.options

    assert o1.count == 25
    # voter_ids capped at 20 (earliest first) while the count stays exact.
    assert length(o1.voter_ids) == Polls.voter_ids_cap()
    assert o1.voter_ids == Enum.take(voters, 20)
    assert o2 == %{id: "o2", text: "B", count: 3, voter_ids: ["u1", "u2", "u3"]}
    assert aggregate.total_voters == 25
    assert aggregate.allows_multiple == true

    # The view-votes screen: nil cap returns everything.
    full = Polls.build_aggregate(definition, votes, nil)
    assert length(hd(full.options).voter_ids) == 25
  end

  test "zero_aggregate mirrors the definition with empty results (the create ack)" do
    {:ok, definition} = Polls.normalize_definition(@valid)

    assert Polls.zero_aggregate(definition) == %{
             question: "Lunch where?",
             allows_multiple: false,
             options: [
               %{id: "o1", text: "Sushi", count: 0, voter_ids: []},
               %{id: "o2", text: "Pizza", count: 0, voter_ids: []}
             ],
             total_voters: 0
           }
  end
end
