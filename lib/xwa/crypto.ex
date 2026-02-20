defmodule Xwa.Crypto do
  @moduledoc """
  AES-256-GCM encryption for document content.

  ## Key tiers

  - **App tier** — uses a single 32-byte key from the `ENCRYPTION_KEY`
    environment variable. Protects against raw database exposure. The
    application can always decrypt app-tier content.

  - **User tier** — uses a per-user 32-byte key stored (encrypted with
    the app key) in the `user_keys` table. Only the document owner and
    users they have explicitly shared with can decrypt. The application
    cannot read user-tier content without first fetching the user's key.

  ## Wire format

  Encrypted binaries are stored as:

      <<iv::binary-12, tag::binary-16, ciphertext::binary>>

  The IV is randomly generated per encryption call. The GCM authentication
  tag provides integrity verification on decryption.

  ## Usage

      # Encrypt with app key (default)
      {:ok, ciphertext} = Xwa.Crypto.encrypt_app(plaintext)
      {:ok, plaintext}  = Xwa.Crypto.decrypt_app(ciphertext)

      # Encrypt with a raw key (user tier — caller fetches/manages the key)
      {:ok, ciphertext} = Xwa.Crypto.encrypt(plaintext, key)
      {:ok, plaintext}  = Xwa.Crypto.decrypt(ciphertext, key)

      # Generate and wrap a new user key with the app key
      {:ok, encrypted_key} = Xwa.Crypto.generate_user_key()

      # Unwrap a user key for use
      {:ok, raw_key} = Xwa.Crypto.unwrap_user_key(encrypted_key)
  """

  @aad "xwa_v1"
  @iv_size 12
  @tag_size 16

  # ---------------------------------------------------------------------------
  # App-tier convenience functions
  # ---------------------------------------------------------------------------

  @doc """
  Encrypts `plaintext` using the app-level key from config/env.
  Returns `{:ok, ciphertext_binary}` or `{:error, reason}`.
  """
  @spec encrypt_app(binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt_app(plaintext) when is_binary(plaintext) do
    with {:ok, key} <- app_key() do
      encrypt(plaintext, key)
    end
  end

  @doc """
  Decrypts `ciphertext` using the app-level key from config/env.
  Returns `{:ok, plaintext}` or `{:error, reason}`.
  """
  @spec decrypt_app(binary()) :: {:ok, binary()} | {:error, term()}
  def decrypt_app(ciphertext) when is_binary(ciphertext) do
    with {:ok, key} <- app_key() do
      decrypt(ciphertext, key)
    end
  end

  # ---------------------------------------------------------------------------
  # Raw encrypt / decrypt (key provided by caller)
  # ---------------------------------------------------------------------------

  @doc """
  Encrypts `plaintext` with the given 32-byte `key` using AES-256-GCM.

  Returns `{:ok, <<iv::12, tag::16, ciphertext::n>>}`.
  """
  @spec encrypt(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt(plaintext, key) when is_binary(plaintext) and byte_size(key) == 32 do
    iv = :crypto.strong_rand_bytes(@iv_size)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, @tag_size, true)

    {:ok, <<iv::binary-12, tag::binary-16, ciphertext::binary>>}
  end

  def encrypt(_plaintext, key) when is_binary(key) do
    {:error, {:invalid_key_size, byte_size(key)}}
  end

  @doc """
  Decrypts `ciphertext` (in wire format) with the given 32-byte `key`.

  Returns `{:ok, plaintext}` or `{:error, :decryption_failed}` if the
  tag does not verify (wrong key, corrupted data, or tampered content).
  """
  @spec decrypt(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def decrypt(
        <<iv::binary-12, tag::binary-16, ciphertext::binary>>,
        key
      )
      when byte_size(key) == 32 do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      :error -> {:error, :decryption_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  def decrypt(ciphertext, _key) when byte_size(ciphertext) < @iv_size + @tag_size do
    {:error, :ciphertext_too_short}
  end

  def decrypt(_ciphertext, key) when is_binary(key) do
    {:error, {:invalid_key_size, byte_size(key)}}
  end

  # ---------------------------------------------------------------------------
  # Per-user key management
  # ---------------------------------------------------------------------------

  @doc """
  Generates a new random 32-byte user key and wraps it with the app key.

  Returns `{:ok, encrypted_key_binary}` — this is what gets stored in
  `user_keys.encrypted_key`. The raw key is not returned and is not stored.
  """
  @spec generate_user_key() :: {:ok, binary()} | {:error, term()}
  def generate_user_key do
    raw_key = :crypto.strong_rand_bytes(32)

    with {:ok, encrypted} <- encrypt_app(raw_key) do
      {:ok, encrypted}
    end
  end

  @doc """
  Unwraps a stored per-user key by decrypting it with the app key.

  Returns `{:ok, raw_key_binary}` for use in `encrypt/2` or `decrypt/2`.
  The raw key should not be persisted — use it transiently and let it be
  garbage collected.
  """
  @spec unwrap_user_key(binary()) :: {:ok, binary()} | {:error, term()}
  def unwrap_user_key(encrypted_key) when is_binary(encrypted_key) do
    decrypt_app(encrypted_key)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp app_key do
    case Application.get_env(:xwa, :encryption_key) ||
           System.get_env("ENCRYPTION_KEY") do
      nil ->
        {:error, :encryption_key_not_configured}

      key when is_binary(key) and byte_size(key) == 32 ->
        {:ok, key}

      key when is_binary(key) ->
        # Accept hex-encoded 64-char string as a convenience
        case Base.decode16(key, case: :mixed) do
          {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
          _ -> {:error, {:invalid_encryption_key, "must be 32 raw bytes or 64 hex chars"}}
        end

      _ ->
        {:error, :invalid_encryption_key}
    end
  end
end
