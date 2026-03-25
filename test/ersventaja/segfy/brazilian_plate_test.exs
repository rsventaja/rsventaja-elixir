defmodule Ersventaja.Segfy.BrazilianPlateTest do
  use ExUnit.Case, async: true

  alias Ersventaja.Segfy.BrazilianPlate

  test "Mercosul com hífen" do
    assert {:ok, "DAP0J59"} == BrazilianPlate.normalize("dap-0j59")
  end

  test "antiga" do
    assert {:ok, "ABC1234"} == BrazilianPlate.normalize("abc-1234")
  end

  test "fragmento OCR inválido" do
    assert :error == BrazilianPlate.normalize("DAP-9")
    assert :error == BrazilianPlate.normalize("DAP9")
  end

  test "pick_first_valid_plate prefere primeira válida" do
    assert "DAP0J59" ==
             BrazilianPlate.pick_first_valid_plate(["DAP-9", "DAP0J59", "ABC1234"])
  end

  test "pick_first_valid_plate cai no show quando atual é lixo" do
    assert "XYZ9876" ==
             BrazilianPlate.pick_first_valid_plate(["nope", nil, "XYZ9876"])
  end
end
