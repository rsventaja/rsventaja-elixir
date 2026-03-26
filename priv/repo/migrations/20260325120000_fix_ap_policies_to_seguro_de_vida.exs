defmodule Ersventaja.Repo.Migrations.FixApPoliciesToSeguroDeVida do
  use Ecto.Migration

  def up do
    # Reclassify "PERFECT - AP..." policies from EMPRESARIAL to SEGURO DE VIDA
    # AP here = Acidentes Pessoais (not Apartamento - e.g. "AP 191 BL C" is RESIDENCIAL)
    execute("""
    UPDATE policies
    SET insurance_type_id = (SELECT id FROM insurance_types WHERE name = 'SEGURO DE VIDA')
    WHERE detail LIKE 'PERFECT - AP%'
    """)
  end

  def down do
    # Revert PERFECT - AP back to EMPRESARIAL
    execute("""
    UPDATE policies
    SET insurance_type_id = (SELECT id FROM insurance_types WHERE name = 'EMPRESARIAL')
    WHERE detail LIKE 'PERFECT - AP%'
    """)

  end
end
