defmodule Cashubrew.Nuts.Nut04.Impl do
  @moduledoc """
  Implementation and structs of the NUT-04
  """
  alias Cashubrew.Lightning.LightningNetworkService
  alias Cashubrew.Mint
  alias Cashubrew.Nuts.Nut00
  alias Cashubrew.Nuts.Nut04.Impl.MintQuoteMutex
  alias Cashubrew.Schema

  def create_mint_quote!(amount, unit) do
    repo = Application.get_env(:cashubrew, :repo)

    {payment_request, _payment_hash} = LightningNetworkService.create_invoice!(amount, unit)

    # Note: quote is a unique and random id generated by the mint to internally look up the payment state.
    # quote MUST remain a secret between user and mint and MUST NOT be derivable from the payment request.
    # A third party who knows the quote ID can front-run and steal the tokens that this operation mints.
    quote_id = Ecto.UUID.bingenerate()

    # 1 hour expiry
    expiry = :os.system_time(:second) + 3600

    Schema.MintQuote.create!(repo, %{
      id: quote_id,
      payment_request: payment_request,
      expiry: expiry,
      # Unpaid
      state: <<0>>
    })

    %{quote_id: quote_id, request: payment_request, expiry: expiry}
  end

  def get_mint_quote(quote_id) do
    repo = Application.get_env(:cashubrew, :repo)

    quote = repo.get!(Schema.MintQuote, quote_id)

    %{
      quote_id: quote_id,
      request: quote.payment_request,
      expiry: quote.expiry,
      state:
        case quote.state do
          <<0>> -> "UNPAID"
          <<1>> -> "PAID"
          <<2>> -> "ISSUED"
          _ -> raise "InvalidState"
        end
    }
  end

  @spec mint_tokens!(String.t(), Nut00.BlindedMessage) :: Nut00.BlindSignature
  def mint_tokens!(quote_id, blinded_messages) do
    repo = Application.get_env(:cashubrew, :repo)

    mint_quote = MintQuoteMutex.check_and_acquire!(repo, quote_id)

    try do
      {keyset, total_amount} = Mint.Verification.Outputs.verify!(repo, blinded_messages)

      if total_amount != mint_quote.amount do
        raise "TotalOutputAmountDoesNotEqualMintQuoteAmount"
      end

      if !keyset.active do
        raise "KeysetIsNotActive"
      end

      unit = keyset.unit

      if unit != mint_quote.unit do
        raise "OutputsAndMintQuoteUnitsDoNotMatch"
      end

      if mint_quote.exipry > :os.system_time(:second) do
        raise "QuoteExpired"
      end

      promises = Mint.generate_promises(repo, keyset.id, blinded_messages)
      repo.insert_all(Schema.Promises, promises)
    after
      MintQuoteMutex.release!(repo, quote_id)
    end
  end

  defmodule MintQuoteMutex do
    @moduledoc """
    # The msb of the `state` field of the MintQuore is used as a guard,
    # against two process minting this quote at the same time.
    # It has to be set when we start the minting process and cleared in the end,
    # regardless of the mint being a success or a failure.
    """
    def check_and_acquire!(repo, quote_id) do
      mint_quote = repo.get!(Schema.MintQuote, quote_id)

      case mint_quote.state do
        <<1>> -> nil
        <<0>> -> raise "InvoiceHasNotBeenPaid"
        <<2>> -> raise "QuoteHasAlreadyBeenIssued"
        v when Bitwise.band(v, <<0x80>>) != 0 -> raise "QuoteIsAlreadyBeingProcessed"
        _ -> raise "QuoteNotPaid"
      end

      new_state = mint_quote.state && <<0x7F>>
      new_value = Ecto.Changeset.change(mint_quote, state: new_state)

      case repo.update(new_value) do
        {:ok, _} -> mint_quote
        {:error, changeset} -> raise "Failed to update key: #{inspect(changeset.errors)}"
      end
    end

    def release!(repo, quote_id) do
      case Schema.MintQuote.unset_pending(repo, quote_id) do
        {:err, e} -> raise e
        {:ok, _} -> nil
      end
    end
  end
end
