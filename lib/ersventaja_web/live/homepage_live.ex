defmodule ErsventajaWeb.HomepageLive do
  use ErsventajaWeb, :live_view
  import ErsventajaWeb.Components.Navbar
  import ErsventajaWeb.Components.Hero

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <style>
      /* Force full width for homepage */
      body { margin: 0 !important; padding: 0 !important; font-family: 'Playfair Display', Georgia, serif; color: #504f4f; width: 100% !important; max-width: 100% !important; }
      .homepage-wrapper { width: 100% !important; max-width: 100% !important; margin: 0 !important; padding: 0 !important; }
      .homepage-wrapper .container { max-width: 100% !important; width: 100% !important; padding: 0 !important; margin: 0 !important; }

      /* Content */
      .main-content { background-color: white; width: 100% !important; max-width: 100% !important; }
      .section { padding: 3em 2em; text-align: center; width: 100% !important; max-width: 100% !important; }
      .section-title { font-size: 36px; font-weight: 400; letter-spacing: 2px; margin-bottom: 1.5em; font-family: 'Playfair Display', Georgia, serif; }
      .about-text { max-width: 70%; margin: 0 auto; font-size: 20px; line-height: 30px; letter-spacing: 1px; text-indent: 4em; font-family: 'Playfair Display', Georgia, serif; }

      @media (max-width: 768px) {
        .section { padding: 2em 1.25em; }
        .section-title { font-size: 26px; letter-spacing: 1px; margin-bottom: 1em; }
        .about-text { max-width: 100%; font-size: 17px; line-height: 28px; text-indent: 2em; letter-spacing: 0.3px; }
      }
    </style>

    <div class="homepage-wrapper" style="width: 100%; max-width: 100%; margin: 0; padding: 0;">
      <.navbar />
      <.hero title="RS Ventaja" subtitle="Corretora de Seguros" />

      <!-- Main Content -->
      <div class="main-content" style="width: 100%;">
        <!-- Quem somos -->
        <section class="section">
          <h2 class="section-title">Quem somos</h2>
          <p class="about-text">
            No mercado desde 2000, trabalhamos com atenção especial às necessidades individuais do cliente. Temos orgulho em
            construir relações de confiança, possuindo clientes satisfeitos pelo nosso atendimento personalizado e bem
            amparados pelas coberturas que oferecemos.
          </p>
        </section>
      </div>
    </div>
    """
  end
end
