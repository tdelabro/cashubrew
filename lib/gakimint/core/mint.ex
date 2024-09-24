defmodule Gakimint.Mint do
  @moduledoc """
  Mint operations for the Gakimint mint.
  """

  use GenServer
  alias Gakimint.Crypto.BDHKE
  alias Gakimint.Schema.{Key, Keyset, MintConfiguration}
  import Ecto.Query

  @keyset_generation_seed_key "keyset_generation_seed"
  @keyset_generation_derivation_path "m/0'/0'/0'"
  @mint_pubkey_key "mint_pubkey"
  @mint_privkey_key "mint_privkey"
  @default_input_fee_ppk 0

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %{keysets: [], mint_pubkey: nil}, {:continue, :load_keysets_and_mint_key}}
  end

  @impl true
  def handle_continue(:load_keysets_and_mint_key, state) do
    repo = Application.get_env(:gakimint, :repo)
    seed = get_or_create_seed(repo)
    keysets = load_or_create_keysets(repo, seed)
    {_, mint_pubkey} = get_or_create_mint_key(repo, seed)
    {:noreply, %{state | keysets: keysets, mint_pubkey: mint_pubkey}}
  end

  defp get_or_create_seed(repo) do
    case repo.get_by(MintConfiguration, key: @keyset_generation_seed_key) do
      nil ->
        seed =
          System.get_env("KEYSET_GENERATION_SEED") ||
            :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

        case %MintConfiguration{}
             |> MintConfiguration.changeset(%{key: @keyset_generation_seed_key, value: seed})
             |> repo.insert() do
          {:ok, config} ->
            config.value

          {:error, changeset} ->
            raise "Failed to insert MintConfiguration: #{inspect(changeset.errors)}"
        end

      config ->
        config.value
    end
  end

  defp load_or_create_keysets(repo, seed) do
    case repo.all(Keyset) do
      [] ->
        keyset =
          Keyset.generate("sat", seed, @keyset_generation_derivation_path, @default_input_fee_ppk)

        [keyset]

      existing ->
        existing
    end
  end

  defp get_or_create_mint_key(repo, seed) do
    case {repo.get_by(MintConfiguration, key: @mint_pubkey_key),
          repo.get_by(MintConfiguration, key: @mint_privkey_key)} do
      {nil, nil} ->
        {privkey, pubkey} = derive_mint_key(seed)

        %MintConfiguration{}
        |> MintConfiguration.changeset(%{
          key: @mint_pubkey_key,
          value: Base.encode16(pubkey, case: :lower)
        })
        |> repo.insert!()

        %MintConfiguration{}
        |> MintConfiguration.changeset(%{
          key: @mint_privkey_key,
          value: Base.encode16(privkey, case: :lower)
        })
        |> repo.insert!()

        {privkey, pubkey}

      {pubkey_config, privkey_config} ->
        pubkey = Base.decode16!(pubkey_config.value, case: :lower)
        privkey = Base.decode16!(privkey_config.value, case: :lower)
        {privkey, pubkey}
    end
  end

  defp derive_mint_key(seed) do
    private_key = :crypto.hash(:sha256, seed)
    {private_key, public_key} = BDHKE.generate_keypair(private_key)
    {private_key, public_key}
  end

  @impl true
  def handle_call(:get_keysets, _from, state) do
    {:reply, state.keysets, state}
  end

  @impl true
  def handle_call(:get_mint_pubkey, _from, state) do
    {:reply, state.mint_pubkey, state}
  end

  # Public API

  def get_keysets do
    GenServer.call(__MODULE__, :get_keysets)
  end

  def get_keys_for_keyset(repo, keyset_id) do
    repo.all(
      from(k in Key,
        where: k.keyset_id == ^keyset_id,
        order_by: [asc: k.amount]
      )
    )
  end

  def get_pubkey do
    GenServer.call(__MODULE__, :get_mint_pubkey)
  end

  def get_active_keysets(repo) do
    repo.all(from(k in Keyset, where: k.active == true))
  end

  def get_all_keysets(repo) do
    repo.all(Keyset)
  end

  def get_keyset(repo, keyset_id) do
    repo.get(Keyset, keyset_id)
  end
end
