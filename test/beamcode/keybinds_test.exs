defmodule Beamcode.KeybindsTest do
  use ExUnit.Case, async: true
  alias Beamcode.Keybinds

  test "in-session defaults follow opencode, with the prefix as leader" do
    d = Keybinds.defaults()
    assert d["session_interrupt"] == "escape"
    assert d["model_list"] == "<leader>m"
    refute Map.has_key?(d, "leader")
  end

  test "overrides keep only changed known keys" do
    assert Keybinds.overrides(%{
             "model_list" => "<leader>m",
             "messages_first" => " Ctrl+Home ",
             "bogus" => "x"
           }) ==
             %{"messages_first" => "ctrl+home"}
  end

  test "merged applies user overrides" do
    assert Keybinds.merged(%{keybinds: %{"model_list" => "ctrl+m", "nope" => "x"}})["model_list"] ==
             "ctrl+m"

    refute Map.has_key?(Keybinds.merged(%{keybinds: %{"nope" => "x"}}), "nope")
  end

  test "label expands the prefix" do
    assert Keybinds.label("<leader>m,ctrl+m", "ctrl+b") == "ctrl+b m"
  end

  test "prefs default to the tmux keymap with ctrl+b" do
    assert %{"keymap" => "tmux", "prefix" => "ctrl+b", "which_key_delay" => 300} =
             Keybinds.prefs(nil)
  end

  test "pref_overrides validates and keeps only changes" do
    assert Keybinds.pref_overrides(%{
             "keymap" => "standard",
             "prefix" => "ctrl+z",
             "which_key_delay" => "9000",
             "status_line" => "true",
             "keycast" => "true",
             "model_list" => "x"
           }) == %{"keymap" => "standard", "which_key_delay" => 1500, "keycast" => true}
  end

  test "shortcut hints follow the keymap" do
    tmux = Keybinds.prefs(nil)
    std = %{tmux | "keymap" => "standard"}
    inbox = %{id: "inbox", key: "i"}
    models = %{id: "models", key: "m"}

    assert Keybinds.item_keys(tmux, 0) == ["ctrl+b", "1"]
    assert Keybinds.item_keys(std, 0) == ["alt+1"]
    assert Keybinds.global_keys(tmux, inbox) == ["ctrl+b", "i"]
    assert Keybinds.global_keys(tmux, models) == ["ctrl+b", "g", "m"]
    assert Keybinds.global_keys(std, models) == ["g", "m"]
  end

  test "admin-only pages are hidden from members" do
    refute Enum.any?(Keybinds.globals(%{admin: false}), &(&1.id == "users"))
    assert Enum.any?(Keybinds.globals(%{admin: true}), &(&1.id == "users"))
  end
end
