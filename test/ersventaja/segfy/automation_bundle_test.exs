defmodule Ersventaja.Segfy.AutomationBundleTest do
  use ExUnit.Case, async: true

  alias Ersventaja.Segfy.AutomationBundle

  test "parse_pair_from_js extrai uuid:hex do padrão do bundle" do
    uuid = "53ac945e-08e9-4e1d-8c9d-61ad3f10faeb"
    hex = String.duplicate("ab", 32)

    js = ~s|...const e="#{uuid}:#{hex}";return fetch(|

    assert {:ok, ^uuid, ^hex} = AutomationBundle.parse_pair_from_js(js)
  end

  test "parse_pair_from_js sem match" do
    assert :error = AutomationBundle.parse_pair_from_js("no credentials here")
  end
end
