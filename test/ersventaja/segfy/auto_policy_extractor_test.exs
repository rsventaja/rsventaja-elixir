defmodule Ersventaja.Segfy.AutoPolicyExtractorTest do
  use ExUnit.Case, async: true

  alias Ersventaja.Segfy.AutoPolicyExtractor

  describe "merge_calculate_payload/2" do
    test "mescla seções e sobrescreve com valores extraídos" do
      base = %{
        zip_code: "00000000",
        questionnaire: %{monthly_km: 100, residence_type: "house"},
        renewal: %{bonus_current: "5"}
      }

      extracted = %{
        "questionnaire" => %{"monthly_km" => 300, "work_distance" => 10},
        "renewal" => %{"bonus_current" => "10"}
      }

      merged = AutoPolicyExtractor.merge_calculate_payload(base, extracted)

      assert merged[:questionnaire][:monthly_km] == 300
      assert merged[:questionnaire][:work_distance] == 10
      assert merged[:questionnaire][:residence_type] == "house"
      assert merged[:renewal][:bonus_current] == "10"
      assert merged[:zip_code] == "00000000"
    end
  end
end
