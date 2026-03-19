# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Ersventaja.Repo.insert!(%Ersventaja.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Ersventaja.Repo
alias Ersventaja.UserManager.Models.User
alias Ersventaja.Policies.Models.{Policy, Insurer}

# ── User ──────────────────────────────────────────────────────────────────────
unless Repo.get_by(User, username: "user") do
  Ersventaja.UserManager.create_user(%{username: "user", password: "123"})
end

# ── Insurers ──────────────────────────────────────────────────────────────────
insurer_names = ["Porto Seguro", "Azul Seguros", "SulAmérica", "Tokio Marine",
                 "Allianz", "Bradesco Seguros", "Liberty", "HDI"]

insurers =
  Enum.map(insurer_names, fn name ->
    case Repo.get_by(Insurer, name: name) do
      nil  -> Repo.insert!(%Insurer{name: name})
      ins  -> ins
    end
  end)

insurer_ids = Enum.map(insurers, & &1.id)

# ── Helpers ───────────────────────────────────────────────────────────────────
today = Date.utc_today()

rand_insurer = fn -> Enum.random(insurer_ids) end

detail_pool = [
  "RESIDENCIAL", "EMPRESARIAL", "AUTOMÓVEL", "VIDA", "SAÚDE",
  "CONDOMÍNIO", "EQUIPAMENTOS", "RESPONSABILIDADE CIVIL",
  "TRANSPORTE", "GARANTIA", "FIANÇA LOCATÍCIA"
]

rand_detail = fn ->
  prefix = Enum.random(["ABC", "DEF", "GHI", "JKL", "MNO", "PQR", "STU", "VWX"])
  suffix = :rand.uniform(9999) |> Integer.to_string() |> String.pad_leading(4, "0")
  "#{prefix}#{suffix}"
end

phones = [
  "(11) 98765-4321", "(11) 97654-3210", "(21) 99876-5432", "(31) 98765-1234",
  "(41) 99999-8888", "(51) 98888-7777", "(61) 97777-6666", "(71) 96666-5555"
]

emails = [
  "contato@email.com", "cliente@gmail.com", "financeiro@empresa.com",
  "rh@empresa.com.br", "comercial@negocio.com", "pessoal@hotmail.com"
]

# ── Client pool (name / cpf / phone / email) ──────────────────────────────────
# Some clients have multiple policies (and slightly varying names to test grouping)
clients = [
  # -- clients vencendo em breve (< 7 dias) --
  %{name: "JOAO SILVA PEREIRA",         cpf: "111.222.333-01", phone: "(11) 91111-0001", email: "joao.silva@email.com"},
  %{name: "MARIA FERNANDA COSTA",       cpf: "111.222.333-02", phone: "(11) 92222-0002", email: "mariaf@gmail.com"},
  %{name: "CARLOS ALBERTO SOUZA",       cpf: "111.222.333-03", phone: "(21) 93333-0003", email: "carlos.souza@hotmail.com"},

  # -- clients vencendo entre 8-30 dias --
  %{name: "ANA BEATRIZ OLIVEIRA",       cpf: "222.333.444-01", phone: "(31) 94444-0004", email: "ana.oliveira@empresa.com"},
  %{name: "PEDRO HENRIQUE LIMA",        cpf: "222.333.444-02", phone: "(41) 95555-0005", email: "pedrolima@gmail.com"},
  %{name: "LUCIA APARECIDA MARTINS",    cpf: "222.333.444-03", phone: "(51) 96666-0006", email: "lucia.martins@hotmail.com"},
  %{name: "ROBERTO CARLOS ALVES",       cpf: "222.333.444-04", phone: "(61) 97777-0007", email: "roberto.alves@email.com"},
  %{name: "FERNANDA PATRICIA ROCHA",    cpf: "222.333.444-05", phone: "(71) 98888-0008", email: "fernanda.rocha@gmail.com"},
  %{name: "MARCOS AURELIO SANTOS",      cpf: "222.333.444-06", phone: "(11) 99999-0009", email: "marcos.santos@empresa.com"},
  %{name: "VANESSA CRISTINA BORGES",    cpf: "222.333.444-07", phone: "(11) 91010-0010", email: "vanessa.borges@hotmail.com"},

  # -- clients vigentes (vencimento daqui 31-300 dias) --
  %{name: "JULIO CESAR FERREIRA",       cpf: "333.444.555-01", phone: "(21) 91111-1001", email: "julio.ferreira@email.com"},
  %{name: "PATRICIA HELENA DIAS",       cpf: "333.444.555-02", phone: "(31) 92222-1002", email: "patricia.dias@gmail.com"},
  %{name: "ANDERSON LUIZ CAMPOS",       cpf: "333.444.555-03", phone: "(41) 93333-1003", email: "anderson.campos@hotmail.com"},
  %{name: "SIMONE APARECIDA FREITAS",   cpf: "333.444.555-04", phone: "(51) 94444-1004", email: "simone.freitas@empresa.com"},
  %{name: "GUSTAVO HENRIQUE MOREIRA",   cpf: "333.444.555-05", phone: "(61) 95555-1005", email: "gustavo.moreira@gmail.com"},
  %{name: "LARISSA BEATRIZ CUNHA",      cpf: "333.444.555-06", phone: "(71) 96666-1006", email: "larissa.cunha@email.com"},
  %{name: "RENATO JOSE BARBOSA",        cpf: "333.444.555-07", phone: "(11) 97777-1007", email: "renato.barbosa@hotmail.com"},
  %{name: "TATIANE SILVA MENDES",       cpf: "333.444.555-08", phone: "(11) 98888-1008", email: "tatiane.mendes@gmail.com"},
  %{name: "FABIO AUGUSTO CARDOSO",      cpf: "333.444.555-09", phone: "(21) 99999-1009", email: "fabio.cardoso@empresa.com"},
  %{name: "CLAUDIA REGINA PINTO",       cpf: "333.444.555-10", phone: "(31) 91010-1010", email: "claudia.pinto@email.com"},

  # -- clients com MÚLTIPLAS APÓLICES (mesmo CPF, nomes levemente diferentes) --
  %{name: "EMPRESA ABC LTDA",           cpf: "12.345.678/0001-90", phone: "(11) 93030-2020", email: "financeiro@empresaabc.com.br"},
  %{name: "EMPRESA ABC LTDA.",          cpf: "12.345.678/0001-90", phone: "(11) 93030-2020", email: "rh@empresaabc.com.br"},
  %{name: "CLINICA SAO LUCAS EIRELI",   cpf: "98.765.432/0001-11", phone: "(21) 94040-3030", email: "contato@clinicasaolucas.com"},
  %{name: "CLINICA SAO LUCAS",          cpf: "98.765.432/0001-11", phone: "(21) 94040-3030", email: "financeiro@clinicasaolucas.com"},
  %{name: "INSTITUTO EDUCACIONAL NOVO HORIZONTE", cpf: "55.666.777/0001-22", phone: "(31) 95050-4040", email: "secretaria@inh.edu.br"},
  %{name: "INSTITUTO NOVO HORIZONTE",   cpf: "55.666.777/0001-22", phone: "(31) 95050-4040", email: "diretoria@inh.edu.br"},
]

# ── Policy insertion ──────────────────────────────────────────────────────────

# Returns true if a policy with same customer + detail already exists
already_exists? = fn name, detail ->
  import Ecto.Query
  Repo.exists?(from p in Policy, where: p.customer_name == ^name and p.detail == ^detail)
end

insert_policy = fn attrs ->
  unless already_exists?.(attrs.customer_name, attrs.detail) do
    Repo.insert!(%Policy{
      customer_name:      attrs.customer_name,
      detail:             Map.get(attrs, :detail, rand_detail.()),
      start_date:         attrs.start_date,
      end_date:           attrs.end_date,
      calculated:         Map.get(attrs, :calculated, false),
      insurer_id:         Map.get(attrs, :insurer_id, rand_insurer.()),
      customer_cpf_or_cnpj: Map.get(attrs, :cpf),
      customer_phone:     Map.get(attrs, :phone),
      customer_email:     Map.get(attrs, :email)
    })
  end
end

# ── 1. Vencendo em 1–7 dias ────────────────────────────────────────────────────
soon_due = [
  {Enum.at(clients, 0), 2},
  {Enum.at(clients, 0), 4},   # mesmo cliente, 2ª apólice
  {Enum.at(clients, 1), 3},
  {Enum.at(clients, 2), 5},
  {Enum.at(clients, 2), 7},
]

Enum.each(soon_due, fn {client, days} ->
  insert_policy.(%{
    customer_name: client.name,
    cpf: client.cpf, phone: client.phone, email: client.email,
    start_date: Date.add(today, -(365 - days)),
    end_date:   Date.add(today, days),
    detail:     rand_detail.(),
    insurer_id: rand_insurer.()
  })
end)

# ── 2. Vencendo entre 8–30 dias ───────────────────────────────────────────────
mid_due = Enum.with_index([
  {Enum.at(clients, 3),  8},
  {Enum.at(clients, 4), 10},
  {Enum.at(clients, 5), 12},
  {Enum.at(clients, 3), 14},   # Ana: 2ª apólice
  {Enum.at(clients, 6), 15},
  {Enum.at(clients, 7), 17},
  {Enum.at(clients, 8), 19},
  {Enum.at(clients, 9), 20},
  {Enum.at(clients, 4), 22},   # Pedro: 2ª apólice
  {Enum.at(clients, 5), 24},
  {Enum.at(clients, 6), 25},
  {Enum.at(clients, 7), 27},
  {Enum.at(clients, 8), 28},
  {Enum.at(clients, 9), 29},
])

Enum.each(mid_due, fn {{client, days}, _i} ->
  insert_policy.(%{
    customer_name: client.name,
    cpf: client.cpf, phone: client.phone, email: client.email,
    start_date: Date.add(today, -(365 - days)),
    end_date:   Date.add(today, days),
    detail:     rand_detail.(),
    insurer_id: rand_insurer.()
  })
end)

# ── 3. Vigentes (vencendo daqui 31–300 dias) ──────────────────────────────────
vigent_clients = Enum.slice(clients, 10, 10)

vigent_offsets = [35, 45, 60, 75, 90, 120, 150, 180, 210, 240, 270, 300,
                  40, 55, 80, 100, 130, 160, 190, 220]

Enum.zip(vigent_clients ++ vigent_clients, vigent_offsets)
|> Enum.each(fn {client, days} ->
  insert_policy.(%{
    customer_name: client.name,
    cpf: client.cpf, phone: client.phone, email: client.email,
    start_date: Date.add(today, -(365 - days)),
    end_date:   Date.add(today, days),
    detail:     rand_detail.(),
    insurer_id: rand_insurer.()
  })
end)

# ── 4. Clientes com múltiplas apólices ────────────────────────────────────────
multi_clients = Enum.slice(clients, 20, 6)

multi_policies = [
  # Empresa ABC: 4 apólices
  {Enum.at(multi_clients, 0), 10,   Enum.at(detail_pool, 0)},
  {Enum.at(multi_clients, 1), 120,  Enum.at(detail_pool, 1)},
  {Enum.at(multi_clients, 0), 200,  Enum.at(detail_pool, 2)},
  {Enum.at(multi_clients, 1), -30,  Enum.at(detail_pool, 3)},  # vencida
  # Clínica São Lucas: 3 apólices
  {Enum.at(multi_clients, 2), 5,    Enum.at(detail_pool, 4)},
  {Enum.at(multi_clients, 3), 90,   Enum.at(detail_pool, 5)},
  {Enum.at(multi_clients, 2), -15,  Enum.at(detail_pool, 6)},  # vencida
  # Instituto Novo Horizonte: 3 apólices
  {Enum.at(multi_clients, 4), 20,   Enum.at(detail_pool, 7)},
  {Enum.at(multi_clients, 5), 180,  Enum.at(detail_pool, 8)},
  {Enum.at(multi_clients, 4), 250,  Enum.at(detail_pool, 9)},
]

Enum.each(multi_policies, fn {client, days, detail} ->
  start_d = if days < 0,
    do:   Date.add(today, days - 365),
    else: Date.add(today, -(365 - days))
  insert_policy.(%{
    customer_name: client.name,
    cpf: client.cpf, phone: client.phone, email: client.email,
    start_date: start_d,
    end_date:   Date.add(today, days),
    detail:     detail,
    insurer_id: rand_insurer.(),
    calculated: days < 0
  })
end)

# ── 5. Apólices vencidas (para testar filtro vigentes) ────────────────────────
expired_names = [
  "SILVIA MORAES TEIXEIRA", "BRUNO ANDRADE NUNES", "HELIO RODRIGUES PAZ",
  "ELAINE CRISTINA VIDAL", "SERGIO LUIZ MONTEIRO"
]

Enum.each(Enum.with_index(expired_names), fn {name, i} ->
  days_past = -(i * 15 + 10)
  insert_policy.(%{
    customer_name: name,
    cpf: "444.555.66#{i}-0#{i}",
    phone: Enum.at(phones, rem(i, length(phones))),
    email: Enum.at(emails, rem(i, length(emails))),
    start_date: Date.add(today, days_past - 365),
    end_date:   Date.add(today, days_past),
    detail:     rand_detail.(),
    insurer_id: rand_insurer.(),
    calculated: true
  })
end)

IO.puts("✅  Seeds concluídas!")
