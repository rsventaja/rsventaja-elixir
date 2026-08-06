defmodule Ersventaja.BackupJob do
  use GenServer

  alias Ersventaja.Policies.Models.Policy
  alias Ersventaja.Repo
  alias ExAws.S3

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{})
  end

  def init(state) do
    schedule_work()
    {:ok, state}
  end

  def handle_info(:work, state) do
    file_content =
      Policy
      |> Repo.all()
      |> Repo.preload(:customer)
      |> Enum.map(&generate_row(&1))
      |> Enum.join("\n")

    file_name =
      DateTime.utc_now()
      |> DateTime.to_string()
      |> String.replace(~r/[^\d]/, "")

    "rsventaja-db-backup"
    |> S3.put_object("#{file_name}.BKP", file_content)
    |> ExAws.request!()

    schedule_work()

    {:noreply, state}
  end

  defp generate_row(
         %Policy{
           calculated: calculated,
           detail: detail,
           end_date: end_date,
           id: id,
           insurer_id: insurer_id,
           start_date: start_date
         } = policy
       ) do
    customer_name =
      case policy.customer do
        %{name: name} -> name
        _ -> ""
      end

    "#{id};#{customer_name};#{detail};#{insurer_id};#{start_date};#{end_date};#{calculated};#{id}"
  end

  defp schedule_work do
    Process.send_after(self(), :work, 24 * 60 * 60 * 1000)
  end
end
