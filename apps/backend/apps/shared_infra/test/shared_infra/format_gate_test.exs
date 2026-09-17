defmodule SharedInfra.FormatGateTest do
  @moduledoc """
  The format gate has to be able to FAIL. It once could not: the root `.formatter.exs` used
  `subdirectories: ["apps/*"]`, the traversal never happened, and `mix format --check-formatted`
  returned 0 with 24 unformatted files in the tree — so every "format check passed" claim made
  against it was vacuous while CI failed on the same commit.

  Nothing in the repo asserted the gate itself, which is why the hole survived. These tests do:

    * the root `inputs` must actually reach every umbrella app's `lib/` and `test/` — narrowing that
      glob is how a whole app silently escapes the check (MUT-6);
    * the command must exit NON-ZERO on an unformatted file and zero on a formatted one, read from
      the exit status;
    * through a pipe that status is LOST — `cmd | head` reports head's 0 — which is the second half
      of how the hole stayed hidden, and is pinned here so it stays known.

  The command runs in a throwaway directory with its own `.formatter.exs`, so it never loads this
  project and never touches `_build`.
  """
  use ExUnit.Case, async: true

  @umbrella Path.expand("../../../..", __DIR__)

  # Deliberately unformatted: the formatter puts a space inside `%{ }`, one space around `<-`, and
  # strips the doubled blank line.
  @unformatted """
  defmodule Bad do
    def go(x) do
      %{a: 1,   b: 2}
      |>Map.put(:c,   x)


    end
  end
  """

  defp inputs do
    {config, _} = Code.eval_file(Path.join(@umbrella, ".formatter.exs"))
    Keyword.fetch!(config, :inputs)
  end

  defp matched_paths do
    inputs()
    |> Enum.flat_map(&Path.wildcard(Path.join(@umbrella, &1)))
    |> MapSet.new()
  end

  test "MUT-6 guard: the root inputs reach every umbrella app's lib/ AND test/ — no app escapes the gate" do
    apps =
      @umbrella
      |> Path.join("apps/*")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert length(apps) >= 9, "expected the full umbrella, found: #{inspect(apps)}"

    matched = matched_paths()

    for app <- apps, dir <- ["lib", "test"] do
      covered =
        Enum.any?(matched, fn path ->
          String.starts_with?(path, Path.join([@umbrella, "apps", app, dir]) <> "/")
        end)

      assert covered,
             "apps/#{app}/#{dir} is NOT covered by the root .formatter.exs inputs — an unformatted " <>
               "file there would pass the gate unnoticed. inputs: #{inspect(inputs())}"
    end
  end

  test "the root inputs reach files in apps that have NO .formatter.exs of their own" do
    # These three have none; under the old `subdirectories:` config their sources were structurally
    # unreachable by the gate, whatever it returned.
    for app <- ["shared_infra", "media_service", "notification_service"] do
      refute File.exists?(Path.join([@umbrella, "apps", app, ".formatter.exs"])),
             "apps/#{app} grew its own .formatter.exs — the root inputs must still cover it directly"

      assert Enum.any?(matched_paths(), fn path ->
               String.starts_with?(path, Path.join([@umbrella, "apps", app, "lib"]) <> "/")
             end)
    end
  end

  @tag :tmp_dir
  test "the check EXITS NON-ZERO on an unformatted file and names it", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, ".formatter.exs"), ~s([inputs: ["*.ex"]]\n))
    File.write!(Path.join(tmp, "bad.ex"), @unformatted)

    {output, status} =
      System.cmd("mix", ["format", "--check-formatted"], cd: tmp, stderr_to_stdout: true)

    assert status != 0, "the gate passed an unformatted file. output:\n#{output}"
    assert output =~ "bad.ex"
    assert output =~ "not formatted"
  end

  @tag :tmp_dir
  test "the check exits ZERO once the file is formatted — the gate is not simply always red",
       %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, ".formatter.exs"), ~s([inputs: ["*.ex"]]\n))

    File.write!(
      Path.join(tmp, "good.ex"),
      Code.format_string!(@unformatted) |> IO.iodata_to_binary()
    )

    File.write!(Path.join(tmp, "good.ex"), File.read!(Path.join(tmp, "good.ex")) <> "\n")

    {output, status} =
      System.cmd("mix", ["format", "--check-formatted"], cd: tmp, stderr_to_stdout: true)

    assert status == 0, "a formatted file was reported unformatted. output:\n#{output}"
  end

  @tag :tmp_dir
  test "THE PIPE TRAP: `mix format --check-formatted | head` reports head's 0, hiding the failure",
       %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, ".formatter.exs"), ~s([inputs: ["*.ex"]]\n))
    File.write!(Path.join(tmp, "bad.ex"), @unformatted)

    {_, direct} =
      System.cmd("sh", ["-c", "mix format --check-formatted"], cd: tmp, stderr_to_stdout: true)

    {_, piped} =
      System.cmd("sh", ["-c", "mix format --check-formatted | head -1"],
        cd: tmp,
        stderr_to_stdout: true
      )

    assert direct != 0

    assert piped == 0,
           "if this ever fails the trap is gone and the warning in .formatter.exs can go"
  end
end
