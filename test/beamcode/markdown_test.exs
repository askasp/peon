defmodule BeamcodeWeb.MarkdownTest do
  use ExUnit.Case, async: true
  alias BeamcodeWeb.Markdown

  defp html(text), do: text |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()

  test "escapes html" do
    assert html("<script>alert(1)</script>") =~ "&lt;script&gt;"
    refute html("<img src=x onerror=1>") =~ "<img"
  end

  test "renders code, lists, headings and links" do
    out =
      html(
        "## Title\n\n- **a**\n- `b`\n\n```\n<x>\n```\n\n[ok](https://example.com) [bad](javascript:alert(1))"
      )

    assert out =~ "<h2>Title</h2>"
    assert out =~ "<li><strong>a</strong></li>"
    assert out =~ "<code>b</code>"
    assert out =~ "<pre><code>&lt;x&gt;</code></pre>"
    assert out =~ ~s(<a href="https://example.com")
    refute out =~ ~s(href="javascript)
  end

  test "a heading followed directly by bullets" do
    out = html("## Urgent · 2\n- one\n- two\nafter")
    assert out =~ "<h2>Urgent · 2</h2><ul><li>one</li><li>two</li></ul><p>after</p>"
  end

  test "run summary uses section headings" do
    assert Beamcode.Schedules.summary_line(
             "# Front digest\nToday\n\n## Urgent · 2\n- a\n## Waiting · 5\n- b"
           ) ==
             "Urgent · 2 · Waiting · 5"

    assert Beamcode.Schedules.summary_line("# Title\n\n**All quiet** today.") ==
             "All quiet today."
  end
end
