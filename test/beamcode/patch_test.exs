defmodule Beamcode.PatchTest do
  use ExUnit.Case, async: true

  alias Beamcode.Patch

  @header "diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f"

  # A whole-file hunk (as OpenCode sends it): `n` lines, line `at` changed.
  defp whole(n, at) do
    body =
      for i <- 1..n do
        if i == at, do: "-old #{i}\n+new #{i}", else: " line #{i}"
      end

    "#{@header}\n@@ -1,#{n} +1,#{n} @@\n#{Enum.join(body, "\n")}\n"
  end

  test "keeps a change with three lines around it, as its own hunk" do
    {patch, hidden} = Patch.trim(whole(1000, 500))

    assert hidden == 0
    lines = String.split(patch, "\n")
    assert Enum.take(lines, 4) == String.split(@header, "\n")

    assert Enum.drop(lines, 4) == [
             "@@ -497,7 +497,7 @@",
             " line 497",
             " line 498",
             " line 499",
             "-old 500",
             "+new 500",
             " line 501",
             " line 502",
             " line 503"
           ]
  end

  test "changes far apart become separate hunks with their own line numbers" do
    body = for i <- 1..100, do: if(i in [10, 90], do: "+added #{i}", else: " line #{i}")
    patch = "@@ -1,98 +1,100 @@\n" <> Enum.join(body, "\n")

    {trimmed, 0} = Patch.trim(patch, context: 1)

    assert String.split(trimmed, "\n") == [
             "@@ -9,2 +9,3 @@",
             " line 9",
             "+added 10",
             " line 11",
             "@@ -88,2 +89,3 @@",
             " line 89",
             "+added 90",
             " line 91"
           ]
  end

  test "stops after max_lines and says how many were left out" do
    body = for i <- 1..50, do: "+line #{i}"
    {patch, hidden} = Patch.trim("@@ -0,0 +1,50 @@\n" <> Enum.join(body, "\n"), max_lines: 11)

    assert length(String.split(patch, "\n")) == 11
    assert hidden == 40
  end

  test "a patch without hunks (a binary file) stays as it is" do
    assert Patch.trim("Binary files a/x and b/x differ") == {"Binary files a/x and b/x differ", 0}
  end
end
