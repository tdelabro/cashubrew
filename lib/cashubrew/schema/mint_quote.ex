defmodule Cashubrew.Schema.MintQuote do
  @moduledoc """
  Schema for a mint quote.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "mint_quotes" do
    field(:quote_id, :binary_id)
    field(:payment_request, :string)
    field(:expiry, :integer)
    field(:paid, :boolean)

    timestamps()
  end

  def changeset(quote, attrs) do
    quote
    |> cast(attrs, [:quote_id, :payment_request, :expiry, :paid])
    |> validate_required([:quote_id, :payment_request, :expiry, :paid])
  end

  def create!(repo, values) do
    %__MODULE__{}
    |> changeset(values)
    |> repo.insert()
    |> case do
      {:ok, mint_quote} -> mint_quote.id
      {:error, changeset} -> raise "Failed to insert key: #{inspect(changeset.errors)}"
    end
  end
end
