defmodule Ersventaja.Segfy.BudgetRenewalPriorFromGateTest do
  use ExUnit.Case, async: true

  alias Ersventaja.Segfy.Budget

  describe "renewal_prior_*_from_gate_item/1" do
    test "extrai dígitos da apólice e fim de vigência (dd/mm/yyyy) como no Gate" do
      item = %{
        "numeroApolice" => "4551146",
        "dataFim" => "31/03/2026"
      }

      assert Budget.renewal_prior_policy_digits_from_gate_item(item) == "4551146"
      assert Budget.renewal_prior_policy_end_iso_from_gate_item(item) == "2026-03-31"
    end

    test "aceita mask_police com máscara" do
      item = %{"mask_police" => "4551-146", "dtFinalVigencia" => "2026-03-31"}

      assert Budget.renewal_prior_policy_digits_from_gate_item(item) == "4551146"
      assert Budget.renewal_prior_policy_end_iso_from_gate_item(item) == "2026-03-31"
    end

    test "dataVencimento dd/mm/aaaa (JSON gate alternativo)" do
      item = %{"numeroApolice" => "4551146", "dataVencimento" => "31/03/2026"}

      assert Budget.renewal_prior_policy_end_iso_from_gate_item(item) == "2026-03-31"
    end
  end
end
