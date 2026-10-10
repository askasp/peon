defmodule Beamcode.SpeechTest do
  use ExUnit.Case, async: true
  import Beamcode.Speech

  test "keeps two sentences and the closing question; drops code, paths, tables, headings" do
    md = """
    ## Summary

    I fixed the failing checkout test. The cause was in `lib/beamcode/sessions.ex:42`, where the payment mock timed out after **5 seconds** on CI.

    ```elixir
    def foo, do: :bar
    ```

    - Updated `test/checkout_test.exs`
    - Changed apps/web/src/payment/mock.ts

    | a | b |
    |---|---|

    Want me to open a PR?
    """

    assert speakable(md) ==
             "I fixed the failing checkout test. The cause was in sessions, where the payment mock timed out after 5 seconds on CI. Want me to open a PR?"
  end

  test "links become their text, URLs and arrows go" do
    assert speakable("See [the PR](https://x.y/1) at https://github.com/a/b → merged.") ==
             "See the PR at a link, merged."
  end

  test "list items read as sentences" do
    assert speakable("Done:\n- tests pass\n- pushed the branch\n- deployed") ==
             "Done. tests pass."

    assert speakable("- tests pass\n- pushed the branch") == "tests pass. pushed the branch."
  end

  test "a long first sentence is cut" do
    long = Enum.map_join(1..60, " ", fn _ -> "word" end) <> "."
    assert speakable(long) |> String.split() |> length() == 40
    assert String.ends_with?(speakable(long), "…")
  end

  test "nothing to say" do
    assert speakable("```\nonly code\n```") == ""
    assert speakable(nil) == ""
  end
end
