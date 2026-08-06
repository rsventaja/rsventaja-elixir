defmodule ErsventajaWeb.ErrorViewTest do
  use ErsventajaWeb.ConnCase, async: true

  # Bring render_to_string/3 for testing custom views
  import Phoenix.Template

  test "renders 404.html" do
    assert render_to_string(ErsventajaWeb.ErrorView, "404", "html", assigns: []) =~ "Not Found"
  end

  test "renders 500.html" do
    assert render_to_string(ErsventajaWeb.ErrorView, "500", "html", assigns: []) =~
             "Internal Server Error"
  end
end
