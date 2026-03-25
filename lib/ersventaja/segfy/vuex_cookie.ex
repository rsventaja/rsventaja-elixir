defmodule Ersventaja.Segfy.VuexCookie do
  @moduledoc false
  # Cookie `vuex` que o SPA grava após `upfygate.../auth/login`; o ASP.NET em gestao.segfy.com
  # usa `auth.token` para abrir sessão (ver scripts/segfy_chain_probe.py `_build_vuex_cookie`).

  @spec build_from_gate_login_data(map()) :: binary()
  def build_from_gate_login_data(d) when is_map(d) do
    d = stringify_keys(d)

    vuex_obj = %{
      "auth" => %{
        "isAuth" => true,
        "emailSegfyer" => d["emailSegfyer"],
        "nameSegfyer" => d["nomeSegfyer"] || "",
        "SegfyerId" => d["segfyerId"] || "",
        "email" => d["email"] || "",
        "username" => d["nome"] || "",
        "usuarioId" => d["usuarioId"] || 0,
        "assinaturaId" => d["assinaturaId"] || 0,
        "assinaturaLogin" => d["assinaturaLogin"] || "",
        "chatHost" => d["chatHost"] || "",
        "dataAssinatura" => d["dataAssinatura"] || "",
        "primeiroAcesso" => d["primeiroAcesso"] || false,
        "token" => d["token"] || "",
        "server" => d["server"] || "",
        "administrador" => d["administrador"] || false,
        "impersonateClient" => "",
        "impersonateUser" => "",
        "authTime" => 0,
        "hash" => "",
        "segfyer" => d["segfyer"] || false,
        "guid" => d["guid"] || "",
        "dataTrialInicio" => d["dataInclusaoTrial"],
        "dataTrialFim" => d["dataExpiracaoTrial"],
        "isMC" => d["acessoMC"] || false,
        "isGestao" => d["acessoGestao"] || false,
        "isOrcamentacao" => d["acessoOrcamentacao"] || false,
        "administradorOrcamento" => d["administradorOrcamento"] || false,
        "produtorId" => d["produtorId"],
        "bloquearOrcamentoVeicular" => d["bloquearCotacaoVeicularTelaCotacao"] || false,
        "bloquearOrcamentoResidencial" => d["bloquearCotacaoResidencialTelaCotacao"] || false,
        "bloquearOrcamentoManual" => d["bloquearCotacaoManualTelaCotacao"] || false,
        "bloquearDuplicarOrcamento" => d["bloquearDuplicarCotacaoTelaCotacao"] || false,
        "acessoBuscaDocumentos" => d["acessoBuscaDocumentos"] || false,
        "acessoRecebimento" => d["acessoRecebimento"] || false,
        "acessoParcelaAtrasada" => d["acessoParcelaAtrasada"] || false,
        "nomeCorretora" => d["nomeCorretora"] || "",
        "cnpjCorretora" => d["cnpjCorretora"],
        "emailIntranet" => d["emailIntranet"] || "",
        "temParcelaPendente" => d["temParcelaPendente"] || false,
        "statusAssinatura" => d["statusAssinatura"] || "",
        "novaJornada" => d["novaJornada"] || false,
        "authAutomationToken" => d["authAutomationToken"] || "",
        "userAutomationToken" => d["userAutomationToken"] || "",
        "acessoCotacaoSaude" => d["acessoCotacaoSaude"] || false,
        "configuraLoginCompanhia" => d["configuraLoginCompanhia"] || 0,
        "segfyerId" => d["segfyerId"],
        "nomeSegfyer" => d["nomeSegfyer"],
        "acessoConfigurarLoginsTodos" => d["acessoConfigurarLoginsTodos"] || false
      },
      "settings" => %{"collapsedMenu" => false, "showTutorialPlugin" => true}
    }

    Jason.encode!(vuex_obj)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end
end
