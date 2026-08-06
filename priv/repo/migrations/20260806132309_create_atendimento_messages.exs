defmodule Ersventaja.Repo.Migrations.CreateAtendimentoMessages do
  use Ecto.Migration

  def change do
    create table(:atendimento_messages) do
      add :atendimento_id, references(:atendimentos, on_delete: :delete_all), null: false
      add :direction, :string, null: false
      add :sender_type, :string, null: false
      add :content_type, :string, null: false
      add :content, :text
      add :whatsapp_phone, :string
      add :media_id, :string
      add :mime_type, :string

      timestamps()
    end

    create index(:atendimento_messages, [:atendimento_id])
  end
end
