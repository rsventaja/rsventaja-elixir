defmodule Ersventaja.Repo.Migrations.SeedInsuranceTypesAndClassifyPolicies do
  use Ecto.Migration

  def up do
    # 1. Seed insurance types
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    types = [
      "AUTOMÓVEL",
      "RESIDENCIAL",
      "EMPRESARIAL",
      "RESPONSABILIDADE CIVIL",
      "SEGURO DE VIDA",
      "RISCOS DIVERSOS",
      "CAPITALIZAÇÃO",
      "PLANO DE SAÚDE PET"
    ]

    for name <- types do
      execute(
        "INSERT INTO insurance_types (name, inserted_at, updated_at) VALUES ('#{name}', '#{now}', '#{now}') ON CONFLICT (name) DO NOTHING"
      )
    end

    # 2. Classify existing policies
    # We need to flush to ensure insurance_types are inserted before we reference them
    flush()

    # AUTOMÓVEL: detail matches Brazilian license plate pattern (old: AAA0000, Mercosul: AAA0A00)
    # Also includes entries that are car model names or have plates embedded in text
    execute("""
    UPDATE policies SET insurance_type_id = (SELECT id FROM insurance_types WHERE name = 'AUTOMÓVEL')
    WHERE insurance_type_id IS NULL
    AND (
      detail ~ '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$'
      OR detail IN (
        'TORO', 'PRISMA', 'PRIUS', 'STRADA', 'GREAT WALL', '208 STYLE',
        'COROLLA', 'COROLLA HYBRID', 'COROLLA CROSS', 'PULSE DRIVE',
        'KWID ZEN 0KM', 'JEEP RENEGADE', 'L200 ZERO', 'HB20 2022', 'HB20X 0KM',
        'MERCEDES BENZ CLA200', 'MACAN -SUBSTITUIÇÃO DA CAYENNE', 'AUTO', 'MOTO',
        'JUNIOR', 'AMANDA', '00000'
      )
      OR detail LIKE '%PLACA%'
      OR detail LIKE 'COLETIVA%'
    )
    """)

    # RESIDENCIAL
    execute("""
    UPDATE policies SET insurance_type_id = (SELECT id FROM insurance_types WHERE name = 'RESIDENCIAL')
    WHERE insurance_type_id IS NULL
    AND (
      detail LIKE 'RESIDENCIAL%'
      OR detail LIKE 'RESIDENCIA%'
      OR detail LIKE 'RESIDÊNCIA%'
      OR detail LIKE 'RES %'
      OR detail LIKE 'RES'
      OR detail LIKE 'HOUSING%'
      OR detail LIKE 'HOSING%'
      OR detail LIKE 'BURITAMA'
      OR detail LIKE 'APC RESIDENCIAL%'
      OR detail LIKE 'TÓKIO MARINE - RESIDENCIAL'
      OR detail LIKE 'TÓKIO MARINE RESIDENCIAL%'
      OR detail LIKE 'TOKIO MARINE RESIDENCIAL%'
      OR detail LIKE 'R. AUGUSTO TORTORELO%RESIDENCIAL'
      OR detail LIKE 'IMÓVEL%'
      OR detail LIKE 'APTº%'
      OR detail LIKE 'APTO%'
      OR detail LIKE 'AP %'
      OR detail LIKE 'APARTAMENTO%'
      OR detail LIKE 'AV PORTO CARREIRO'
      OR detail LIKE 'RUA %'
      OR detail LIKE 'SEM ESTACIONAMENTO'
    )
    """)

    # EMPRESARIAL
    execute("""
    UPDATE policies SET insurance_type_id = (SELECT id FROM insurance_types WHERE name = 'EMPRESARIAL')
    WHERE insurance_type_id IS NULL
    AND (
      detail LIKE 'EMPRESARIAL%'
      OR detail LIKE 'EMRPESARIAL%'
      OR detail LIKE 'EMPREASARIAL%'
      OR detail LIKE 'EMPESARIAL%'
      OR detail LIKE 'EMP'
      OR detail LIKE 'CONSULTÓRIO%'
      OR detail LIKE 'CONSULTÓRIOS%'
      OR detail LIKE 'ESTACIONAMENTO'
      OR detail LIKE 'UNIDADE %'
      OR detail LIKE 'S M PAULISTA'
      OR detail LIKE 'PERFECT%'
    )
    """)

    # RESPONSABILIDADE CIVIL
    execute("""
    UPDATE policies SET insurance_type_id = (SELECT id FROM insurance_types WHERE name = 'RESPONSABILIDADE CIVIL')
    WHERE insurance_type_id IS NULL
    AND (
      detail LIKE 'RESP CIVIL%'
      OR detail LIKE 'RESPONSABILIDADE CIVIL%'
      OR detail LIKE 'RESPOONSABILIDADE CIVIL%'
      OR detail LIKE 'RESPONSABILIDADE CIIVIL%'
      OR detail LIKE 'RCPI%'
      OR detail LIKE 'RCPSI%'
      OR detail LIKE 'RCP%'
      OR detail LIKE 'RC %'
      OR detail LIKE 'R C PROFISSIONAL'
    )
    """)

    # SEGURO DE VIDA
    execute("""
    UPDATE policies SET insurance_type_id = (SELECT id FROM insurance_types WHERE name = 'SEGURO DE VIDA')
    WHERE insurance_type_id IS NULL
    AND (
      detail LIKE 'VIDA%'
      OR detail LIKE 'VG %'
      OR detail LIKE 'VG -%'
      OR detail LIKE 'ACIDENTES PESSOAIS%'
    )
    """)

    # RISCOS DIVERSOS (celular, equipamentos, etc.)
    execute("""
    UPDATE policies SET insurance_type_id = (SELECT id FROM insurance_types WHERE name = 'RISCOS DIVERSOS')
    WHERE insurance_type_id IS NULL
    AND (
      detail LIKE 'CELULAR%'
      OR detail LIKE 'SMARTPHONE%'
      OR detail LIKE 'IPHONE%'
      OR detail LIKE 'RE - CELULAR%'
      OR detail LIKE 'RD %'
      OR detail LIKE 'R D %'
      OR detail LIKE 'EQUIPAMENTOS%'
      OR detail LIKE 'EQUI%PORT%'
      OR detail LIKE 'MAQ%EQUIP%'
    )
    """)

    # CAPITALIZAÇÃO
    execute("""
    UPDATE policies SET insurance_type_id = (SELECT id FROM insurance_types WHERE name = 'CAPITALIZAÇÃO')
    WHERE insurance_type_id IS NULL
    AND (
      detail LIKE 'PORTOCAP%'
      OR detail LIKE 'CAPITALIZAÇÃO%'
      OR detail LIKE 'ALUGUEL'
    )
    """)

    # PLANO DE SAÚDE PET
    execute("""
    UPDATE policies SET insurance_type_id = (SELECT id FROM insurance_types WHERE name = 'PLANO DE SAÚDE PET')
    WHERE insurance_type_id IS NULL
    AND detail = 'HEALTH FOR PET'
    """)

    # ENDOSSO / CANCELAMENTO / SUBSTITUIÇÃO: match by customer_name + end_date to find original policy
    # These refer to modifications of existing auto policies (new vehicle on same policy)
    execute("""
    UPDATE policies p
    SET insurance_type_id = orig.insurance_type_id
    FROM policies orig
    WHERE p.insurance_type_id IS NULL
    AND orig.insurance_type_id IS NOT NULL
    AND p.id != orig.id
    AND (
      LOWER(TRIM(p.customer_name)) = LOWER(TRIM(orig.customer_name))
      OR LOWER(TRIM(REGEXP_REPLACE(p.customer_name, '^[^A-Za-z]+', ''))) = LOWER(TRIM(orig.customer_name))
    )
    AND p.end_date = orig.end_date
    AND (
      p.detail LIKE 'ENDOSSO%'
      OR p.detail LIKE 'CANCELAMENTO%'
      OR p.detail LIKE 'SUBSTITUIÇÃO%'
      OR p.detail LIKE 'CORREÇÃO%'
      OR p.detail LIKE 'ATUALIZAÇÃO%'
      OR p.detail = 'APÓLICE CORRIGIDA'
    )
    """)

    # Second pass: match endossos by customer_name only (for cases where end_date doesn't match exactly)
    # but the customer has policies with a known type
    execute("""
    UPDATE policies p
    SET insurance_type_id = (
      SELECT orig.insurance_type_id
      FROM policies orig
      WHERE orig.insurance_type_id IS NOT NULL
      AND orig.id != p.id
      AND (
        LOWER(TRIM(orig.customer_name)) = LOWER(TRIM(p.customer_name))
        OR LOWER(TRIM(orig.customer_name)) = LOWER(TRIM(REGEXP_REPLACE(p.customer_name, '^[^A-Za-z]+', '')))
      )
      ORDER BY ABS(orig.end_date - p.end_date)
      LIMIT 1
    )
    WHERE p.insurance_type_id IS NULL
    AND (
      p.detail LIKE 'ENDOSSO%'
      OR p.detail LIKE 'CANCELAMENTO%'
      OR p.detail LIKE 'SUBSTITUIÇÃO%'
      OR p.detail LIKE 'CORREÇÃO%'
      OR p.detail LIKE 'ATUALIZAÇÃO%'
      OR p.detail = 'APÓLICE CORRIGIDA'
    )
    """)

    # Remaining entries with plate-like patterns in detail (e.g. "TÓKIO MARINE ELU1H14", "VERSA EAK2356")
    # These have plates embedded in longer text
    execute("""
    UPDATE policies SET insurance_type_id = (SELECT id FROM insurance_types WHERE name = 'AUTOMÓVEL')
    WHERE insurance_type_id IS NULL
    AND detail ~ '[A-Z]{3}[0-9][A-Z0-9][0-9]{2}'
    """)

    # Entries with car model names or Tókio/Tokio/Allianz references that are likely auto
    execute("""
    UPDATE policies SET insurance_type_id = (SELECT id FROM insurance_types WHERE name = 'AUTOMÓVEL')
    WHERE insurance_type_id IS NULL
    AND (
      detail LIKE 'TÓKIO%'
      OR detail LIKE 'TOKIO%'
      OR detail LIKE 'ALLIANZ%'
      OR detail LIKE '%ENDOSSO%SUBST%'
      OR detail LIKE '%ENDOSSO%PERFIL%'
      OR detail LIKE '%ENDOSSO T-CROSS%'
      OR detail LIKE '%ENDOSSO HR-V%'
      OR detail LIKE '%ENDOSSO COMPASS%'
      OR detail LIKE '%ENDOSSO BMW%'
      OR detail LIKE '%ENDOSSO COROLLA%'
      OR detail LIKE '%ENDOSSO JEEP%'
      OR detail LIKE '%ENDOSSO ECLIPSE%'
      OR detail LIKE '%ENDOSSO COMMANDER%'
      OR detail LIKE '%ENDOSSO TAOS%'
      OR detail LIKE 'DOBLO%'
      OR detail LIKE 'ETIOS%'
      OR detail LIKE 'FOX%'
      OR detail LIKE 'SPIN%'
      OR detail LIKE 'PÁLIO%'
      OR detail LIKE 'PAJERO%'
      OR detail LIKE 'UP!%'
      OR detail LIKE 'TIGGO%'
      OR detail LIKE 'BSY6H54%'
      OR detail LIKE 'ESPOSA%'
      OR detail LIKE 'A AVISAR'
      OR detail LIKE 'YS FAZER'
    )
    """)
  end

  def down do
    execute("UPDATE policies SET insurance_type_id = NULL")
    execute("DELETE FROM insurance_types")
  end
end
